defmodule FleetlmWeb.FallbackController do
  use FleetlmWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: translate_errors(changeset)})
  end

  def call(conn, {:error, %ArgumentError{} = error}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: error.message})
  end

  def call(conn, {:error, :not_found}) do
    send_resp(conn, :not_found, "")
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: inspect(reason)})
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
