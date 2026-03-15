defmodule Mix.Tasks.Terrain.Cards.Import do
  @moduledoc """
  Import flashcards from a CSV file.

  Usage:
    mix terrain.cards.import --path /path/to/cards.csv [--track "Override Name"]

  Options:
    --path    Path to CSV file (required)
    --track   Track name (optional, defaults to "Default" or CSV "track" column)
  """

  use Mix.Task
  require Logger

  alias BotArmyTerrain.Ingestion.CardImporter

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start", [])

    case parse_args(args) do
      {:ok, opts} ->
        import_cards(opts)

      {:error, msg} ->
        Mix.raise(msg)
    end
  end

  defp parse_args(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [path: :string, track: :string])

    case Keyword.get(opts, :path) do
      nil -> {:error, "Missing required --path option"}
      _path -> {:ok, opts}
    end
  end

  defp import_cards(opts) do
    path = Keyword.fetch!(opts, :path)

    case CardImporter.import_csv(path) do
      {:ok, %{tracks: track_count, cards: card_count, errors: errors}} ->
        Logger.info("✓ Imported #{card_count} cards across #{track_count} tracks")

        if not Enum.empty?(errors) do
          Logger.warning("Errors: #{inspect(errors)}")
        end

      {:error, reason} ->
        Mix.raise("Import failed: #{inspect(reason)}")
    end
  end
end
