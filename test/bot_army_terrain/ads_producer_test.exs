defmodule BotArmyTerrain.AdsProducerTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyTerrain.{Ads, AdsProducer, Story}

  @chapter_three %{
    "id" => "ch3",
    "title" => "Chapter Three — The Smallest Unit",
    "start" => "one",
    "lesson" => "The smallest unit is the blast radius.",
    "scenes" => %{
      "one" => %{
        "title" => "One",
        "text" => "A room with one door.",
        "choice" => %{
          "prompt" => "Which unit do you move?",
          "card" => %{"deck" => "The System", "front" => "The smallest unit."},
          "options" => [%{"label" => "The smallest unit.", "correct" => true, "next" => "end"}]
        }
      },
      "end" => %{"end" => true}
    }
  }

  @answer %{
    "recap" => %{
      "title" => "Previously on The Quiet Archive",
      "body" =>
        "The door read the row you chose, and that row decided what you could see.\n\nThe lesson: the door decides the row.",
      "tagline" => %{"prompt" => "Where did a default decide for you today?", "max_chars" => 120}
    },
    "trailer" => %{
      "title" => "Next: The Smallest Unit",
      "body" =>
        "A single changed row is never the whole blast radius.\n\nThe next chapter follows one small move until it reaches everything it touched.",
      "tagline" => %{"prompt" => "Where will you meet that next?", "max_chars" => 120}
    }
  }

  setup do
    story_dir = tmp("story")
    ads_dir = tmp("ads")
    File.mkdir_p!(story_dir)
    File.mkdir_p!(ads_dir)
    File.write!(Path.join(story_dir, "chapter_03.json"), Jason.encode!(@chapter_three))

    Application.put_env(:bot_army_terrain, :story_dir, story_dir)
    Application.put_env(:bot_army_terrain, :ads_dir, ads_dir)

    on_exit(fn ->
      Application.delete_env(:bot_army_terrain, :story_dir)
      Application.delete_env(:bot_army_terrain, :ads_dir)
      Application.delete_env(:bot_army_terrain, :ads_submitter)
      File.rm_rf(story_dir)
      File.rm_rf(ads_dir)
    end)

    :ok
  end

  test "the drafts become two canon-bound creatives" do
    previous = Story.chapter("ch2")
    next = Story.chapter("ch3")

    [recap, trailer] = AdsProducer.build(@answer, previous, next)

    assert recap["id"] == "ch2-recap-ch3-auto"
    assert recap["kind"] == "recap"
    assert recap["air_after"] == "ch2"
    assert recap["lesson"] == previous["lesson"]
    assert trailer["lesson"] == next["lesson"]
    assert Ads.answer_free?(recap, next)
    assert Ads.answer_free?(trailer, next)
    assert {:ok, 2} = Ads.lint([recap, trailer])
  end

  test "a fenced answer is parsed, and a prose answer is refused" do
    fenced =
      "Here are the two:\n```json\n" <>
        Jason.encode!(@answer) <>
        "\n```\n"

    assert {:ok, %{"recap" => _, "trailer" => _}} = AdsProducer.parse(fenced)
    assert {:error, :not_two_creatives} = AdsProducer.parse("I wrote you a nice ad.")
  end

  test "the boundary is produced once and lands in the runtime catalogue" do
    Application.put_env(:bot_army_terrain, :ads_submitter, fn _prompt, _job -> {:ok, "p1"} end)

    start_supervised!({AdsProducer, []})

    assert {:ok, :queued} = AdsProducer.ensure("tenant", "ch2")
    assert {:ok, :writing} = AdsProducer.ensure("tenant", "ch2")

    job_id = wait_for_active()
    AdsProducer.complete(completion(job_id, Jason.encode!(@answer)))
    wait_until(fn -> AdsProducer.status().active == nil end)

    ids = Enum.map(Ads.creatives(), & &1["id"])
    assert "ch2-recap-ch3-auto" in ids
    assert "ch2-trailer-ch3-auto" in ids
    assert {:ok, _} = Ads.lint()
    assert {:ok, :ready} = AdsProducer.ensure("tenant", "ch2")
  end

  test "a model that will not answer still publishes the template" do
    Application.put_env(:bot_army_terrain, :ads_submitter, fn _prompt, _job -> {:ok, "p1"} end)

    start_supervised!({AdsProducer, []})

    assert {:ok, :queued} = AdsProducer.ensure("tenant", "ch2")
    job_id = wait_for_active()
    AdsProducer.complete(completion(job_id, "no json here"))
    wait_until(fn -> AdsProducer.status().active == nil end)

    ids = Enum.map(Ads.creatives(), & &1["id"])
    assert "ch2-recap-ch3-auto" in ids
    assert "ch2-trailer-ch3-auto" in ids
  end

  test "an authored boundary is left alone" do
    start_supervised!({AdsProducer, []})
    assert {:ok, :ready} = AdsProducer.ensure("tenant", "ch1")
  end

  defp completion(job_id, text) do
    %{
      "source_metadata" => %{"story_ads_job_id" => job_id},
      "payload" => %{"completion" => text}
    }
  end

  defp wait_for_active(attempts \\ 100) do
    case AdsProducer.status().active do
      nil when attempts > 0 ->
        Process.sleep(10)
        wait_for_active(attempts - 1)

      nil ->
        flunk("the producer never started a job")

      id ->
        id
    end
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) do
    cond do
      fun.() ->
        :ok

      attempts <= 0 ->
        flunk("the producer did not finish")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end

  defp tmp(kind) do
    Path.join(
      System.tmp_dir!(),
      "terrain_ads_producer_#{kind}_#{System.unique_integer([:positive])}"
    )
  end
end
