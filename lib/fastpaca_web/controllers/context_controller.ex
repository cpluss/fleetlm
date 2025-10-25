defmodule FastpacaWeb.ContextController do
  use FastpacaWeb, :controller

  alias Fastpaca.Context
  alias Fastpaca.Context.Config
  alias Fastpaca.Runtime

  action_fallback FastpacaWeb.FallbackController

  # ---------------------------------------------------------------------------
  # Context lifecycle
  # ---------------------------------------------------------------------------

  def upsert(conn, %{"id" => id} = params) do
    with {:ok, config} <- build_config(params),
         {:ok, context} <-
           Runtime.upsert_context(id, config,
             status: status_from_params(params),
             metadata: params["metadata"] || %{}
           ) do
      status = if conn.method == "PUT", do: :ok, else: :ok
      conn |> put_status(status) |> json(context)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %Context{} = context} <- Runtime.get_context(id) do
      json(conn, context_to_map(context))
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %Context{} = context} <- Runtime.get_context(id),
         {:ok, _} <-
           Runtime.upsert_context(id, context.config,
             status: :tombstoned,
             metadata: context.metadata || %{}
           ) do
      send_resp(conn, :no_content, "")
    end
  end

  def update_metadata(conn, %{"id" => id, "metadata" => metadata}) do
    with {:ok, %Context{} = context} <- Runtime.get_context(id),
         {:ok, updated} <-
           Runtime.upsert_context(id, context.config, status: context.status, metadata: metadata) do
      json(conn, updated)
    end
  end

  # ---------------------------------------------------------------------------
  # Messaging
  # ---------------------------------------------------------------------------

  def append(conn, %{"id" => id, "message" => message_params} = params) do
    with {:ok, inputs} <- build_message_inputs(message_params),
         {:ok, reply} <-
           Runtime.append_messages(id, inputs, if_version: parse_int(params["if_version"])) do
      last = List.last(reply)

      conn
      |> put_status(:created)
      |> json(%{
        seq: last[:seq] || last["seq"],
        version: last[:version] || last["version"],
        token_estimate: last[:token_count] || last["token_count"] || 0
      })
    end
  end

  def list_messages(conn, %{"id" => id} = params) do
    after_seq = parse_int(params["from_seq"]) || 0
    limit = parse_int(params["limit"]) || 100

    with {:ok, messages} <- Runtime.get_messages(id, after_seq, limit) do
      json(conn, %{messages: Enum.map(messages, &message_to_map/1)})
    end
  end

  def window(conn, %{"id" => id}) do
    with {:ok, window} <- Runtime.get_context_window(id) do
      json(conn, %{
        version: window.version,
        messages: Enum.map(window.messages, &llm_message_to_map/1),
        used_tokens: window.token_count,
        needs_compaction: window.needs_compaction,
        metadata: window.metadata,
        segments: build_segments(window.messages)
      })
    end
  end

  def compact(conn, %{"id" => id} = params) do
    with {:ok, inputs} <- build_replacement(params["replacement"]),
         {:ok, version} <-
           Runtime.compact(id, inputs, if_version: parse_int(params["if_version"])) do
      json(conn, %{version: version})
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_config(params) do
    token_budget = parse_int(params["token_budget"]) || params["token_budget"]
    trigger_ratio = parse_float(params["trigger_ratio"]) || 0.7
    policy = params["policy"] || %{}

    {:ok, %Config{token_budget: token_budget, trigger_ratio: trigger_ratio, policy: policy}}
  end

  defp status_from_params(%{"status" => "tombstoned"}), do: :tombstoned
  defp status_from_params(_), do: :active

  defp build_message_inputs(message) when is_map(message) do
    tuple =
      {message_role(message), normalize_parts(message_parts(message)), message_metadata(message),
       message_token_count(message)}

    {:ok, [tuple]}
  end

  defp build_message_inputs(_), do: {:error, :invalid_message}

  defp build_replacement(messages) when is_list(messages) do
    replacement =
      Enum.map(messages, fn message ->
        %{
          role: message_role(message),
          parts: normalize_parts(message_parts(message)),
          metadata: message_metadata(message),
          token_count: message_token_count(message)
        }
      end)

    {:ok, replacement}
  end

  defp build_replacement(_), do: {:error, :invalid_replacement}

  defp message_role(message), do: message["role"] || message[:role]
  defp message_parts(message), do: message["parts"] || message[:parts] || []

  defp normalize_parts(parts) when is_list(parts) do
    Enum.map(parts, fn
      %{"type" => type} when is_binary(type) -> %{type: type}
      %{type: type} when is_binary(type) -> %{type: type}
    end)
  end

  defp message_metadata(message), do: message["metadata"] || message[:metadata] || %{}
  defp message_token_count(message), do: message["token_count"] || message[:token_count]

  defp message_to_map(message) when is_map(message), do: message

  defp llm_message_to_map(%{
         role: role,
         parts: parts,
         metadata: metadata,
         token_count: tokens,
         seq: seq,
         inserted_at: %NaiveDateTime{} = dt
       }) do
    %{
      role: role,
      parts: parts,
      metadata: metadata,
      token_count: tokens,
      seq: seq,
      inserted_at: NaiveDateTime.to_iso8601(dt)
    }
  end

  defp llm_message_to_map(%{
         role: role,
         parts: parts,
         metadata: metadata,
         token_count: tokens,
         seq: seq,
         inserted_at: inserted_at
       }) do
    %{
      role: role,
      parts: parts,
      metadata: metadata,
      token_count: tokens,
      seq: seq,
      inserted_at: inserted_at
    }
  end

  defp build_segments(messages) do
    seqs =
      messages
      |> Enum.map(fn msg -> msg[:seq] || msg["seq"] end)
      |> Enum.filter(&is_integer/1)

    case seqs do
      [] -> []
      _ -> [%{type: "live", from_seq: Enum.min(seqs), to_seq: Enum.max(seqs)}]
    end
  end

  defp context_to_map(%Context{} = context) do
    %{
      id: context.id,
      status: context.status,
      token_budget: context.config.token_budget,
      trigger_ratio: context.config.trigger_ratio,
      policy: context.config.policy,
      version: context.version,
      last_seq: context.last_seq,
      metadata: context.metadata || %{},
      inserted_at: NaiveDateTime.to_iso8601(context.inserted_at),
      updated_at: NaiveDateTime.to_iso8601(context.updated_at)
    }
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_float(nil), do: nil

  defp parse_float(value) when is_float(value), do: value

  defp parse_float(value) when is_integer(value), do: value / 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> nil
    end
  end

  defp parse_float(_), do: nil
end
