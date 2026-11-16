defmodule BotArmyTerrain.StoryWriter do
  @moduledoc """
  Writes the next chapter while the current one is still being played.

  The request path never calls a model. `ensure/2` is a GenServer call that only looks at the
  season plan and a small in-memory queue; it answers in microseconds. A background job loads
  the deck's cards, asks the LLM for a chapter **plan**, compiles that plan through
  `BotArmyTerrain.StoryBuilder`, and writes the playable chapter into the runtime story
  directory.

  The ten-minute watchdog is the promise: if the model has not answered, or its answer cannot
  be compiled, the writer publishes a template chapter built from the same cards and lesson.
  The story never waits on a model to be playable.

  Jobs are in memory on purpose: a restart loses a pending job, and the next `ensure/2` asks
  again. The chapter file is the durable artifact.
  """

  use GenServer
  require Logger

  alias BotArmyLibraryRuntime.NATS.Connection
  alias BotArmyTerrain.{CardStore, Story, StoryBuilder, TrackStore}

  @watchdog_ms 600_000
  @failure_cooldown_ms 120_000
  @max_attempts 2
  @prompt_cards 10

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Make sure the chapter after `chapter_id` is written, now or soon.

  Returns `{:ok, :ready}` when it already exists, `{:ok, :writing}` when a job is running (or
  cooling down after a failure), `{:ok, :queued}` when this call queued it, and
  `{:error, :no_next_chapter}` at the end of the season.
  """
  def ensure(tenant_id, chapter_id) do
    GenServer.call(__MODULE__, {:ensure, tenant_id, chapter_id}, 5_000)
  end

  @doc "The LLM completion handler asks the writer to finish the job it started."
  def complete(msg), do: GenServer.cast(__MODULE__, {:completion, msg})

  @doc "For operators and tests: the active job id and the queue behind it."
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts) do
    {:ok, %{jobs: %{}, queue: [], active: nil, cooldowns: %{}}}
  end

  @impl true
  def handle_call({:ensure, tenant_id, chapter_id}, _from, state) do
    case Story.next_season_chapter(chapter_id) do
      nil ->
        {:reply, {:error, :no_next_chapter}, state}

      spec ->
        cond do
          Story.chapter(spec["id"]) ->
            {:reply, {:ok, :ready}, state}

          job_for(state, spec["id"]) ->
            {:reply, {:ok, :writing}, state}

          cooling_down?(state, spec["id"]) ->
            {:reply, {:ok, :writing}, state}

          true ->
            {:reply, {:ok, :queued}, enqueue(state, tenant_id, chapter_id, spec)}
        end
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, %{active: state.active, queue: state.queue, jobs: map_size(state.jobs)}, state}
  end

  @impl true
  def handle_cast({:completion, msg}, state) do
    job_id = get_in(msg, ["source_metadata", "story_job_id"])
    text = get_in(msg, ["payload", "completion"])

    if is_binary(job_id) and is_binary(text) do
      send(self(), {:completion, job_id, text})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:start, %{active: nil} = state) do
    {:noreply, start_next(state)}
  end

  def handle_info(:start, state), do: {:noreply, state}

  def handle_info({:prepared, job_id, result}, %{active: job_id} = state) do
    job = state.jobs[job_id]

    case result do
      {:ok, cards, prompt_id} ->
        job = %{job | cards: cards, prompt_id: prompt_id, status: :waiting}
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
    Logger.warning("Terrain: story job #{job_id} passed its ten-minute deadline")
    {:noreply, fallback(state.jobs[job_id], :timeout, state)}
  end

  def handle_info({:watchdog, _job_id}, state), do: {:noreply, state}

  defp enqueue(state, tenant_id, previous_id, spec) do
    job = %{
      id: UUID.uuid4(),
      tenant_id: tenant_id,
      previous_id: previous_id,
      chapter_id: spec["id"],
      spec: spec,
      cards: [],
      attempt: 0,
      prompt_id: nil,
      deadline: nil,
      last_answer: nil,
      last_errors: [],
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
        job = %{job | attempt: 1, status: :preparing, deadline: deadline()}
        Process.send_after(self(), {:watchdog, job.id}, @watchdog_ms)
        Task.start(fn -> send(parent, {:prepared, job.id, prepare(job)}) end)

        %{
          state
          | queue: rest,
            active: job.id,
            jobs: Map.put(state.jobs, job.id, job)
        }
    end
  end

  defp prepare(job) do
    case load_cards(job.tenant_id, job.spec["deck"]) do
      {:ok, []} -> {:error, :no_cards}
      {:ok, cards} -> prepare_with_cards(job, cards)
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  end

  defp prepare_with_cards(job, cards) do
    prompt =
      if is_binary(job.last_answer) do
        repair_prompt(
          job.spec,
          Story.chapter(job.previous_id),
          cards,
          job.last_answer,
          job.last_errors
        )
      else
        prompt(job.spec, Story.chapter(job.previous_id), cards)
      end

    case submit(prompt, job) do
      {:ok, prompt_id} -> {:ok, cards, prompt_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp submit(prompt, job) do
    case Application.get_env(:bot_army_terrain, :story_submitter) do
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
      "triggered_by" => "story_writer",
      "schema_version" => "1.0",
      "tenant_id" => job.tenant_id,
      "source_metadata" => %{
        "source_domain" => "story_generation",
        "story_job_id" => job.id,
        "chapter_id" => job.chapter_id
      },
      "payload" => %{
        "text" => prompt,
        "prompt_id" => prompt_id,
        "context" => job.spec["title"]
      }
    }

    with {:ok, conn} <- get_connection(),
         :ok <- Gnat.pub(conn, "llm.prompt.submit", Jason.encode!(envelope)) do
      Logger.info("Terrain: asked the model for #{job.chapter_id} (job #{job.id})")
      {:ok, prompt_id}
    else
      {:error, reason} ->
        Logger.warning("Terrain: story prompt could not be sent: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_answer(job, text, state) do
    job = %{job | last_answer: text}

    case parse_plan(text) do
      {:ok, plan} ->
        compile(job, plan, state)

      {:error, reason} ->
        retry_or_fallback(
          job,
          ["the answer was not a JSON plan (#{inspect(reason)})"],
          state
        )
    end
  end

  defp compile(job, plan, state) do
    plan =
      plan
      |> Map.put("id", job.spec["id"])
      |> Map.put("title", job.spec["title"])
      |> Map.put("lesson", job.spec["lesson"])
      |> Map.put("deck", job.spec["deck"])

    case StoryBuilder.build(plan, job.cards) do
      {:ok, chapter} ->
        publish(job, chapter, state, "model")

      {:error, reasons} ->
        retry_or_fallback(job, reasons, state)
    end
  end

  defp retry_or_fallback(job, errors, state) do
    if job.attempt < @max_attempts do
      Logger.warning(
        "Terrain: story plan for #{job.chapter_id} refused, asking again: #{inspect(errors)}"
      )

      job = %{
        job
        | attempt: job.attempt + 1,
          status: :preparing,
          last_errors: errors
      }

      parent = self()
      Task.start(fn -> send(parent, {:prepared, job.id, prepare(job)}) end)

      %{state | jobs: Map.put(state.jobs, job.id, job)}
    else
      fallback(job, errors, state)
    end
  end

  defp fallback(job, reason, state) do
    Logger.warning("Terrain: writing #{job.chapter_id} from the template (#{inspect(reason)})")

    plan = fallback_plan(job.spec, job.cards)

    case StoryBuilder.build(plan, job.cards) do
      {:ok, chapter} ->
        publish(job, chapter, state, "template")

      {:error, errors} ->
        fail(job, errors, state)
    end
  end

  defp publish(job, chapter, state, source) do
    case Story.publish_chapter(chapter) do
      {:ok, path} ->
        Logger.info("Terrain: published #{job.chapter_id} at #{path} (#{source})")
        emit_ready(job, chapter, source)
        request_boundary_interstitials(job)
        finish(job, state)

      {:error, reason} ->
        fail(job, {:write_failed, reason}, state)
    end
  end

  # A chapter landing is also the earliest moment the two interstitials around it become
  # knowable. Asking now gives the producer the whole time she spends in the previous chapter;
  # the end-of-chapter request remains as a fallback if this one was lost.
  defp request_boundary_interstitials(job) do
    producer =
      Application.get_env(:bot_army_terrain, :ads_producer, &BotArmyTerrain.AdsProducer.ensure/2)

    producer.(job.tenant_id, job.previous_id)
  rescue
    error ->
      Logger.warning(
        "Terrain: ad producer unavailable after publish: #{Exception.message(error)}"
      )

      :error
  catch
    :exit, _ -> :error
  end

  defp emit_ready(job, chapter, source) do
    Task.start(fn ->
      emit_event("events.terrain.story.ready", %{
        "tenant_id" => job.tenant_id,
        "chapter_id" => job.chapter_id,
        "title" => chapter["title"],
        "lesson" => chapter["lesson"],
        "source" => source
      })
    end)
  end

  defp finish(job, state) do
    state = %{
      state
      | active: nil,
        jobs: Map.delete(state.jobs, job.id),
        cooldowns: Map.delete(state.cooldowns, job.chapter_id)
    }

    send(self(), :start)
    state
  end

  defp fail(job, reason, state) do
    Logger.error("Terrain: story job #{job.id} failed: #{inspect(reason)}")

    Task.start(fn ->
      emit_event("events.terrain.story.failed", %{
        "tenant_id" => job.tenant_id,
        "chapter_id" => job.chapter_id,
        "reason" => inspect(reason)
      })
    end)

    state = %{
      state
      | active: nil,
        jobs: Map.delete(state.jobs, job.id),
        cooldowns: Map.put(state.cooldowns, job.chapter_id, now_ms() + @failure_cooldown_ms)
    }

    send(self(), :start)
    state
  end

  defp job_for(state, chapter_id) do
    Enum.find_value(state.jobs, fn {id, job} -> if job.chapter_id == chapter_id, do: id end)
  end

  defp cooling_down?(state, chapter_id) do
    case Map.get(state.cooldowns, chapter_id) do
      nil -> false
      until -> now_ms() < until
    end
  end

  defp deadline, do: now_ms() + @watchdog_ms
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp load_cards(tenant_id, deck) do
    case Application.get_env(:bot_army_terrain, :story_card_loader) do
      loader when is_function(loader, 2) -> loader.(tenant_id, deck)
      _ -> cards_from_deck(tenant_id, deck)
    end
  end

  defp cards_from_deck(tenant_id, deck) do
    case TrackStore.get_by_name(deck) do
      nil ->
        {:error, :no_deck}

      track ->
        due = CardStore.list_due_cards(tenant_id, track.id, limit: @prompt_cards)
        all = CardStore.list_cards_for_track(tenant_id, track.id)

        cards =
          (due ++ all)
          |> Enum.uniq_by(& &1.id)
          |> Enum.take(@prompt_cards)
          |> Enum.map(&%{"front" => &1.front, "back" => &1.back, "deck" => deck})

        {:ok, cards}
    end
  end

  @doc """
  The prompt for a chapter plan. The model owns the prose; the season owns the id, title and
  lesson, and the deck owns the cards. Every scene must test one exact card front.
  """
  def prompt(spec, previous, cards) do
    cards = normalize_cards(cards, spec["deck"])

    """
    You are writing one chapter of "The Quiet Archive", a choose-your-own-adventure in which
    every choice is a flashcard. The learner is the ship's new operator. Write in second
    person, present tense. No shame, no streaks, no scorekeeping.

    Season through-line: #{Story.season()["through_line"]}
    Chapter id: #{spec["id"]}
    Chapter title: #{spec["title"]}
    The chapter's one grand lesson: #{spec["lesson"]}
    Deck: #{spec["deck"]}

    #{previous_block(previous)}

    Cards available from the deck (use each card's front exactly as written):
    #{card_lines(cards)}

    Return ONLY a JSON object, no prose and no code fences, in this shape:

    {
      "id": "#{spec["id"]}",
      "title": "#{spec["title"]}",
      "lesson": "#{spec["lesson"]}",
      "start": "first_scene_id",
      "deck": "#{spec["deck"]}",
      "scenes": [
        {
          "id": "a_scene_id",
          "title": "Short scene title",
          "text": "Two or three short paragraphs. Use **bold**, *italic*, `code`, and [[term]] sparingly.",
          "card": "the exact card front from the list above",
          "prompt": "The situation's question, not the card's answer",
          "right": "What happens when she chooses the true answer. Restate the fact in the fiction.",
          "wrong": "What it costs when she guesses. The world remembers it, but does not shame her.",
          "wrong_label": "A plausible but false answer (never the card's true back)",
          "set": { "a_fact": true },
          "wrong_set": { "a_cost": true }
        }
      ],
      "end": {
        "title": "End of #{spec["title"]}",
        "text": "The chapter closes by naming what she now knows.",
        "ritual": "One sentence about opening the next chapter when she is ready."
      }
    }

    Rules:
    - 4 to 6 scenes. Each scene tests exactly one card, and no card is used twice.
    - The card front must match a line above character for character.
    - Both buttons must be plausible. The wrong answer is a real mistake, not a joke.
    - The right outcome restates the card's fact; the wrong outcome shows its cost.
    - Facts set by a wrong answer are costs the next scenes may echo; they are never a reward.
    - The chapter must earn the lesson; do not state the lesson as a lecture before the end.
    - Do not reveal or name the next chapter's twist.
    """
  end

  @doc "The same prompt, with the refused answer and the compiler's reasons appended."
  def repair_prompt(spec, previous, cards, previous_answer, errors) do
    prompt(spec, previous, cards) <>
      """

      Your previous answer was refused for these reasons:
      #{Enum.map_join(errors, "\n", &"- #{&1}")}

      Previous answer:
      #{String.slice(previous_answer, 0, 8_000)}

      Return only the corrected JSON object.
      """
  end

  defp previous_block(nil), do: "This is the season's opening chapter."

  defp previous_block(previous) do
    end_text =
      case previous do
        %{"scenes" => %{"end" => %{"text" => text}}} -> text
        _ -> ""
      end

    """
    The chapter she just finished: #{previous["title"]}
    Its lesson: #{previous["lesson"]}
    How it ended: #{end_text}
    """
  end

  defp card_lines(cards) do
    Enum.map_join(cards, "\n", fn card -> "- #{card["front"]} => #{card["back"]}" end)
  end

  @doc "Parse a model answer into a plan, tolerating code fences and stray prose around it."
  def parse_plan(text) when is_binary(text) do
    json =
      case Regex.run(~r/\{.*\}/s, text) do
        [object | _] -> object
        nil -> text
      end

    case Jason.decode(json) do
      {:ok, %{} = plan} -> {:ok, plan}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse_plan(_text), do: {:error, :not_text}

  @doc """
  A playable chapter from the deck when the model is late, wrong, or unavailable.

  It is not the model's prose, but it is the same lesson and the same cards, and every scene
  still requires the fact. The story keeps its promise even when the writer does not.
  """
  def fallback_plan(spec, cards) do
    cards = normalize_cards(cards, spec["deck"])
    selected = select_cards(cards)
    scenes = build_fallback_scenes(spec, selected)

    %{
      "id" => spec["id"],
      "title" => spec["title"],
      "lesson" => spec["lesson"],
      "deck" => spec["deck"],
      "start" => "first",
      "scenes" => scenes,
      "end" => %{
        "title" => "End of #{spec["title"]}",
        "text" => "The corridor lets you go. **#{spec["lesson"]}**" <> next_teaser(spec),
        "ritual" => "The next chapter opens when you're ready."
      }
    }
  end

  defp select_cards([]), do: []

  defp select_cards(cards) do
    if length(cards) >= 4 do
      Enum.take(cards, 4)
    else
      cards
      |> Stream.cycle()
      |> Enum.take(4)
    end
  end

  defp build_fallback_scenes(_spec, []), do: []

  defp build_fallback_scenes(spec, cards) do
    titles = ["The Next Door", "The Console", "The Cost", "The Lesson"]

    cards
    |> Enum.with_index()
    |> Enum.map(fn {card, index} ->
      other = Enum.at(cards, rem(index + 1, length(cards)))

      %{
        "id" => fallback_id(index),
        "title" => Enum.at(titles, index, "The Next Door"),
        "text" =>
          "A console waits in the corridor. VESPER says: \"One card before the next door.\"\n\n" <>
            "The prompt is already on the screen.",
        "card" => card["front"],
        "prompt" => card["front"],
        "right" => "**The door opens.** The System files it under *known*.",
        "wrong" => "**The door holds.** The System wants the fact, not the guess.",
        "wrong_label" => wrong_label(card, other),
        "set" => %{"#{spec["id"]}_fact_#{index}" => true},
        "wrong_set" => %{"#{spec["id"]}_wrong_#{index}" => true}
      }
    end)
  end

  defp fallback_id(0), do: "first"
  defp fallback_id(1), do: "second"
  defp fallback_id(2), do: "third"
  defp fallback_id(_), do: "fourth"

  defp wrong_label(card, other) do
    candidate =
      case other do
        nil -> nil
        _ -> other["back"] |> first_sentence() |> StoryBuilder.plain()
      end

    if is_binary(candidate) and candidate != "" and candidate != label(card),
      do: candidate,
      else: "Another answer"
  end

  defp label(card) do
    card["back"] |> first_sentence() |> StoryBuilder.plain()
  end

  defp first_sentence(text) when is_binary(text) do
    case Regex.run(~r/^.*?[.!?](?:\s|$)/, text) do
      [sentence | _] -> sentence
      nil -> text
    end
  end

  defp first_sentence(_text), do: ""

  defp next_teaser(spec) do
    case Story.next_season_chapter(spec["id"]) do
      nil -> "\n\nThe season ends here, for now."
      next -> "\n\nThe next door is marked **#{next["title"]}**."
    end
  end

  defp normalize_cards(cards, deck) when is_list(cards) do
    cards
    |> Enum.map(&normalize_card(&1, deck))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_cards(_cards, _deck), do: []

  defp normalize_card(%{"front" => front, "back" => back}, deck)
       when is_binary(front) and is_binary(back),
       do: %{"front" => front, "back" => back, "deck" => deck}

  defp normalize_card(%{front: front, back: back}, deck)
       when is_binary(front) and is_binary(back),
       do: %{"front" => front, "back" => back, "deck" => deck}

  defp normalize_card(_card, _deck), do: nil

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
      Logger.debug("Terrain: story event not published: #{Exception.message(error)}")
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
