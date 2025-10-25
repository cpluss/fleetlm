defmodule FastpacaWeb.Router do
  use FastpacaWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FastpacaWeb do
    get "/health", HealthController, :health
  end
end
