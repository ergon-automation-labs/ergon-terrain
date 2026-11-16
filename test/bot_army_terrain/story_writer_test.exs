defmodule BotArmyTerrain.StoryWriterTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyTerrain.{Story, StoryBuilder, StoryWriter}

  @cards [
    %{
      "front" => "What is a door?",
      "back" => "**A decision** about who may see the row.",
      "deck" => "The System"
    },
    %{
      "front" => "Who holds the pen?",
      "back" => "**The one who writes the row.**",
      "deck" => "The System"
    },
    %{
      "front" => "What does a green light mean?",
      "back" => "**A claim,** not a fact.",
      "deck" => "The System"
    },
    %{
      "front" => "What is the smallest unit?",
      "back" => "**The blast radius.**",
      "deck" => "The System"
    }
  ]

  @plan %{
    "start" => "first",
    "scenes" => [
      %{
        "id" => "first",
        "title" => "The Door",
        "text" => "A door waits.",
        "card" => "What is a door?",
        "prompt" => "What is it?",
        "right" => "The door opens.",
        "wrong" => "The door stays shut.",
        "wrong_label" => "A wall."
      },
      %{
        "id" => "second",
        "title" => "The Pen",
        "text" => "A pen waits.",
        "card" => "Who holds the pen?",
        "prompt" => "Who?",
        "right" => "The row changes.",
        "wrong" => "The row stays.",
        "wrong_label" => "The reader."
      },
      %{
        "id" => "third",
        "title" => "The Light",
        "text" => "A light waits.",
        "card" => "What does a green light mean?",
        "prompt" => "What does it mean?",
        "right" => "It is a claim.",
        "wrong" => "It is a fact.",
        "wrong_label" => "A promise."
      },
      %{
        "id" => "fourth",
        "title" => "The Radius",
        "text" => "A console waits.",
        "card" => "What is the smallest unit?",
        "prompt" => "What is it?",
        "right" => "The blast radius.",
        "wrong" => "The dashboard.",
        "wrong_label" => "The report."
      }
    ],
    "end" => %{"title" => "End", "text" => "The corridor lets you go."}
  }

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "terrain_writer_test_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:bot_army_terrain, :story_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      Application.delete_env(:bot_army_terrain, :story_dir)
      Application.delete_env(:bot_army_terrain, :story_card_loader)
      Application.delete_env(:bot_army_terrain, :story_submitter)
    end)
  end

  test "the prompt carries the lesson and every exact card front" do
    spec = Story.season_chapter("ch3")
    prompt = StoryWriter.prompt(spec, Story.chapter("ch2"), @cards)

    assert prompt =~ "The smallest unit is the blast radius."
    assert prompt =~ "Chapter Three — The Smallest Unit"
    assert prompt =~ "What is a door?"
    assert prompt =~ "Who holds the pen?"
    assert prompt =~ "Return ONLY a JSON object"
  end

  test "a fenced answer is still a plan" do
    assert {:ok, %{"scenes" => scenes}} =
             StoryWriter.parse_plan("```json\n" <> Jason.encode!(@plan) <> "\n```")

    assert length(scenes) == 4
  end

  test "the template chapter is playable and names the lesson" do
    spec = Story.season_chapter("ch3")
    plan = StoryWriter.fallback_plan(spec, @cards)

    assert {:ok, chapter} = StoryBuilder.build(plan, @cards)
    assert chapter["lesson"] == "The smallest unit is the blast radius."
    assert map_size(chapter["scenes"]) == 5
    assert chapter["scenes"]["end"]["text"] =~ "The smallest unit is the blast radius."
  end

  test "a completion is compiled, published, and read back by the story" do
    me = self()

    Application.put_env(:bot_army_terrain, :story_card_loader, fn _tenant, "The System" ->
      {:ok, @cards}
    end)

    Application.put_env(:bot_army_terrain, :story_submitter, fn prompt, job ->
      send(me, {:story_prompt, job.id, prompt})
      {:ok, "prompt-1"}
    end)

    start_supervised!(StoryWriter)

    assert {:ok, :queued} = StoryWriter.ensure("tenant", "ch2")
    job_id = StoryWriter.status().active
    assert is_binary(job_id)
    assert_receive {:story_prompt, ^job_id, _prompt}, 1_000

    assert {:ok, :writing} = StoryWriter.ensure("tenant", "ch2")

    answer = @plan |> Map.put("id", "ch3") |> Jason.encode!()

    StoryWriter.complete(%{
      "source_metadata" => %{"story_job_id" => job_id, "source_domain" => "story_generation"},
      "payload" => %{"completion" => answer, "original_prompt_id" => "prompt-1"}
    })

    wait_until(fn -> Story.chapter("ch3") != nil end)

    chapter = Story.chapter("ch3")
    assert chapter["title"] == "Chapter Three — The Smallest Unit"
    assert chapter["lesson"] == "The smallest unit is the blast radius."
    assert chapter["start"] == "first"
    wait_until(fn -> StoryWriter.status().active == nil end)
  end

  defp wait_until(fun, tries \\ 50)

  defp wait_until(_fun, 0), do: flunk("the writer did not finish in time")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, tries - 1)
    end
  end
end
