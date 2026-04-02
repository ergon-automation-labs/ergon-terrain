defmodule BotArmyTerrain.Skills.ImportCards do
  @moduledoc """
  Skill for importing pre-made flashcards from CSV files.

  Processes:
  - CSV files with card data (question, answer, track, tags)
  - Validates card format
  - Stores in card database
  - Generates embeddings for semantic linking

  Trigger: bot.army.terrain.command.import_cards
  """

  use BotArmy.Skill
  require Logger

  @impl true
  def name, do: :import_cards

  @impl true
  def description do
    "Import pre-made flashcards from CSV file"
  end

  @impl true
  def nats_triggers do
    [
      "bot.army.terrain.command.import_cards"
    ]
  end

  @impl true
  def llm_hint, do: :none

  @impl true
  def validate(%{"path" => path}) when is_binary(path) and byte_size(path) > 0 do
    :ok
  end

  def validate(_) do
    {:error, "path field required"}
  end

  @impl true
  def execute(input, _ctx) do
    try do
      path = input["path"]

      case BotArmyTerrain.Ingestion.CardImporter.import_csv(path) do
        {:ok, stats} ->
          Logger.info("[ImportCards] Completed: #{inspect(stats)}")
          {:ok, Map.merge(stats, %{path: path})}

        {:error, reason} ->
          Logger.error("[ImportCards] Failed: #{inspect(reason)}")
          {:error, {:import_failed, reason}}
      end
    rescue
      e ->
        Logger.error("[ImportCards] Execution failed", error: inspect(e))
        {:error, :execution_failed}
    end
  end
end
