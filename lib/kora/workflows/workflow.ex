defmodule Kora.Workflows.Workflow do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflows" do
    field :name, :string
    # JSON
    field :definition, :map

    has_many :sessions, Kora.Sessions.Session

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [:name, :definition])
    |> validate_required([:name, :definition])
  end
end
