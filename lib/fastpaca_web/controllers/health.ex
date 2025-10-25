defmodule FastpacaWeb.HealthController do
  use FastpacaWeb, :controller

  @doc """
  GET /health/live

  Liveness probe - returns ok when node is accepting traffic.
  """
  def live(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @doc """
  GET /health/ready

  Readiness probe - returns ok when Raft groups have leaders.
  """
  def ready(conn, _params) do
    # TODO: Check if Raft groups are ready
    # For now, just return ok
    json(conn, %{status: "ok"})
  end
end
