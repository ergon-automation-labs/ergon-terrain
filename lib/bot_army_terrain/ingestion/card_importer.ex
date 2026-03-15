defmodule BotArmyTerrain.Ingestion.CardImporter do
  @moduledoc """
  Mode 1: CSV with front/back/track columns → Card records immediately.
  Plain module (no GenServer). Expects CSV columns: front, back, card_type (optional), track (optional).
  """

  require Logger

  alias BotArmyTerrain.Ingestion.CsvParser

  # Allow mocking via Application config (for tests)
  defp card_store, do: Application.get_env(:bot_army_terrain, :card_store, BotArmyTerrain.CardStore)
  defp track_store, do: Application.get_env(:bot_army_terrain, :track_store, BotArmyTerrain.TrackStore)

  @doc "Import cards from CSV file."
  def import_csv(path) do
    case CsvParser.parse_path(path) do
      {:ok, rows} -> import_rows(rows)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Import cards from CSV string (for tests)."
  def import_string(body) do
    case CsvParser.parse_string(body) do
      {:ok, rows} -> import_rows(rows)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Import rows (list of maps with front, back, card_type, track keys)."
  def import_rows(rows) do
    rows_by_track = group_by_track(rows)

    track_results =
      Enum.map(rows_by_track, fn {track_name, track_rows} ->
        case import_track(track_name, track_rows) do
          {:ok, {track, cards}} -> {:ok, {track, cards}}
          {:error, reason} -> {:error, reason}
        end
      end)

    # Count successful tracks and cards
    successful = Enum.filter(track_results, &match?({:ok, _}, &1))
    errors = Enum.filter(track_results, &match?({:error, _}, &1))

    total_cards =
      successful
      |> Enum.map(fn {:ok, {_, cards}} -> cards end)
      |> Enum.sum()

    if Enum.empty?(errors) do
      {:ok, %{tracks: length(successful), cards: total_cards, errors: []}}
    else
      error_msgs = Enum.map(errors, fn {:error, reason} -> inspect(reason) end)
      {:ok, %{tracks: length(successful), cards: total_cards, errors: error_msgs}}
    end
  end

  # Group rows by track column (default "Default")
  defp group_by_track(rows) do
    rows
    |> Enum.group_by(fn row -> row["track"] || row["Track"] || "Default" end)
  end

  # Import all cards for a single track
  defp import_track(track_name, track_rows) do
    with {:ok, track} <- track_store().get_or_create_track_by_name(track_name),
         {success_count, error_count} <- create_cards_for_track(track.id, track_rows) do
      if error_count > 0 do
        Logger.warning(
          "Track '#{track_name}': #{success_count} cards created, #{error_count} failed"
        )
      end

      track_store().update_card_count_from_store(track.id)
      {:ok, {track, success_count}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Create cards for a track, return {success_count, error_count}
  defp create_cards_for_track(track_id, rows) do
    results =
      rows
      |> Enum.map(fn row ->
        attrs = %{
          track_id: track_id,
          front: row["front"] || row["Front"] || "",
          back: row["back"] || row["Back"] || "",
          card_type: row["card_type"] || row["Card Type"] || "basic",
          generation_model: nil
        }

        case card_store().create_card(attrs) do
          {:ok, _card} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end)

    success_count = Enum.count(results, &match?(:ok, &1))
    error_count = Enum.count(results, &match?({:error, _}, &1))

    {success_count, error_count}
  end
end
