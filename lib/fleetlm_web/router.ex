defmodule FleetlmWeb.Router do
  use FleetlmWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", FleetlmWeb do
    pipe_through :api

    # Agent CRUD
    resources "/agents", AgentController, except: [:new, :edit]

    # Session operations
    get "/sessions", SessionController, :index
    post "/sessions", SessionController, :create
    get "/sessions/:id", SessionController, :show
    get "/sessions/:session_id/messages", SessionController, :messages
    post "/sessions/:session_id/messages", SessionController, :append_message
    post "/sessions/:session_id/read", SessionController, :mark_read
    delete "/sessions/:session_id", SessionController, :delete
  end
end
