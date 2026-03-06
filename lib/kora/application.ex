defmodule Kora.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start TwMerge cache
      TwMerge.Cache,
      KoraWeb.Telemetry,
      Kora.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:kora, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:kora, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Kora.PubSub},
      {Registry, keys: :unique, name: Kora.AgentRegistry},
      {Task.Supervisor, name: Kora.ToolSupervisor},
      Kora.RateLimiter,
      Kora.Orchestrator,
      Kora.AgentSupervisor,
      # Start a worker by calling: Kora.Worker.start_link(arg)
      # {Kora.Worker, arg},
      # Start to serve requests, typically the last entry
      KoraWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kora.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KoraWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # Always run migrations on startup for this local-first app
    false
  end
end
