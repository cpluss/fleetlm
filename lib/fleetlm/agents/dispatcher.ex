defmodule Fleetlm.Agents.Dispatcher do
  @moduledoc """
  Asynchronous webhook dispatcher for agent sessions.

  When a new message is appended to an agent-backed session, the dispatcher
  forwards the payload to the registered webhook endpoint, records delivery
  logs, and emits telemetry. Work is delegated to a `Task.Supervisor` so the
  main request path remains non-blocking.
  """

  require Logger

  alias Fleetlm.Agents
  alias Fleetlm.Agents.AgentEndpoint

  @dispatcher_supervisor Fleetlm.Agents.DispatcherSupervisor

  @spec maybe_dispatch(map(), map()) :: :ok
  def maybe_dispatch(session, message) do
    cond do
      is_nil(session.agent_id) -> :ok
      message.sender_id == session.agent_id -> :ok
      true -> dispatch_async(session, message)
    end
  end

  defp dispatch_async(session, message) do
    case Agents.get_endpoint(session.agent_id) do
      %AgentEndpoint{status: "enabled"} = endpoint ->
        Task.Supervisor.start_child(@dispatcher_supervisor, fn ->
          deliver(endpoint, session, message)
        end)

      %AgentEndpoint{} ->
        :ok

      nil ->
        :ok
    end
  end

  defp deliver(endpoint, session, message) do
    meta = telemetry_meta(session, message)
    :telemetry.execute([:fleetlm, :agent, :delivery, :start], %{}, meta)

    started_at = System.monotonic_time(:millisecond)

    result =
      case dispatcher_mode() do
        {:test, pid} ->
          payload = build_payload(session, message)
          send(pid, {:agent_dispatch, payload})
          {:ok, 200, "test"}

        :live ->
          perform_http_call(endpoint, session, message)
      end

    latency = System.monotonic_time(:millisecond) - started_at

    case result do
      {:ok, status, excerpt} ->
        log_delivery(session, message, %{
          status: "sent",
          http_status: status,
          latency_ms: latency,
          response_excerpt: excerpt
        })

        :telemetry.execute([:fleetlm, :agent, :delivery, :stop], %{duration: latency}, meta)

      {:error, reason} ->
        log_delivery(session, message, %{
          status: "failed",
          error_reason: reason,
          latency_ms: latency
        })

        :telemetry.execute(
          [:fleetlm, :agent, :delivery, :stop],
          %{duration: latency},
          Map.put(meta, :error, reason)
        )
    end
  rescue
    exception ->
      reason = Exception.message(exception)
      log_delivery(session, message, %{status: "failed", error_reason: reason})

      Logger.error("agent dispatch failed",
        session_id: session.id,
        agent_id: session.agent_id,
        message_id: message.id,
        error: reason
      )

      :telemetry.execute(
        [:fleetlm, :agent, :delivery, :exception],
        %{},
        Map.put(telemetry_meta(session, message), :error, reason)
      )
  end

  defp dispatcher_mode do
    case Application.get_env(:fleetlm, :agent_dispatcher, []) do
      %{mode: :test, pid: pid} when is_pid(pid) -> {:test, pid}
      %{mode: :test} -> {:test, self()}
      _ -> :live
    end
  end

  defp perform_http_call(%AgentEndpoint{} = endpoint, session, message) do
    payload = build_payload(session, message)

    headers =
      endpoint.headers
      |> to_headers()
      |> maybe_add_auth(endpoint)

    request =
      Req.new(
        url: endpoint.origin_url,
        method: :post,
        json: payload,
        headers: headers,
        receive_timeout: endpoint.timeout_ms
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, status, excerpt(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "status=#{status} body=#{excerpt(body)}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp log_delivery(session, message, attrs) do
    log_attrs =
      attrs
      |> Map.put(:session_id, session.id)
      |> Map.put(:message_id, message.id)
      |> Map.put(:agent_id, session.agent_id)

    _ = Agents.log_delivery(log_attrs)
    :ok
  end

  defp telemetry_meta(session, message) do
    %{
      session_id: session.id,
      agent_id: session.agent_id,
      message_id: message.id
    }
  end

  defp build_payload(session, message) do
    session_map =
      %{
        "id" => session.id,
        "kind" => session.kind,
        "initiator_id" => session.initiator_id,
        "peer_id" => session.peer_id,
        "metadata" => session.metadata,
        "last_message_id" => session.last_message_id,
        "last_message_at" => encode_datetime(session.last_message_at)
      }
      |> stringify_map()

    message_map =
      %{
        "id" => Map.get(message, :id),
        "session_id" => Map.get(message, :session_id),
        "kind" => Map.get(message, :kind),
        "content" => Map.get(message, :content),
        "metadata" => Map.get(message, :metadata),
        "sender_id" => Map.get(message, :sender_id),
        "inserted_at" => encode_datetime(Map.get(message, :inserted_at))
      }
      |> stringify_map()
      |> Map.update("content", %{}, &stringify_map/1)
      |> Map.update("metadata", %{}, &stringify_map/1)

    %{"session" => session_map, "message" => message_map}
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)

  defp to_headers(map) when is_map(map) do
    Enum.map(map, fn {key, value} ->
      {to_string(key), to_string(value)}
    end)
  end

  defp to_headers(_), do: []

  defp stringify_map(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.into(%{})
  end

  defp stringify_map(other), do: other

  defp maybe_add_auth(headers, %AgentEndpoint{auth_strategy: "bearer", auth_value: token})
       when is_binary(token) do
    [{"authorization", "Bearer #{token}"} | headers]
  end

  defp maybe_add_auth(headers, _endpoint), do: headers

  defp excerpt(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp excerpt(body), do: inspect(body)
end
