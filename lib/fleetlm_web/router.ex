defmodule FleetlmWeb.Router do
  use FleetlmWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FleetlmWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FleetlmWeb do
    pipe_through :browser

    get "/", PageController, :home
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

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:fleetlm, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard"
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
