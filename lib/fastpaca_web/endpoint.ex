defmodule FastpacaWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :fastpaca

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_fleetlm_key",
    signing_salt: "eLLrwmM+",
    same_site: "Lax"
  ]

  # WebSocket for context updates
  socket "/socket", FastpacaWeb.UserSocket,
    websocket: [compress: true, timeout: 120_000],
    longpoll: false

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug FastpacaWeb.Router
end
