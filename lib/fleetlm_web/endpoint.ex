defmodule FleetlmWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :fleetlm

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_fleetlm_key",
    signing_salt: "eLLrwmM+",
    same_site: "Lax"
  ]

  socket "/socket", FleetlmWeb.UserSocket,
    websocket: [compress: true, timeout: 120_000],
    longpoll: false

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :fleetlm
  end

  plug Plug.RequestId
  plug PromEx.Plug, prom_ex_module: Fleetlm.Observability.PromEx
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug FleetlmWeb.Router
end
