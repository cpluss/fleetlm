defmodule FastpacaWeb.ContextController do
  use FastpacaWeb, :controller

  alias Fastpaca.Context
  alias Fastpaca.Context.Config
  alias Fastpaca.Runtime

  action_fallback FastpacaWeb.FallbackController

  # Context lifecycle

  def upsert(conn, %{"id" => id, "token_budget" => budget} = params)
      when is_integer(budget) and budget > 0 do
    trigger_ratio = params["trigger_ratio"] || 0.7
    policy = params["policy"] || %{}
    metadata = params["metadata"] || %{}
    status = if params["status"] == "tombstoned", do: :tombstoned, else: :active

    config = %Config{token_budget: budget, trigger_ratio: trigger_ratio, policy: policy}

    with {:ok, context} <- Runtime.upsert_context(id, config, status: status, metadata: metadata) do
      json(conn, context)
    end
  end

  def upsert(_conn, _params), do: {:error, :invalid_context_config}

  def show(conn, %{"id" => id}) do
    with {:ok, context} <- Runtime.get_context(id) do
      json(conn, context)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %Context{} = context} <- Runtime.get_context(id),
         {:ok, _} <-
           Runtime.upsert_context(id, context.config,
             status: :tombstoned,
             metadata: context.metadata
           ) do
      send_resp(conn, :no_content, "")
    end
  end

  def update_metadata(conn, %{"id" => id, "metadata" => metadata}) when is_map(metadata) do
    with {:ok, %Context{} = context} <- Runtime.get_context(id),
         {:ok, updated} <-
           Runtime.upsert_context(id, context.config, status: context.status, metadata: metadata) do
      json(conn, updated)
    end
  end

  def update_metadata(_conn, _params), do: {:error, :invalid_metadata}

  # Messaging

  def append(conn, %{
        "id" => id,
        "message" => %{"role" => role, "parts" => parts, "token_count" => count} = msg
      })
      when is_binary(role) and is_list(parts) and is_integer(count) and count >= 0 do
    metadata = Map.get(msg, "metadata", %{})
    if_version = Map.get(conn.params, "if_version")

    with {:ok, [reply]} <-
           Runtime.append_messages(id, [{role, parts, metadata, count}], if_version: if_version) do
      json(conn, %{seq: reply.seq, version: reply.version, token_estimate: reply.token_count})
      |> put_status(:created)
    end
  end

  def append(_conn, _params), do: {:error, :invalid_message}

  @doc """
  Retrieves messages from the tail (newest) with offset-based pagination.

  Query parameters:
    - `offset` (integer, default: 0): Number of messages to skip from tail
    - `limit` (integer, default: 100): Maximum messages to return

  Examples:
    GET /v1/contexts/:id/tail              -> Last 100 messages
    GET /v1/contexts/:id/tail?limit=50     -> Last 50 messages
    GET /v1/contexts/:id/tail?offset=50&limit=50  -> Messages 51-100 from tail

  Returns messages in chronological order (oldest to newest).
  Designed for backward iteration - future-proof for tiered storage.
  """
  def tail(conn, %{"id" => id} = params) do
    offset = parse_non_neg_integer(params, "offset", 0)
    limit = parse_pos_integer(params, "limit", 100)

    with {:ok, messages} <- Runtime.get_messages_tail(id, offset, limit) do
      json(conn, %{messages: messages})
    end
  end

  def window(conn, %{"id" => id}) do
    with {:ok, window} <- Runtime.get_context_window(id) do
      json(conn, window)
    end
  end

  def compact(conn, %{"id" => id, "replacement" => replacement})
      when is_list(replacement) do
    if_version = Map.get(conn.params, "if_version")

    with {:ok, version} <- Runtime.compact(id, replacement, if_version: if_version) do
      json(conn, %{version: version})
    end
  end

  def compact(_conn, _params), do: {:error, :invalid_replacement}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp parse_non_neg_integer(params, key, default) do
    case Map.get(params, key) do
      nil -> default
      val when is_integer(val) and val >= 0 -> val
      val when is_binary(val) -> max(String.to_integer(val), 0)
      _ -> default
    end
  end

  defp parse_pos_integer(params, key, default) do
    case Map.get(params, key) do
      nil -> default
      val when is_integer(val) and val > 0 -> val
      val when is_binary(val) -> max(String.to_integer(val), 1)
      _ -> default
    end
  end
end
