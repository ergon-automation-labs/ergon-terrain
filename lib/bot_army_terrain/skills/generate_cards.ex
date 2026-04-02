defmodule BotArmyTerrain.Skills.GenerateCards do
  @moduledoc """
  Skill for generating flashcards from text or files using LLM.

  Processes:
  - Raw text input
  - File paths with content
  - Generates cards with LLM-driven question/answer pairs
  - Stores in track with optional embedding

  Trigger: bot.army.terrain.command.generate_cards
  """

  use BotArmy.Skill
  require Logger

  @impl true
  def name, do: :generate_cards

  @impl true
  def description do
    "Generate flashcards from text or files using LLM"
  end

  @impl true
  def nats_triggers do
    [
      "bot.army.terrain.command.generate_cards"
    ]
  end

  @impl true
  def llm_hint, do: :quality

  @impl true
  def validate(input) when is_map(input) do
    has_path = is_binary(input["path"]) and byte_size(input["path"]) > 0
    has_text = is_binary(input["text"]) and byte_size(input["text"]) > 0

    if has_path or has_text do
      :ok
    else
      {:error, "path or text field required"}
    end
  end

  def validate(_) do
    {:error, "input must be a map with path or text field"}
  end

  @impl true
  def execute(input, _ctx) do
    try do
      path = input["path"]
      text = input["text"]
      track_name = input["track_name"] || input["track"] || "Default"
      model = input["model"] || "haiku"

      result =
        cond do
          is_binary(path) and byte_size(path) > 0 ->
            BotArmyTerrain.Ingestion.CardGenerator.generate_from_path(path,
              track_name: track_name,
              model: model
            )

          is_binary(text) and byte_size(text) > 0 ->
            BotArmyTerrain.Ingestion.CardGenerator.generate_from_text(text,
              track_name: track_name,
              model: model
            )

          true ->
            {:error, :missing_path_or_text}
        end

      case result do
        {:ok, stats} ->
          Logger.info("[GenerateCards] Initiated: #{inspect(stats)}")
          {:ok, Map.merge(stats, %{track_name: track_name, model: model})}

        {:error, reason} ->
          Logger.error("[GenerateCards] Failed: #{inspect(reason)}")
          {:error, {:generation_failed, reason}}
      end
    rescue
      e ->
        Logger.error("[GenerateCards] Execution failed", error: inspect(e))
        {:error, :execution_failed}
    end
  end
end
