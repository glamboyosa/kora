defmodule Kora.Repo.Migrations.AddToolCallIdAndToolNameToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :tool_call_id, :string
      add :tool_name, :string
    end
  end
end
