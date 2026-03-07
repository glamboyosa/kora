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

    # Print port for Tauri sidecar handshake
    # We do this in a task to ensure it runs after endpoint startup
    Task.start(fn ->
      # Give endpoint a moment to bind
      Process.sleep(1000)

      # Attempt to find the bound port.
      # In dev, it is fixed at 4000.
      # In prod with port 0, we would need to query ThousandIsland.

      port =
        case Application.get_env(:kora, KoraWeb.Endpoint)[:http][:port] do
          0 ->
            # Fallback to 0 if dynamic, printed to stdout later if possible
            0

          p ->
            p
        end

      if port > 0 do
        IO.puts("KORA_PORT=#{port}")
      end
    end)

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
