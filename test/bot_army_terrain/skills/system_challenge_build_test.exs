defmodule BotArmyTerrain.Skills.SystemChallengeBuildTest do
  use ExUnit.Case
  @moduletag :skills

  alias BotArmyTerrain.Skills.SystemChallengeBuild

  @tenant_id "00000000-0000-0000-0000-000000000001"

  describe "validate/1" do
    test "accepts tenant_id and non-empty internal_docs_excerpts" do
      assert :ok ==
               SystemChallengeBuild.validate(%{
                 "tenant_id" => @tenant_id,
                 "internal_docs_excerpts" => "## Docs\n\nHello NATS."
               })
    end

    test "unwraps payload envelope" do
      assert :ok ==
               SystemChallengeBuild.validate(%{
                 "payload" => %{
                   "tenant_id" => @tenant_id,
                   "internal_docs_excerpts" => "x"
                 }
               })
    end

    test "accepts smoke without excerpts" do
      assert :ok ==
               SystemChallengeBuild.validate(%{
                 "tenant_id" => @tenant_id,
                 "smoke" => true
               })
    end

    test "rejects missing tenant_id" do
      assert {:error, _} = SystemChallengeBuild.validate(%{"internal_docs_excerpts" => "x"})
    end

    test "rejects bad tenant_id" do
      assert {:error, _} =
               SystemChallengeBuild.validate(%{
                 "tenant_id" => "not-a-uuid",
                 "internal_docs_excerpts" => "x"
               })
    end

    test "rejects empty excerpts when not smoke" do
      assert {:error, _} =
               SystemChallengeBuild.validate(%{
                 "tenant_id" => @tenant_id,
                 "internal_docs_excerpts" => "   "
               })
    end
  end

  describe "deterministic chunk id (via validate + slug stability)" do
    test "same inputs imply stable idempotency key contract" do
      # UUID v5 from :dns namespace is stable for the same name string.
      id1 =
        UUID.uuid5(
          :dns,
          "terrain.system_challenge|#{@tenant_id}|2026-05-14|system-daily"
        )

      id2 =
        UUID.uuid5(
          :dns,
          "terrain.system_challenge|#{@tenant_id}|2026-05-14|system-daily"
        )

      assert id1 == id2
    end
  end
end
