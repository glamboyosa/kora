defmodule Kora.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    create table(:workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string
      add :definition, :map
      timestamps(type: :utc_datetime_usec)
    end

    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :nilify_all)
      add :status, :string
      add :goal, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all)
      add :parent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :name, :string
      add :model, :string
      add :status, :string
      add :system_prompt, :text
      add :goal, :text
      add :context, :text

      # SQLite doesn't support arrays natively, Ecto emulates it via JSON usually with ecto_sqlite3
      add :tools, {:array, :string}
      add :result, :text
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:agents, [:session_id])
    create index(:agents, [:parent_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all)
      add :role, :string
      add :content, :text
      add :tool_calls, :map
      timestamps(type: :utc_datetime_usec)
    end

    create index(:messages, [:agent_id])

    create table(:tool_results, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all)
      add :tool_name, :string
      add :input, :map
      add :output, :text
      add :error, :text
      add :duration_ms, :integer
      timestamps(type: :utc_datetime_usec)
    end

    create index(:tool_results, [:agent_id])

    create table(:cost_ledger, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all)
      add :model, :string
      add :prompt_tokens, :integer
      add :completion_tokens, :integer
      add :cost_usd, :decimal
      timestamps(type: :utc_datetime_usec)
    end

    create index(:cost_ledger, [:agent_id])
  end
end
