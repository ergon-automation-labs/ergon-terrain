defmodule BotArmyTerrain.Repo.Migrations.AddQuizQuestionsToLessons do
  use Ecto.Migration

  def change do
    alter table(:lessons, prefix: "terrain") do
      add :quiz_questions, {:array, :map}, default: []
    end
  end
end
