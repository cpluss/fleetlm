defmodule FleetlmWeb.Plugs.CORS do
  @moduledoc false

  import Plug.Conn

  @behaviour Plug

  @allowed_methods "GET,POST,PUT,PATCH,DELETE,OPTIONS"
  @max_age "600"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
    |> put_cors_headers()
    |> send_resp(:no_content, "")
    |> halt()
  end

  def call(conn, _opts) do
    put_cors_headers(conn)
  end

  defp put_cors_headers(conn) do
    requested_headers =
      conn
      |> get_req_header("access-control-request-headers")
      |> Enum.join(",")

    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", @allowed_methods)
    |> put_resp_header("access-control-allow-headers", allow_headers(requested_headers))
    |> put_resp_header("access-control-max-age", @max_age)
  end

  defp allow_headers("") do
    "*"
  end

  defp allow_headers(requested_headers) do
    requested_headers
  end
end
