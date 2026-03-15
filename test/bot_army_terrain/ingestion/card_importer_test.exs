defmodule BotArmyTerrain.Ingestion.CardImporterTest do
  use ExUnit.Case
  import Mox

  alias BotArmyTerrain.Ingestion.CardImporter

  setup :verify_on_exit!

  describe "import_string" do
    test "valid CSV with front, back, track creates cards" do
      csv = """
      front,back,track
      "What is Elixir?","A functional language","Elixir Basics"
      "What is BEAM?","The Erlang VM","Elixir Basics"
      """

      expect(BotArmyTerrain.CardStoreMock, :create_card, 2, fn _attrs -> {:ok, %{id: "card-1"}} end)
      expect(BotArmyTerrain.TrackStoreMock, :get_or_create_track_by_name, fn _name ->
        {:ok, %{id: "track-1"}}
      end)
      expect(BotArmyTerrain.TrackStoreMock, :update_card_count_from_store, fn _track_id -> {:ok, %{}} end)
      expect(BotArmyTerrain.EmbedWorkerMock, :queue_card, 2, fn _card_id -> :ok end)

      assert {:ok, %{tracks: 1, cards: 2, errors: []}} = CardImporter.import_string(csv)
    end

    test "missing card_type defaults to basic" do
      csv = """
      front,back
      "Q1?","A1"
      """

      expect(BotArmyTerrain.CardStoreMock, :create_card, 1, fn attrs ->
        assert attrs[:card_type] == "basic"
        {:ok, %{id: "card-1"}}
      end)
      expect(BotArmyTerrain.TrackStoreMock, :get_or_create_track_by_name, fn _name ->
        {:ok, %{id: "track-1"}}
      end)
      expect(BotArmyTerrain.TrackStoreMock, :update_card_count_from_store, fn _track_id -> {:ok, %{}} end)
      expect(BotArmyTerrain.EmbedWorkerMock, :queue_card, 1, fn _card_id -> :ok end)

      assert {:ok, %{tracks: 1, cards: 1, errors: []}} = CardImporter.import_string(csv)
    end

    test "multi-track CSV groups correctly" do
      csv = """
      front,back,track
      "Q1?","A1","Track A"
      "Q2?","A2","Track A"
      "Q3?","A3","Track B"
      """

      expect(BotArmyTerrain.CardStoreMock, :create_card, 3, fn _attrs -> {:ok, %{id: "card-1"}} end)
      expect(BotArmyTerrain.TrackStoreMock, :get_or_create_track_by_name, 2, fn _name ->
        {:ok, %{id: "track-1"}}
      end)
      expect(BotArmyTerrain.TrackStoreMock, :update_card_count_from_store, 2, fn _track_id -> {:ok, %{}} end)
      expect(BotArmyTerrain.EmbedWorkerMock, :queue_card, 3, fn _card_id -> :ok end)

      assert {:ok, %{tracks: 2, cards: 3, errors: []}} = CardImporter.import_string(csv)
    end

    test "empty CSV returns zero cards and tracks" do
      csv = """
      front,back,track
      """

      assert {:ok, %{tracks: 0, cards: 0, errors: []}} = CardImporter.import_string(csv)
    end

    test "missing front/back returns error" do
      csv = """
      a,b,c
      1,2,3
      """

      assert {:error, :missing_columns} = CardImporter.import_string(csv)
    end

    test "default track is Default when not specified" do
      csv = """
      front,back
      "Q1?","A1"
      """

      expect(BotArmyTerrain.CardStoreMock, :create_card, 1, fn _attrs -> {:ok, %{id: "card-1"}} end)
      expect(BotArmyTerrain.TrackStoreMock, :get_or_create_track_by_name, fn _name ->
        {:ok, %{id: "track-1"}}
      end)
      expect(BotArmyTerrain.TrackStoreMock, :update_card_count_from_store, fn _track_id -> {:ok, %{}} end)
      expect(BotArmyTerrain.EmbedWorkerMock, :queue_card, 1, fn _card_id -> :ok end)

      assert {:ok, %{tracks: 1, cards: 1, errors: []}} = CardImporter.import_string(csv)
    end

    test "card_type values are preserved" do
      csv = """
      front,back,card_type
      "Q1?","A1","cloze"
      "Q2?","A2","definition"
      """

      expect(BotArmyTerrain.CardStoreMock, :create_card, 2, fn attrs ->
        assert attrs[:card_type] in ["cloze", "definition"]
        {:ok, %{id: "card-1"}}
      end)
      expect(BotArmyTerrain.TrackStoreMock, :get_or_create_track_by_name, fn _name ->
        {:ok, %{id: "track-1"}}
      end)
      expect(BotArmyTerrain.TrackStoreMock, :update_card_count_from_store, fn _track_id -> {:ok, %{}} end)
      expect(BotArmyTerrain.EmbedWorkerMock, :queue_card, 2, fn _card_id -> :ok end)

      assert {:ok, %{tracks: 1, cards: 2, errors: []}} = CardImporter.import_string(csv)
    end
  end
end
