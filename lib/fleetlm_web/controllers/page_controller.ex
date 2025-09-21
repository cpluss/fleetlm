defmodule FleetlmWeb.PageController do
  use FleetlmWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
