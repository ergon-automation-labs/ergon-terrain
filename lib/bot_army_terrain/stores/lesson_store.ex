defmodule BotArmyTerrain.LessonStore do
  use GenServer
  require Logger
  import Ecto.Query

  alias BotArmyTerrain.{Repo, Schemas.Lesson}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  # Public API — bypass GenServer inbox, query Repo directly

  @doc "Store or update a lesson. Upserts by chunk_id."
  def store_lesson(attrs) do
    %Lesson{}
    |> Lesson.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:track_id, :title, :explanation, :external_link, :difficulty, :generated_at, :quiz_question, :quiz_options, :quiz_correct_index, :quiz_questions, :host_intro, :host_correct, :host_wrong, :npc_players, :updated_at]},
      conflict_target: :chunk_id
    )
  end

  @doc "Get a lesson by chunk_id."
  def get_lesson_by_chunk(chunk_id) do
    Repo.get_by(Lesson, chunk_id: chunk_id)
  end

  @doc "List all lessons, ordered by insertion time."
  def list_lessons do
    Repo.all(from l in Lesson, order_by: [asc: l.inserted_at])
  end

  @doc "List all lessons for a track, ordered by insertion time."
  def list_lessons_by_track(track_id) do
    Repo.all(from l in Lesson, where: l.track_id == ^track_id, order_by: [asc: l.inserted_at])
  end

  @doc "Update a lesson."
  def update_lesson(lesson, attrs) do
    lesson
    |> Lesson.changeset(attrs)
    |> Repo.update()
  end

  @doc "Find similar lessons using pgvector cosine distance."
  def find_similar_lessons(embedding_vector, limit \\ 5) do
    Repo.all(
      from l in Lesson,
      where: not is_nil(l.embedding_vector),
      order_by: fragment("embedding_vector <=> ?", ^embedding_vector),
      limit: ^limit,
      select: %{
        id: l.id,
        chunk_id: l.chunk_id,
        title: l.title,
        explanation: l.explanation,
        external_link: l.external_link,
        similarity: fragment("1 - (embedding_vector <=> ?)", ^embedding_vector)
      }
    )
  end
end
