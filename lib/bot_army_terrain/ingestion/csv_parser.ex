defmodule BotArmyTerrain.Ingestion.CsvParser do
  @moduledoc """
  Parses flashcard CSV (front, back, track, tags).
  Returns a list of row maps. Used by IngestionWorker for deck import.
  """

  def parse_path(path) do
    case File.read(path) do
      {:ok, body} -> parse_string(body)
      {:error, reason} -> {:error, reason}
    end
  end

  def parse_string(body) do
    lines = String.split(body, ~r/\r?\n/, trim: true)
    case lines do
      [] -> {:ok, []}
      [header | rest] ->
        keys = parse_line(header)
        if "front" in keys and "back" in keys do
          rows = Enum.map(rest, fn line -> line_to_row(parse_line(line), keys) end)
          {:ok, Enum.reject(rows, &is_nil/1)}
        else
          {:error, :missing_columns}
        end
    end
  end

  defp parse_line(line) do
    # Handle quoted fields: "a,b", "c" -> ["a,b", "c"]
    line
    |> String.split(~r/,(?=(?:[^"]*"[^"]*")*[^"]*$)/)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn s ->
      if String.starts_with?(s, "\"") and String.ends_with?(s, "\"") do
        String.slice(s, 1..-2//1) |> String.replace("\"\"", "\"")
      else
        s
      end
    end)
  end

  defp line_to_row(values, keys) do
    if Enum.any?(values, &(&1 != "")) do
      keys
      |> Enum.zip(values)
      |> Map.new(fn {k, v} -> {String.downcase(k), v} end)
    else
      nil
    end
  end
end
