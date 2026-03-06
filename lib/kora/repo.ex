defmodule Kora.Repo do
  use Ecto.Repo,
    otp_app: :kora,
    adapter: Ecto.Adapters.SQLite3
end
