defmodule FastpacaWeb.ContextController do
  use FastpacaWeb, :controller

  alias Fastpaca.{Runtime, Repo}
  alias Fastpaca.Storage.Model.Context

  action_fallback FastpacaWeb.FallbackController

  @doc """
  PUT /v1/contexts/:id

  Create or update a context (idempotent).
  """
  def upsert(conn, %{"id" => id} = params) do
    attrs = %{
      id: id,
      token_budget: params["token_budget"],
      trigger_ratio: params["trigger_ratio"],
      policy: params["policy"],
      metadata: params["metadata"] || %{}
    }

    case Repo.get(Context, id) do
      nil ->
        # Create new context
        case %Context{}
             |> Context.changeset(attrs)
             |> Repo.insert() do
          {:ok, context} ->
            conn
            |> put_status(:created)
            |> json(serialize_context(context))

          {:error, changeset} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "validation_failed", details: changeset_errors(changeset)})
        end

      existing ->
        # Update existing context
        case existing
             |> Context.changeset(attrs)
             |> Repo.update() do
          {:ok, context} ->
            json(conn, serialize_context(context))

          {:error, changeset} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "validation_failed", details: changeset_errors(changeset)})
        end
    end
  end

  @doc """
  GET /v1/contexts/:id

  Get context configuration and metadata.
  """
  def show(conn, %{"id" => id}) do
    case Repo.get(Context, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "context_not_found"})

      context ->
        json(conn, serialize_context(context))
    end
  end

  @doc """
  DELETE /v1/contexts/:id

  Tombstone a context (no new messages accepted).
  """
  def delete(conn, %{"id" => id}) do
    case Repo.get(Context, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "context_not_found"})

      context ->
        case context
             |> Context.changeset(%{status: "tombstoned"})
             |> Repo.update() do
          {:ok, _context} ->
            send_resp(conn, :no_content, "")

          {:error, _changeset} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "failed_to_tombstone"})
        end
    end
  end

  @doc """
  PATCH /v1/contexts/:id/metadata

  Update context metadata.
  """
  def update_metadata(conn, %{"id" => id, "metadata" => metadata}) do
    case Repo.get(Context, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "context_not_found"})

      context ->
        case context
             |> Context.changeset(%{metadata: metadata})
             |> Repo.update() do
          {:ok, updated} ->
            json(conn, serialize_context(updated))

          {:error, changeset} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "validation_failed", details: changeset_errors(changeset)})
        end
    end
  end

  @doc """
  POST /v1/contexts/:id/messages

  Append a message to the context.
  """
  def append(conn, %{"id" => context_id, "message" => message} = params) do
    idempotency_key = params["idempotency_key"]
    if_version = params["if_version"]

    # TODO: Check idempotency_key (store in cache)
    # TODO: Check if_version (optimistic concurrency)

    case Runtime.append_message(context_id, message) do
      {:ok, seq, version, token_estimate} ->
        conn
        |> put_status(:created)
        |> json(%{
          seq: seq,
          version: version,
          token_estimate: token_estimate
        })

      {:timeout, _leader} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "timeout", message: "Raft quorum timeout"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "append_failed", message: inspect(reason)})
    end
  end

  @doc """
  GET /v1/contexts/:id/messages

  List messages from context (replay/audit).
  """
  def list_messages(conn, %{"id" => context_id} = params) do
    after_seq = String.to_integer(params["from_seq"] || "0")
    limit = String.to_integer(params["limit"] || "100")

    case Runtime.get_messages(context_id, after_seq, limit) do
      {:ok, messages} ->
        json(conn, %{
          messages: Enum.map(messages, &serialize_message/1),
          next_cursor: after_seq + length(messages)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "fetch_failed", message: inspect(reason)})
    end
  end

  @doc """
  GET /v1/contexts/:id/context

  Get the LLM context window (pre-computed, pure read).
  """
  def window(conn, %{"id" => context_id} = params) do
    if_version = params["if_version"]

    case Runtime.get_context_window(context_id) do
      {:ok, %{messages: messages, version: version, used_tokens: used_tokens, needs_compaction: needs_compaction}} ->
        # Check version guard
        if if_version && String.to_integer(if_version) != version do
          conn
          |> put_status(:conflict)
          |> json(%{
            error: "conflict",
            message: "Version changed (expected #{if_version}, found #{version})"
          })
        else
          json(conn, %{
            version: version,
            messages: Enum.map(messages, &serialize_message/1),
            used_tokens: used_tokens,
            needs_compaction: needs_compaction,
            segments: build_segments(messages)
          })
        end

      {:error, :context_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "context_not_found"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "fetch_failed", message: inspect(reason)})
    end
  end

  @doc """
  POST /v1/contexts/:id/compact

  Manual compaction - replace message range with summary.
  """
  def compact(conn, %{"id" => context_id} = params) do
    from_seq = params["from_seq"]
    to_seq = params["to_seq"]
    replacement = params["replacement"]
    if_version = params["if_version"]

    # TODO: Check if_version (optimistic concurrency)

    case Runtime.compact(context_id, from_seq, to_seq, replacement) do
      {:ok, new_version} ->
        json(conn, %{version: new_version})

      {:error, :context_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "context_not_found"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "compaction_failed", message: inspect(reason)})
    end
  end

  # Private helpers

  defp serialize_context(context) do
    %{
      id: context.id,
      token_budget: context.token_budget,
      trigger_ratio: context.trigger_ratio,
      policy: context.policy,
      version: context.version,
      status: context.status,
      metadata: context.metadata,
      created_at: NaiveDateTime.to_iso8601(context.inserted_at),
      updated_at: NaiveDateTime.to_iso8601(context.updated_at)
    }
  end

  defp serialize_message(message) when is_map(message) do
    %{
      seq: message[:seq] || message["seq"],
      role: message[:role] || message["role"],
      parts: message[:parts] || message["parts"],
      metadata: message[:metadata] || message["metadata"] || %{},
      inserted_at: format_timestamp(message[:inserted_at] || message["inserted_at"])
    }
  end

  defp format_timestamp(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_timestamp(ts) when is_binary(ts), do: ts
  defp format_timestamp(_), do: nil

  defp build_segments(messages) when is_list(messages) and length(messages) > 0 do
    first_seq = hd(messages)[:seq] || hd(messages)["seq"] || 1
    last_seq = List.last(messages)[:seq] || List.last(messages)["seq"] || 1

    [
      %{
        type: "live",
        from_seq: first_seq,
        to_seq: last_seq
      }
    ]
  end

  defp build_segments(_), do: []

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
