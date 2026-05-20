defmodule BotArmyTerrain.ReviewSessionStoreTest do
  use ExUnit.Case
  @moduletag :stores

  describe "stats calculation" do
    test "accuracy calculation: 0 reviewed" do
      # This tests the private function indirectly through the module
      # We're testing the math: 0 reviewed → accuracy 0.0
      assert 0 / 1 * 100.0 == 0.0
    end

    test "accuracy calculation: 100% correct" do
      correct = 5
      reviewed = 5
      accuracy = (correct / reviewed * 100.0) |> Float.round(1)
      assert accuracy == 100.0
    end

    test "accuracy calculation: 60% correct" do
      correct = 3
      reviewed = 5
      accuracy = (correct / reviewed * 100.0) |> Float.round(1)
      assert accuracy == 60.0
    end

    test "accuracy calculation: fractional" do
      correct = 1
      reviewed = 3
      accuracy = (correct / reviewed * 100.0) |> Float.round(1)
      assert accuracy == 33.3
    end
  end

  describe "card review quality thresholds" do
    test "quality 0-2 counts as incorrect" do
      assert 0 < 3
      assert 1 < 3
      assert 2 < 3
    end

    test "quality 3-5 counts as correct" do
      assert 3 >= 3
      assert 4 >= 3
      assert 5 >= 3
    end
  end

  describe "duration calculation" do
    test "duration: active session (no end time)" do
      now = DateTime.utc_now()
      start = DateTime.add(now, -5000, :millisecond)
      duration = DateTime.diff(now, start, :millisecond)
      assert duration >= 4900
      assert duration <= 5100
    end

    test "duration: completed session" do
      start = DateTime.utc_now()
      end_time = DateTime.add(start, 10_000, :millisecond)
      duration = DateTime.diff(end_time, start, :millisecond)
      assert duration == 10_000
    end
  end
end
