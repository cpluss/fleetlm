defmodule FastpacaWeb.HealthController do
  use FastpacaWeb, :controller

  def health(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
