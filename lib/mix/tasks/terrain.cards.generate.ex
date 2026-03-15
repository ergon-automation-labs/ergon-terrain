defmodule Mix.Tasks.Terrain.Cards.Generate do
  @moduledoc """
  Generate flashcards from content using LLM.

  Usage:
    mix terrain.cards.generate --path /path/to/notes.md --track "Track Name"
    mix terrain.cards.generate --text "raw content..." --track "Track Name" [--model haiku]

  Options:
    --path    Path to markdown/text file (one of --path or --text required)
    --text    Raw content string (one of --path or --text required)
    --track   Track name (required)
    --model   LLM model to use (optional, defaults to haiku)
  """

  use Mix.Task
  require Logger

  alias BotArmyTerrain.Ingestion.CardGenerator

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start", [])

    case parse_args(args) do
      {:ok, opts} ->
        generate_cards(opts)

      {:error, msg} ->
        Mix.raise(msg)
    end
  end

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [path: :string, text: :string, track: :string, model: :string])

    track = Keyword.get(opts, :track)
    path = Keyword.get(opts, :path)
    text = Keyword.get(opts, :text)

    cond do
      track == nil ->
        {:error, "Missing required --track option"}

      path != nil ->
        {:ok, Keyword.put(opts, :track_name, track)}

      text != nil ->
        {:ok, Keyword.put(opts, :track_name, track)}

      true ->
        {:error, "Exactly one of --path or --text is required"}
    end
  end

  defp generate_cards(opts) do
    path = Keyword.get(opts, :path)
    text = Keyword.get(opts, :text)
    track_name = Keyword.get(opts, :track_name)
    model = Keyword.get(opts, :model, "haiku")

    result =
      if path do
        CardGenerator.generate_from_path(path, track_name: track_name, model: model)
      else
        CardGenerator.generate_from_text(text, track_name: track_name, model: model)
      end

    case result do
      {:ok, %{chunks: chunk_count}} ->
        Logger.info(
          "✓ Sent #{chunk_count} LLM requests for track '#{track_name}'. Cards created asynchronously."
        )

      {:error, reason} ->
        Mix.raise("Generation failed: #{inspect(reason)}")
    end
  end
end
