defmodule BotArmyTerrain.Skills.Ingest do
  @moduledoc """
  Skill for ingesting CSV and markdown content into the terrain database.

  Processes:
  - CSV files with track/content structure
  - Markdown files with hierarchical content
  - Chunks content and stores in knowledge base
  - Generates embeddings for semantic search

  Trigger: bot.army.terrain.command.ingest
  """

  use BotArmy.Skill
  require Logger

  @impl true
  def name, do: :ingest

  @impl true
  def description do
    "Ingest CSV/markdown content into terrain tracks and chunks"
  end

  @impl true
  def nats_triggers do
    [
      "bot.army.terrain.command.ingest"
    ]
  end

  @impl true
  def llm_hint, do: :none

  @impl true
  def validate(%{"path_or_blob_ref" => path}) when is_binary(path) and byte_size(path) > 0 do
    :ok
  end

  def validate(%{"path" => path}) when is_binary(path) and byte_size(path) > 0 do
    :ok
  end

  def validate(_) do
    {:error, "path or path_or_blob_ref field required"}
  end

  @impl true
  def execute(input, _ctx) do
    try do
      path = input["path_or_blob_ref"] || input["path"]
      source_type = (input["source_type"] || "csv") |> to_string() |> String.downcase()

      case source_type do
        "csv" ->
          case BotArmyTerrain.Ingestion.IngestionWorker.ingest_csv(path) do
            {:ok, stats} ->
              Logger.info("[Ingest] Completed: #{inspect(stats)}")
              {:ok, Map.merge(stats, %{source_type: "csv", path: path})}

            {:error, reason} ->
              Logger.error("[Ingest] Failed: #{inspect(reason)}")
              {:error, {:ingestion_failed, reason}}
          end

        _ ->
          Logger.warning("[Ingest] Unsupported source_type: #{source_type}")
          {:error, {:unsupported_source_type, source_type}}
      end
    rescue
      e ->
        Logger.error("[Ingest] Execution failed", error: inspect(e))
        {:error, :execution_failed}
    end
  end
end
