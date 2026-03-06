import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kora start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :kora, KoraWeb.Endpoint, server: true
end

if config_env() != :test do
  # Load .env from project root and merge with system env (system overrides). Then push into
  # the process environment so System.get_env/1 sees them everywhere (config, Application.get_env, etc.).
  env_file = Path.join([__DIR__, "..", ".env"])
  merged =
    if File.exists?(env_file) do
      Dotenvy.source!([env_file, System.get_env()])
    else
      System.get_env()
    end

  for {key, value} <- merged, is_binary(key) and value != nil, do: System.put_env(key, to_string(value))

  config :kora,
    openrouter_api_key:
      System.get_env("OPENROUTER_API_KEY") ||
        raise("OPENROUTER_API_KEY is missing. Set it in .env or your environment."),
    default_model: System.get_env("DEFAULT_MODEL") || "google/gemini-3.1-pro-preview",
    # Optional: for real web_search results (Exa). Without it, web_search returns mock data.
    exa_api_key: System.get_env("EXA_API_KEY"),
    # Timeout in ms for waiting on a spawned subagent (default 5 min). Parent tool call returns error if exceeded.
    subagent_timeout_ms: String.to_integer(System.get_env("SUBAGENT_TIMEOUT_MS", "300000"))
end

config :kora, KoraWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/kora/kora.db
      """

  config :kora, Kora.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :kora, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :kora, KoraWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :kora, KoraWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :kora, KoraWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
