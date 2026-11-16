defmodule BotArmyTerrain.AdsProducer do
  @moduledoc """
  Writes the two interstitials for a chapter boundary while she is still reading.

  A job is queued when she turns the last page of a chapter: one recap that restates the lesson
  she just used, and one trailer that shows where the next lesson shows up. The model writes
  the prose; this module owns the ids, the lesson metadata, the boundary, and the safety check.
  A creative that leaks an answer from the chapter it advertises is refused; if neither
  survives, a template creative is written instead.

  The ten-minute watchdog is the same promise the story writer makes: the page never waits on a
  model. Text is canonical, so there is no render step to miss. Jobs are in memory; the JSON
  file in the runtime ads directory is the durable artifact.
  """

  use GenServer
  require Logger

  alias BotArmyLibraryRuntime.NATS.Connection
  alias BotArmyTerrain.{Ads, Story}

  @watchdog_ms 600_000
  @failure_cooldown_ms 120_000
  @order 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Make sure the boundary after `chapter_id` has its recap and trailer, now or soon.

  Returns `{:ok, :ready}` when both already exist, `{:ok, :queued}` when this call queued a
  job, `{:ok, :writing}` when one is already running or cooling down, and an error for an
  unknown chapter or the end of the season.
  """
  def ensure(tenant_id, chapter_id) do
    GenServer.call(__MODULE__, {:ensure, tenant_id, chapter_id}, 5_000)
  end

  @doc "The LLM completion handler asks the producer to finish the job it started."
  def complete(msg), do: GenServer.cast(__MODULE__, {:completion, msg})

  @doc "For operators and tests: the active job id and the queue behind it."
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts), do: {:ok, %{jobs: %{}, queue: [], active: nil, cooldowns: %{}}}

  @impl true
  def handle_call({:ensure, tenant_id, chapter_id}, _from, state) do
    previous = Story.chapter(chapter_id)
    next = Story.next_chapter(chapter_id)

    cond do
      is_nil(previous) ->
        {:reply, {:error, :unknown_chapter}, state}

      is_nil(next) ->
        {:reply, {:error, :no_next_chapter}, state}

      covered?(chapter_id) ->
        {:reply, {:ok, :ready}, state}

      job_for(state, chapter_id) ->
        {:reply, {:ok, :writing}, state}

      cooling_down?(state, chapter_id) ->
        {:reply, {:ok, :writing}, state}

      true ->
        {:reply, {:ok, :queued}, enqueue(state, tenant_id, previous, next)}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, %{active: state.active, queue: state.queue, jobs: map_size(state.jobs)}, state}
  end

  @impl true
  def handle_cast({:completion, msg}, state) do
    job_id = get_in(msg, ["source_metadata", "story_ads_job_id"])
    text = get_in(msg, ["payload", "completion"])

    if is_binary(job_id) and is_binary(text) do
      send(self(), {:completion, job_id, text})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:start, %{active: nil} = state), do: {:noreply, start_next(state)}
  def handle_info(:start, state), do: {:noreply, state}

  def handle_info({:prepared, job_id, result}, %{active: job_id} = state) do
    job = state.jobs[job_id]

    case result do
      {:ok, prompt_id} ->
        job = %{job | prompt_id: prompt_id, status: :waiting}
        {:noreply, %{state | jobs: Map.put(state.jobs, job_id, job)}}

      {:error, reason} ->
        {:noreply, fallback(job, reason, state)}
    end
  end

  def handle_info({:prepared, _job_id, _result}, state), do: {:noreply, state}

  def handle_info({:completion, job_id, text}, %{active: job_id} = state) do
    {:noreply, handle_answer(state.jobs[job_id], text, state)}
  end

  def handle_info({:completion, _job_id, _text}, state), do: {:noreply, state}

  def handle_info({:watchdog, job_id}, %{active: job_id} = state) do
    Logger.warning("Terrain: ad job #{job_id} passed its ten-minute deadline")
    {:noreply, fallback(state.jobs[job_id], :timeout, state)}
  end

  def handle_info({:watchdog, _job_id}, state), do: {:noreply, state}

  defp enqueue(state, tenant_id, previous, next) do
    job = %{
      id: UUID.uuid4(),
      tenant_id: tenant_id,
      previous: previous,
      next: next,
      previous_id: previous["id"],
      next_id: next["id"],
      prompt_id: nil,
      status: :queued
    }

    send(self(), :start)

    %{
      state
      | jobs: Map.put(state.jobs, job.id, job),
        queue: state.queue ++ [job.id]
    }
  end

  defp start_next(%{queue: []} = state), do: state

  defp start_next(%{queue: [job_id | rest]} = state) do
    case state.jobs[job_id] do
      nil ->
        start_next(%{state | queue: rest})

      job ->
        parent = self()
        job = %{job | status: :preparing}
        Process.send_after(self(), {:watchdog, job.id}, @watchdog_ms)
        Task.start(fn -> send(parent, {:prepared, job.id, prepare(job)}) end)

        %{state | queue: rest, active: job.id, jobs: Map.put(state.jobs, job.id, job)}
    end
  end

  defp prepare(job) do
    submit(prompt(job.previous, job.next), job)
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  end

  defp submit(prompt, job) do
    case Application.get_env(:bot_army_terrain, :ads_submitter) do
      submitter when is_function(submitter, 2) -> submitter.(prompt, job)
      _ -> publish_prompt(prompt, job)
    end
  end

  defp publish_prompt(prompt, job) do
    prompt_id = UUID.uuid4()
    event_id = UUID.uuid4()

    envelope = %{
      "event" => "llm.prompt.submit",
      "event_id" => event_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_terrain",
      "source_node" => node_name(),
      "triggered_by" => "ads_producer",
      "schema_version" => "1.0",
      "tenant_id" => job.tenant_id,
      "source_metadata" => %{
        "source_domain" => "story_ads",
        "story_ads_job_id" => job.id,
        "previous_chapter" => job.previous_id,
        "next_chapter" => job.next_id
      },
      "payload" => %{
        "text" => prompt,
        "prompt_id" => prompt_id,
        "context" => "Interstitials after #{job.previous_id}"
      }
    }

    with {:ok, conn} <- get_connection(),
         :ok <- Gnat.pub(conn, "llm.prompt.submit", Jason.encode!(envelope)) do
      Logger.info("Terrain: asked the model for the #{job.previous_id} interstitials")
      {:ok, prompt_id}
    else
      {:error, reason} ->
        Logger.warning("Terrain: ad prompt could not be sent: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_answer(job, text, state) do
    case parse(text) do
      {:ok, answer} ->
        creatives = answer |> build(job.previous, job.next) |> Enum.filter(&valid?/1)

        if creatives == [] do
          fallback(job, :no_creative_survived_validation, state)
        else
          publish(job, creatives, state, "model")
        end

      {:error, reason} ->
        fallback(job, reason, state)
    end
  end

  defp valid?(creative) do
    case Ads.lint([creative]) do
      {:ok, _} ->
        true

      {:error, errors} ->
        Logger.warning("Terrain: refused generated interstitial: #{inspect(errors)}")
        false
    end
  end

  defp publish(job, creatives, state, source) do
    results = Enum.map(creatives, &Ads.publish_creative/1)

    case Enum.filter(results, &match?({:ok, _}, &1)) do
      [] ->
        fail(job, {:write_failed, results}, state)

      published ->
        paths = Enum.map(published, fn {:ok, path} -> path end)
        Logger.info("Terrain: wrote interstitials #{inspect(paths)} (#{source})")
        emit_ready(job, creatives, source)
        finish(job, state)
    end
  end

  defp fallback(job, reason, state) do
    Logger.warning(
      "Terrain: writing #{job.previous_id} interstitials from the template (#{inspect(reason)})"
    )

    creatives = fallback_creatives(job.previous, job.next) |> Enum.filter(&valid?/1)

    if creatives == [] do
      fail(job, :fallback_failed, state)
    else
      publish(job, creatives, state, "template")
    end
  end

  defp finish(job, state) do
    state = %{
      state
      | active: nil,
        jobs: Map.delete(state.jobs, job.id),
        cooldowns: Map.delete(state.cooldowns, job.previous_id)
    }

    send(self(), :start)
    state
  end

  defp fail(job, reason, state) do
    Logger.error("Terrain: ad job #{job.id} failed: #{inspect(reason)}")

    state = %{
      state
      | active: nil,
        jobs: Map.delete(state.jobs, job.id),
        cooldowns: Map.put(state.cooldowns, job.previous_id, now_ms() + @failure_cooldown_ms)
    }

    send(self(), :start)
    state
  end

  defp job_for(state, chapter_id) do
    Enum.find_value(state.jobs, fn {id, job} -> if job.previous_id == chapter_id, do: id end)
  end

  defp cooling_down?(state, chapter_id) do
    case Map.get(state.cooldowns, chapter_id) do
      nil -> false
      until -> now_ms() < until
    end
  end

  defp covered?(chapter_id) do
    %{"recap" => recap, "trailer" => trailer} = Ads.coverage(chapter_id)
    recap and trailer
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  @doc """
  The prompt for the two interstitials at one boundary.

  The model owns the prose and the tagline question. This module owns the ids, the lesson
  metadata, and the slot, so a returned creative cannot drift away from the season.
  """
  def prompt(previous, next) do
    season = Story.season()

    """
    You are writing two short interstitials for "The Quiet Archive", a choose-your-own-adventure
    in which every choice is a flashcard. The learner is the ship's new operator. Write in second
    person, present tense. No shame, no streaks, no urgency, no countdown, no scarcity.

    Season: #{season["title"]}
    Through-line: #{season["through_line"]}

    She just finished: #{previous["title"]}
    Its lesson: #{previous["lesson"]}

    Next: #{next["title"]}
    Its one lesson: #{next["lesson"]}

    Return ONLY a JSON object, no prose and no code fences, in this shape:

    {
      "recap": {
        "title": "Previously on The Quiet Archive",
        "body": "Two short paragraphs. Restate the lesson she just used as the thread the next chapter pulls. Do not explain the next lesson.",
        "tagline": {
          "prompt": "One short question that asks her where that lesson showed up in her own day.",
          "max_chars": 120
        }
      },
      "trailer": {
        "title": "Next: #{next["title"]}",
        "body": "Two short paragraphs. DEMONSTRATE one ordinary place the next lesson shows up. Show the consequence of getting it wrong; do not define the lesson as a lecture.",
        "tagline": {
          "prompt": "One short question that asks her to predict where she will meet this next.",
          "max_chars": 120
        }
      }
    }

    Rules for both:
    - The text must be useful with no video. It is read, not watched.
    - Do not use any answer, option label, or card back from the next chapter. The reader has not met it yet.
    - The recap may name the previous lesson. The trailer may name the next lesson, but must earn it first.
    - Keep each body under 600 characters and each title under 80.
    - Do not mention scores, streaks, reminders, or that this is an ad.
    """
  end

  @doc "Parse a model answer into the two interstitial drafts, tolerating fences and stray prose."
  def parse(text) when is_binary(text) do
    json =
      case Regex.run(~r/\{.*\}/s, text) do
        [object | _] -> object
        nil -> text
      end

    case Jason.decode(json) do
      {:ok, %{"recap" => recap, "trailer" => trailer}}
      when is_map(recap) and is_map(trailer) ->
        {:ok, %{"recap" => recap, "trailer" => trailer}}

      _ ->
        {:error, :not_two_creatives}
    end
  end

  def parse(_text), do: {:error, :not_two_creatives}

  @doc "Turn the model's drafts into the two creative files, with canon metadata forced in."
  def build(%{"recap" => recap, "trailer" => trailer}, previous, next) do
    [
      creative(
        "recap",
        previous,
        next,
        previous["lesson"],
        recap,
        "chapter_start",
        "Previously on The Quiet Archive"
      ),
      creative(
        "trailer",
        previous,
        next,
        next["lesson"],
        trailer,
        "story_boundary",
        "Next: #{next["title"]}"
      )
    ]
  end

  defp creative(kind, previous, next, lesson, draft, slot, default_title) do
    %{
      "id" => "#{previous["id"]}-#{kind}-#{next["id"]}-auto",
      "kind" => kind,
      "slot" => slot,
      "air_after" => previous["id"],
      "lesson" => lesson,
      "order" => @order,
      "title" => text(draft["title"], default_title),
      "body" => text(draft["body"], ""),
      "tagline" => tagline(draft["tagline"]),
      "media" => nil,
      "sponsor" => nil
    }
  end

  defp tagline(%{"prompt" => prompt} = tagline) do
    %{"prompt" => text(prompt, ""), "max_chars" => positive(tagline["max_chars"], 120)}
  end

  defp tagline(_tagline), do: %{"prompt" => "", "max_chars" => 120}

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp text(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp text(_value, default), do: default

  @doc "The template used when the model is late, unavailable, or writes something unsafe."
  def fallback_creatives(previous, next) do
    recap = %{
      "title" => "Previously on The Quiet Archive",
      "body" =>
        "The lesson was: #{previous["lesson"]}\n\nThat is the thread #{next["title"]} picks up.",
      "tagline" => %{"prompt" => "Where did that lesson show up in your day?", "max_chars" => 120}
    }

    trailer = %{
      "title" => "Next: #{next["title"]}",
      "body" =>
        "#{next["title"]} starts with a choice that looks small.\n\nThe lesson: #{next["lesson"]}",
      "tagline" => %{"prompt" => "Where will you meet that next?", "max_chars" => 120}
    }

    build(%{"recap" => recap, "trailer" => trailer}, previous, next)
  end

  defp emit_ready(job, creatives, source) do
    Task.start(fn ->
      emit_event("events.terrain.ads.ready", %{
        "tenant_id" => job.tenant_id,
        "previous_chapter" => job.previous_id,
        "next_chapter" => job.next_id,
        "creative_ids" => Enum.map(creatives, & &1["id"]),
        "source" => source
      })
    end)
  end

  defp emit_event(event_name, payload) do
    with {:ok, conn} <- get_connection() do
      envelope = %{
        "event" => event_name,
        "event_id" => UUID.uuid4(),
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source" => "bot_army_terrain",
        "source_node" => node_name(),
        "schema_version" => "1.0",
        "payload" => payload
      }

      Gnat.pub(conn, event_name, Jason.encode!(envelope))
    end
  rescue
    error ->
      Logger.debug("Terrain: ad event not published: #{Exception.message(error)}")
      :error
  catch
    :exit, _ -> :error
  end

  defp get_connection do
    GenServer.call(Connection, :get_connection, 5_000)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp node_name, do: node() |> Atom.to_string()
end
