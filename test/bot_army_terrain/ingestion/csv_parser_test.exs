defmodule BotArmyTerrain.Ingestion.CsvParserTest do
  use ExUnit.Case, async: true
  @moduletag :ingestion

  alias BotArmyTerrain.Ingestion.CsvParser

  @sample """
  front,back,track,tags
  "What is the BEAM?","The Erlang VM","Elixir Bootcamp","beam"
  "What is OTP?","Open Telecom Platform","Elixir Bootcamp","otp"
  """

  test "parse_string returns rows with front, back, track, tags" do
    assert {:ok, rows} = CsvParser.parse_string(@sample)
    assert length(rows) == 2
    [r1, r2] = rows
    assert r1["front"] == "What is the BEAM?"
    assert r1["back"] == "The Erlang VM"
    assert r1["track"] == "Elixir Bootcamp"
    assert r1["tags"] == "beam"
    assert r2["front"] == "What is OTP?"
    assert r2["track"] == "Elixir Bootcamp"
  end

  test "parse_string empty returns empty list" do
    assert {:ok, []} = CsvParser.parse_string("")
    assert {:ok, []} = CsvParser.parse_string("front,back,track,tags\n")
  end

  test "parse_string missing front/back returns error" do
    assert {:error, :missing_columns} = CsvParser.parse_string("a,b,c\n1,2,3\n")
  end
end
