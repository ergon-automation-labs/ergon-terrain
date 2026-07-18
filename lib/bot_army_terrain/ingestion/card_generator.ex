defmodule BotArmyTerrain.Ingestion.CardGenerator do
  @moduledoc """
  Mode 2: Content (markdown/text) → chunks → LLM requests (async).
  Splits text into chunks, creates LLM requests published to NATS,
  and waits for LlmResponseHandler to create cards from responses.
  """

  require Logger

  alias BotArmyLibraryRuntime.NATS.Publisher

  # Allow mocking via Application config (for tests)
  defp chunk_store,
    do: Application.get_env(:bot_army_terrain, :chunk_store, BotArmyTerrain.ChunkStore)

  defp track_store,
    do: Application.get_env(:bot_army_terrain, :track_store, BotArmyTerrain.TrackStore)

  @max_chunk_size 2000

  @doc "Generate cards from a file (markdown/text)."
  def generate_from_path(path, opts \\ []) do
    case File.read(path) do
      {:ok, content} -> generate_from_text(content, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Generate cards from raw text content."
  def generate_from_text(text, opts \\ []) do
    track_name = Keyword.get(opts, :track_name) || Keyword.get(opts, :track) || "Default"
    model = Keyword.get(opts, :model) || "haiku"

    with {:ok, track} <- track_store().get_or_create_track_by_name(track_name),
         chunks <- split_into_chunks(text),
         :ok <- create_chunks_and_send_requests(track.id, chunks, model) do
      track_store().update_chunk_count_from_store(track.id)
      {:ok, %{track_id: track.id, chunks: length(chunks), llm_requests_sent: length(chunks)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Split text into chunks on blank lines, capping each at max_chunk_size."
  def split_into_chunks(text) do
    text
    |> String.split(~r/\n\n+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&split_large_chunk/1)
  end

  # Split a large chunk if it exceeds max size
  defp split_large_chunk(chunk) do
    if String.length(chunk) > @max_chunk_size do
      chunk
      |> String.split(~r/[\s]+/, include_captures: true)
      |> Enum.reduce([], fn word, acc ->
        case acc do
          [] ->
            [[word]]

          [current | rest] ->
            current_text = Enum.join(current)

            if String.length(current_text) + String.length(word) <= @max_chunk_size do
              [current ++ [word] | rest]
            else
              [[word] | acc]
            end
        end
      end)
      |> Enum.map(&Enum.join/1)
      |> Enum.reject(&(&1 == ""))
    else
      [chunk]
    end
  end

  # Create chunks in DB and send LLM requests
  defp create_chunks_and_send_requests(track_id, chunks, model) do
    Enum.each(chunks, fn chunk_content ->
      case create_chunk_and_send_request(track_id, chunk_content, model) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Failed to create chunk: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # Create a single chunk and send LLM request
  defp create_chunk_and_send_request(track_id, chunk_content, model) do
    content_hash = :crypto.hash(:sha256, chunk_content) |> Base.encode16(case: :lower)

    attrs = %{
      source_type: "manual",
      source_path: "llm_generate",
      track_id: track_id,
      content: chunk_content,
      content_hash: content_hash
    }

    case chunk_store().upsert_chunk(attrs) do
      {:ok, chunk} -> build_llm_request_and_publish(track_id, chunk.id, chunk_content, model)
      {:error, reason} -> {:error, reason}
    end
  end

  # Build and publish LLM request
  defp build_llm_request_and_publish(track_id, chunk_id, chunk_content, model) do
    request = build_llm_request(chunk_id, track_id, chunk_content, model)

    case Publisher.publish("llm.response.parse", request) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Build LLM request payload for card generation."
  def build_llm_request(chunk_id, track_id, chunk_content, model) do
    %{
      "type" => "card_generation",
      "source_domain" => "terrain",
      "model" => model,
      "text" => build_prompt(chunk_content),
      "metadata" => %{
        "source" => "terrain_card_generation",
        "track_id" => track_id,
        "chunk_ids" => [chunk_id],
        "model" => model
      }
    }
  end

  # Build the LLM prompt template
  defp build_prompt(content) do
    """
    You are a spaced repetition flashcard author. Given the following knowledge content,
    generate 3-8 high-quality flashcard pairs. Test ONE fact per card.
    "front" = question (max 120 chars), "back" = concise answer (max 300 chars).
    card_type must be "basic", "cloze", or "definition".

    Content:
    ---
    #{content}
    ---

    Return ONLY valid JSON:
    {"cards": [{"front": "...", "back": "...", "card_type": "basic"}]}
    """
  end
end
