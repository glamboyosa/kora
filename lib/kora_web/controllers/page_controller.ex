defmodule KoraWeb.PageController do
  use KoraWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
