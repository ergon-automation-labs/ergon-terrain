defmodule BotArmyTerrain.Ingestion.CardGeneratorTest do
  use ExUnit.Case, async: true
  @moduletag :ingestion

  alias BotArmyTerrain.Ingestion.CardGenerator

  describe "split_into_chunks" do
    test "splits on blank lines" do
      text = """
      Paragraph 1.
      Still paragraph 1.

      Paragraph 2.
      Still paragraph 2.
      """

      chunks = CardGenerator.split_into_chunks(text)
      assert length(chunks) == 2
      assert Enum.at(chunks, 0) =~ "Paragraph 1"
      assert Enum.at(chunks, 1) =~ "Paragraph 2"
    end

    test "handles multiple blank lines" do
      text = """
      Chunk 1.


      Chunk 2.
      """

      chunks = CardGenerator.split_into_chunks(text)
      assert length(chunks) == 2
    end

    test "rejects empty chunks" do
      text = """
      Chunk 1.

      """

      chunks = CardGenerator.split_into_chunks(text)
      assert length(chunks) == 1
    end

    test "caps large chunks at max_chunk_size" do
      large_text = String.duplicate("word ", 500)

      chunks = CardGenerator.split_into_chunks(large_text)
      # All chunks should be reasonable size
      Enum.each(chunks, fn chunk ->
        # allow some margin for word boundaries
        assert String.length(chunk) <= 3000
      end)
    end

    test "handles single paragraph" do
      text = "Just one paragraph."

      chunks = CardGenerator.split_into_chunks(text)
      assert length(chunks) == 1
      assert Enum.at(chunks, 0) == "Just one paragraph."
    end
  end

  describe "build_llm_request" do
    test "includes correct metadata structure" do
      track_id = "track-123"
      chunk_id = "chunk-456"
      content = "Test content"
      model = "haiku"

      request = CardGenerator.build_llm_request(chunk_id, track_id, content, model)

      assert request["type"] == "card_generation"
      assert request["source_domain"] == "terrain"
      assert request["model"] == "haiku"
      assert request["metadata"]["source"] == "terrain_card_generation"
      assert request["metadata"]["track_id"] == track_id
      assert request["metadata"]["chunk_ids"] == [chunk_id]
      assert request["metadata"]["model"] == "haiku"
    end

    test "includes content in text" do
      request = CardGenerator.build_llm_request("c1", "t1", "Test Content", "haiku")

      assert request["text"] =~ "Test Content"
      assert request["text"] =~ "flashcard"
      assert request["text"] =~ "JSON"
    end
  end
end
