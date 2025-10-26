defmodule FastpacaWeb.Router do
  use FastpacaWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/v1", FastpacaWeb do
    pipe_through :api

    # Context lifecycle
    put "/contexts/:id", ContextController, :upsert
    get "/contexts/:id", ContextController, :show
    delete "/contexts/:id", ContextController, :delete
    patch "/contexts/:id/metadata", ContextController, :update_metadata

    # Messages
    post "/contexts/:id/messages", ContextController, :append
    get "/contexts/:id/tail", ContextController, :tail

    # LLM interface
    get "/contexts/:id/context", ContextController, :window

    # Manual compaction
    post "/contexts/:id/compact", ContextController, :compact
  end

  scope "/", FastpacaWeb do
    get "/health/live", HealthController, :live
    get "/health/ready", HealthController, :ready
  end
end
