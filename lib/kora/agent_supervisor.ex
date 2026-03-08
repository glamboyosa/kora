defmodule Kora.AgentSupervisor do
  use DynamicSupervisor

  def start_link(arg) do
    DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_agent(opts) do
    # opts must include :id (UUID from Kora.Agents.create_agent / Repo.insert).
    # The Agent GenServer registers under this id in the Registry so it can be addressed
    # by UUID; init/1 loads state from the DB using this id.
    DynamicSupervisor.start_child(__MODULE__, {Kora.Agent, opts})
  end

  def stop_agent(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
