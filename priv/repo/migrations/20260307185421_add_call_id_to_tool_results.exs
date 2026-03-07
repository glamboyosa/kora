defmodule Kora.Repo.Migrations.AddCallIdToToolResults do
  use Ecto.Migration

  def change do
    alter table(:tool_results) do
      add :call_id, :string
    end

    create unique_index(:tool_results, [:call_id])
  end
end
