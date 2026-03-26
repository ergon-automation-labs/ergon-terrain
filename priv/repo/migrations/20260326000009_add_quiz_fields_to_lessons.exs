defmodule BotArmyTerrain.Repo.Migrations.AddQuizFieldsToLessons do
  use Ecto.Migration
  @prefix "terrain"

  def change do
    alter table(:lessons, prefix: @prefix) do
      add :quiz_question, :string
      add :quiz_options, {:array, :string}
      add :quiz_correct_index, :integer
      add :host_intro, :string
      add :host_correct, :string
      add :host_wrong, :string
      add :npc_players, :map
    end
  end
end
