defmodule KoraWeb.Router do
  use KoraWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KoraWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", KoraWeb do
    pipe_through :browser

    live "/", SessionLive.Index, :index
    live "/sessions/:id", SessionLive.Show, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", KoraWeb do
  #   pipe_through :api
  # end
end
