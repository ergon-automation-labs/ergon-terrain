defmodule BotArmyTerrain.LessonStore do
  @moduledoc "In-memory + Ecto store for generated lesson content and metadata."
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

  @doc "Store or update a lesson. Upserts by chunk_id, scoped to tenant."
  def store_lesson(tenant_id, attrs) do
    attrs = Map.put(attrs, "tenant_id", tenant_id)

    %Lesson{}
    |> Lesson.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :track_id,
           :title,
           :explanation,
           :external_link,
           :difficulty,
           :generated_at,
           :quiz_question,
           :quiz_options,
           :quiz_correct_index,
           :quiz_questions,
           :host_intro,
           :host_correct,
           :host_wrong,
           :npc_players,
           :updated_at
         ]},
      conflict_target: :chunk_id
    )
  end

  @doc "Get a lesson by chunk_id, scoped to tenant."
  def get_lesson_by_chunk(tenant_id, chunk_id) do
    case Repo.get_by(Lesson, chunk_id: chunk_id) do
      nil -> nil
      lesson -> if lesson.tenant_id == tenant_id, do: lesson, else: nil
    end
  end

  @doc "List all lessons, ordered by insertion time, scoped to tenant."
  def list_lessons(tenant_id) do
    Repo.all(from(l in Lesson, where: l.tenant_id == ^tenant_id, order_by: [asc: l.inserted_at]))
  end

  @doc "List all lessons for a track, ordered by insertion time, scoped to tenant."
  def list_lessons_by_track(tenant_id, track_id) do
    Repo.all(
      from(l in Lesson,
        where: l.tenant_id == ^tenant_id and l.track_id == ^track_id,
        order_by: [asc: l.inserted_at]
      )
    )
  end

  @doc "Update a lesson, scoped to tenant."
  def update_lesson(tenant_id, lesson, attrs) do
    if lesson.tenant_id == tenant_id do
      lesson
      |> Lesson.changeset(attrs)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc "Find similar lessons using pgvector cosine distance, scoped to tenant."
  def find_similar_lessons(tenant_id, embedding_vector, limit \\ 5) do
    Repo.all(
      from(l in Lesson,
        where: l.tenant_id == ^tenant_id and not is_nil(l.embedding_vector),
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
    )
  end
end
