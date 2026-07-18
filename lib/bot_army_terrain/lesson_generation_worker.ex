defmodule BotArmyTerrain.LessonGenerationWorker do
  @moduledoc """
  Background worker for generating lessons via LLM.

  Maintains a queue of chunks needing lessons, calls LLM with chunk content,
  emits observability events (started, progress, completed, failed).

  Lessons are stored to database (Phase 2) with vectorization.
  """

  use GenServer
  require Logger

  alias BotArmyTerrain.Handlers.LessonHandler
  alias BotArmyLibraryRuntime.NATS.Envelope

  # Queue structure: %{chunk_id => {chunk_title, chunk_content, retries}}
  defmodule State do
    @moduledoc false
    defstruct queue: %{}, processing: nil, opts: []
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Queue a chunk for lesson generation."
  def queue_lesson(chunk_id, chunk_title, chunk_content) do
    GenServer.cast(__MODULE__, {:queue, chunk_id, chunk_title, chunk_content})
  end

  @doc "Get current queue status."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(opts) do
    state = %State{queue: %{}, processing: nil, opts: opts}
    # Start processing loop
    Process.send_after(self(), :process_next, 1000)
    {:ok, state}
  end

  @impl true
  def handle_cast({:queue, chunk_id, chunk_title, chunk_content}, state) do
    if Map.has_key?(state.queue, chunk_id) do
      Logger.debug("Lesson already queued for #{chunk_id}")
      {:noreply, state}
    else
      emit_event("terrain.lesson.generation.started", %{
        "chunk_id" => chunk_id,
        "chunk_title" => chunk_title,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

      new_queue = Map.put(state.queue, chunk_id, {chunk_title, chunk_content, 0})
      {:noreply, %{state | queue: new_queue}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    queue_size = map_size(state.queue)

    status = %{
      "queue_size" => queue_size,
      "processing" => state.processing,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:process_next, state) do
    case process_next_in_queue(state) do
      {:ok, new_state} ->
        # Schedule next processing
        Process.send_after(self(), :process_next, 2000)
        {:noreply, new_state}

      {:error, new_state} ->
        # Schedule retry after delay
        Process.send_after(self(), :process_next, 5000)
        {:noreply, new_state}

      {:wait, new_state} ->
        # No items in queue, wait longer
        Process.send_after(self(), :process_next, 10_000)
        {:noreply, new_state}
    end
  end

  defp process_next_in_queue(%{queue: queue, processing: nil} = state)
       when map_size(queue) == 0 do
    {:wait, state}
  end

  defp process_next_in_queue(%{queue: queue, processing: nil} = state) when map_size(queue) > 0 do
    # Pick first item from queue
    [{chunk_id, {title, content, retries}} | _] = Map.to_list(queue)

    case generate_lesson(chunk_id, title, content, retries) do
      {:ok, :submitted} ->
        # LLM request submitted — completion event will fire async via LessonCompletionHandler
        # Remove from queue now, don't wait for response
        Logger.debug("Lesson generation request submitted for #{chunk_id}")

        new_queue = Map.delete(queue, chunk_id)
        {:ok, %{state | queue: new_queue, processing: nil}}

      {:ok, demo_lesson} ->
        # NATS unavailable fallback — demo lesson was generated synchronously, fire completed event
        Logger.debug("Lesson generated synchronously (demo fallback) for #{chunk_id}")

        emit_event("terrain.lesson.generation.completed", %{
          "chunk_id" => chunk_id,
          "lesson_id" => Map.get(demo_lesson, "chunk_id"),
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

        new_queue = Map.delete(queue, chunk_id)
        {:ok, %{state | queue: new_queue, processing: nil}}

      {:error, reason} ->
        if retries < 2 do
          Logger.warning("Lesson generation failed for #{chunk_id}, retrying... (#{retries}/2)")

          emit_event("terrain.lesson.generation.progress", %{
            "chunk_id" => chunk_id,
            "status" => "retrying",
            "retries" => retries + 1,
            "reason" => inspect(reason)
          })

          new_queue = Map.put(queue, chunk_id, {title, content, retries + 1})
          {:error, %{state | queue: new_queue, processing: nil}}
        else
          Logger.error("Lesson generation failed permanently for #{chunk_id}: #{inspect(reason)}")

          emit_event("terrain.lesson.generation.failed", %{
            "chunk_id" => chunk_id,
            "reason" => inspect(reason),
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          })

          new_queue = Map.delete(queue, chunk_id)
          {:error, %{state | queue: new_queue, processing: nil}}
        end
    end
  end

  defp process_next_in_queue(state) do
    # Already processing, wait
    {:wait, state}
  end

  defp generate_lesson(chunk_id, chunk_title, chunk_content, _retries) do
    emit_event("terrain.lesson.generation.progress", %{
      "chunk_id" => chunk_id,
      "status" => "generating",
      "progress" => 0.3
    })

    # Call LLM handler to submit lesson generation request (fire-and-forget)
    # Returns {:ok, :submitted} if LLM request succeeded
    # Returns {:ok, demo_lesson} if NATS unavailable (falls back to synchronous demo)
    # Returns {:error, reason} on submission failure
    default_tenant_id = BotArmyLibraryCore.Tenant.default_tenant_id()

    case LessonHandler.generate_lesson(default_tenant_id, chunk_id, chunk_title, chunk_content) do
      {:ok, :submitted} ->
        # LLM request submitted successfully — completion event fires async
        {:ok, :submitted}

      {:ok, demo_lesson} ->
        # NATS unavailable fallback — demo lesson generated synchronously
        emit_event("terrain.lesson.generation.progress", %{
          "chunk_id" => chunk_id,
          "status" => "saving",
          "progress" => 0.9
        })

        {:ok, demo_lesson}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_event(event_name, payload) do
    envelope = %{
      "event" => event_name,
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_terrain",
      "source_node" => get_node_name(),
      "triggered_by" => "lesson_generation.worker",
      "schema_version" => "1.0",
      "payload" => payload
    }

    subject = "events.#{event_name}"

    case get_connection() do
      {:ok, conn} ->
        case Gnat.pub(conn, subject, Jason.encode!(envelope)) do
          :ok ->
            Logger.debug("Emitted event: #{event_name}")

          {:error, reason} ->
            Logger.error("Failed to emit event #{event_name}: #{inspect(reason)}")
        end

      {:error, _} ->
        Logger.warning("NATS unavailable, event not emitted: #{event_name}")
    end
  end

  defp get_connection do
    try do
      GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5000)
    rescue
      _ -> {:error, :unavailable}
    catch
      :exit, _ -> {:error, :unavailable}
    end
  end

  defp get_node_name do
    case :inet.gethostname() do
      {:ok, hostname} -> to_string(hostname)
      {:error, _} -> "unknown"
    end
  end
end
