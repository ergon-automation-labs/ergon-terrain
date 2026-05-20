defmodule BotArmyTerrain.SM2Test do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyTerrain.SM2

  describe "schedule/2" do
    test "quality 5 (perfect): increases interval and improves ease factor" do
      card = %{
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 1
      }

      result = SM2.schedule(card, 5)

      assert result.repetitions == 2
      assert result.interval_days == 3
      assert result.ease_factor > 2.5
      assert result.state == "learning"
    end

    test "quality 3 (pass): increases interval, ease factor slightly decreases" do
      card = %{
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 0
      }

      result = SM2.schedule(card, 3)

      assert result.repetitions == 1
      assert result.interval_days == 1
      # Quality 3: EF = 2.5 + 0.1 - (5-3) * (0.08 + 2*0.02) = 2.5 + 0.1 - 0.24 = 2.36
      assert_in_delta result.ease_factor, 2.36, 0.0001
      assert result.state == "learning"
    end

    test "quality 0 (fail): resets repetitions and interval" do
      card = %{
        ease_factor: 2.5,
        interval_days: 10,
        repetitions: 5
      }

      result = SM2.schedule(card, 0)

      assert result.repetitions == 0
      assert result.interval_days == 1
      assert result.state == "learning"
      assert result.ease_factor < 2.5
    end

    test "quality 1: resets with ease factor degradation" do
      card = %{
        ease_factor: 2.5,
        interval_days: 5,
        repetitions: 2
      }

      result = SM2.schedule(card, 1)

      assert result.repetitions == 0
      assert result.interval_days == 1
      assert result.ease_factor < 2.5
      assert result.state == "learning"
    end

    test "quality 2: resets with ease factor degradation" do
      card = %{
        ease_factor: 2.5,
        interval_days: 8,
        repetitions: 3
      }

      result = SM2.schedule(card, 2)

      assert result.repetitions == 0
      assert result.interval_days == 1
      assert result.ease_factor < 2.5
      assert result.state == "learning"
    end

    test "ease factor has floor of 1.3" do
      card = %{
        ease_factor: 1.5,
        interval_days: 1,
        repetitions: 0
      }

      result = SM2.schedule(card, 0)

      assert result.ease_factor >= 1.3
    end

    test "first review (rep=0) → second review (rep=1): interval = 1" do
      card = %{
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 0
      }

      result = SM2.schedule(card, 4)

      assert result.repetitions == 1
      assert result.interval_days == 1
    end

    test "second review (rep=1) → third review (rep=2): interval = 3" do
      card = %{
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 1
      }

      result = SM2.schedule(card, 4)

      assert result.repetitions == 2
      assert result.interval_days == 3
    end

    test "third review (rep=2) → fourth review (rep=3): interval = prev * EF" do
      card = %{
        ease_factor: 2.5,
        interval_days: 3,
        repetitions: 2
      }

      result = SM2.schedule(card, 4)

      assert result.repetitions == 3
      # 3 * 2.5 = 7.5 rounds to 8
      assert result.interval_days == 8
      assert result.state == "review"
    end

    test "quality < 3 stays in learning state" do
      card = %{
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 0
      }

      assert SM2.schedule(card, 0).state == "learning"
      assert SM2.schedule(card, 1).state == "learning"
      assert SM2.schedule(card, 2).state == "learning"
    end

    test "quality >= 3, rep < 3 is learning" do
      card = %{
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 1
      }

      result = SM2.schedule(card, 3)
      assert result.state == "learning"
    end

    test "quality >= 3, rep >= 3 is review" do
      card = %{
        ease_factor: 2.5,
        interval_days: 3,
        repetitions: 2
      }

      result = SM2.schedule(card, 4)
      assert result.state == "review"
    end

    test "next_review_at is in the future" do
      card = %{
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 0
      }

      now = DateTime.utc_now()
      result = SM2.schedule(card, 4)

      assert DateTime.compare(result.next_review_at, now) == :gt
    end

    test "last_reviewed_at is approximately now" do
      card = %{
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 0
      }

      before = DateTime.utc_now()
      result = SM2.schedule(card, 4)
      after_time = DateTime.utc_now()

      assert DateTime.compare(result.last_reviewed_at, before) in [:eq, :gt]
      assert DateTime.compare(result.last_reviewed_at, after_time) in [:eq, :lt]
    end

    test "next_review_at is approximately interval_days in the future" do
      card = %{
        ease_factor: 2.5,
        interval_days: 1,
        repetitions: 0
      }

      before = DateTime.utc_now()
      result = SM2.schedule(card, 4)

      # Should be 1 day in the future (86_400 seconds)
      seconds_diff = DateTime.diff(result.next_review_at, before, :second)

      # Allow 1 second tolerance
      assert seconds_diff >= 86_399
      assert seconds_diff <= 86_401
    end

    test "handles missing fields with defaults" do
      card = %{}

      result = SM2.schedule(card, 4)

      assert result.ease_factor > 0
      assert result.interval_days > 0
      assert result.repetitions >= 0
      assert is_map(result)
    end
  end
end
