defmodule FastpacaWeb.FallbackController do
  use FastpacaWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end

  def call(conn, {:error, :context_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "context_not_found"})
  end

  def call(conn, {:error, {:version_conflict, current}}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "conflict", message: "Context version changed (found #{current})"})
  end

  def call(conn, {:error, :context_tombstoned}) do
    conn
    |> put_status(:conflict)
    |> json(%{error: "context_tombstoned"})
  end

  def call(conn, {:error, reason})
      when reason in [
             :invalid_message,
             :invalid_replacement,
             :invalid_replacement_message,
             :invalid_context_config,
             :invalid_metadata
           ] do
    conn
    |> put_status(:bad_request)
    |> json(%{error: to_string(reason)})
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: inspect(reason)})
  end
end
