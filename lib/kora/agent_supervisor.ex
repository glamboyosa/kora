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
    # opts should include `id` and `module` (Kora.Agent).
    # The id is needed to restore the agent from the DB.
    # We use a unique name for the process based on id.

    # agent_id = Keyword.get(opts, :id)
    DynamicSupervisor.start_child(__MODULE__, {Kora.Agent, opts})
  end

  def stop_agent(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
