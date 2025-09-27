defmodule Fleetlm.Agents.WebhookWorker do
  @moduledoc """
  Individual webhook delivery worker with HTTP connection pooling.

  Each worker maintains its own HTTP client with connection pooling
  and handles the actual webhook delivery to agent endpoints.
  """

  use GenServer
  require Logger

  alias Fleetlm.Agents
  alias Fleetlm.Agents.AgentEndpoint

  @http_timeout :timer.seconds(10)
  @max_retries 2

  ## Worker Implementation (called by :poolboy)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  ## GenServer Implementation

  @impl true
  def init(_args) do
    # Initialize HTTP client with connection pooling
    req_options = [
      pool_timeout: 5_000,
      receive_timeout: @http_timeout,
      retry: :transient,
      max_retries: @max_retries,
      # Connection pooling for efficiency
      connect_options: [
        protocols: [:http1, :http2],
        transport_opts: [
          # Reuse connections
          reuseaddr: true
        ]
      ]
    ]

    case Req.new(req_options) do
      %Req.Request{} = req ->
        state = %{
          http_client: req,
          stats: %{
            deliveries: 0,
            successes: 0,
            failures: 0
          }
        }

        {:ok, state}

      error ->
        Logger.error("WebhookWorker: Failed to initialize HTTP client: #{inspect(error)}")
        {:stop, error}
    end
  end

  @impl true
  def handle_cast({:deliver, agent_id, session, message}, state) do
    # Check if we're in test mode first
    case dispatcher_mode() do
      {:test, pid} ->
        # In test mode, send message directly to test process
        payload = build_test_payload(session, message)
        send(pid, {:agent_dispatch, payload})

        # Note: Delivery logs are not created in test mode to avoid sandbox issues
        {:noreply, state}

      :live ->
        # Normal webhook delivery
        case Agents.get_endpoint(agent_id) do
          %AgentEndpoint{status: "enabled"} = endpoint ->
            deliver_webhook(endpoint, session, message, state)

          _ ->
            # Agent not enabled or doesn't exist
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:deliver_batch, endpoint, deliveries}, state) do
    if endpoint && endpoint.status == "enabled" do
      # Process batch deliveries for the same endpoint
      Enum.each(deliveries, fn {_agent_id, session, message} ->
        deliver_webhook(endpoint, session, message, state)
      end)
    end

    {:noreply, state}
  end

  ## Private Functions

  defp deliver_webhook(endpoint, session, message, state) do
    started_at = System.monotonic_time(:millisecond)
    meta = telemetry_meta(session, message)

    :telemetry.execute([:fleetlm, :agent, :delivery, :start], %{}, meta)

    # Prepare webhook payload
    http_payload = %{
      session: %{
        id: session.id,
        agent_id: session.agent_id,
        last_message_at: session.last_message_at
      },
      message: message
    }

    # Execute delivery
    delivery_result =
      case webhook_delivery_mode() do
        {:mock, handler} -> deliver_via_mock(handler, endpoint, session, message, http_payload)
        :live -> deliver_http(state.http_client, endpoint, http_payload)
      end

    result =
      case delivery_result do
        {:ok, response} ->
          success_telemetry(started_at, response, meta)
          log_delivery_success(endpoint, session, message, response)
          :success

        {:error, reason} ->
          failure_telemetry(started_at, reason, meta)
          log_delivery_failure(endpoint, session, message, reason)
          :failure
      end

    # Update stats
    updated_stats = %{
      state.stats
      | deliveries: state.stats.deliveries + 1,
        successes:
          if(result == :success, do: state.stats.successes + 1, else: state.stats.successes),
        failures: if(result == :failure, do: state.stats.failures + 1, else: state.stats.failures)
    }

    # Notify manager of result
    send(Fleetlm.Agents.WebhookManager, {:delivery_result, result})

    {:noreply, %{state | stats: updated_stats}}
  end

  defp deliver_http(http_client, endpoint, payload) do
    try do
      case Req.post(http_client,
             url: endpoint.origin_url,
             json: payload,
             headers: endpoint.headers || %{}
           ) do
        {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
          {:ok, response}

        {:ok, %Req.Response{status: status} = response} ->
          {:error, {:http_error, status, response}}

        {:error, reason} ->
          {:error, {:request_error, reason}}
      end
    rescue
      error ->
        {:error, {:exception, error}}
    end
  end

  defp deliver_via_mock(handler, endpoint, session, message, http_payload) do
    payload = %{
      endpoint: endpoint,
      session: session,
      message: message,
      body: http_payload
    }

    try do
      case handler do
        fun when is_function(fun, 1) -> fun.(payload)
        module when is_atom(module) -> apply(module, :deliver, [payload])
      end
    rescue
      error -> {:error, {:mock_exception, error}}
    catch
      kind, reason -> {:error, {:mock_crash, kind, reason}}
    end
  end

  defp webhook_delivery_mode do
    case Application.get_env(:fleetlm, :webhook_delivery) do
      %{mode: :mock, handler: handler} when is_function(handler, 1) -> {:mock, handler}
      %{mode: :mock, module: module} when is_atom(module) -> {:mock, module}
      _ -> :live
    end
  end

  defp success_telemetry(started_at, response, meta) do
    duration = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:fleetlm, :agent, :delivery, :success],
      %{duration: duration, status_code: response.status},
      meta
    )
  end

  defp failure_telemetry(started_at, reason, meta) do
    duration = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:fleetlm, :agent, :delivery, :failure],
      %{duration: duration},
      Map.put(meta, :reason, inspect(reason))
    )
  end

  defp log_delivery_success(endpoint, session, message, response) do
    Agents.log_delivery(%{
      agent_id: session.agent_id,
      session_id: session.id,
      message_id: message.id,
      endpoint_url: endpoint.origin_url,
      status_code: response.status,
      response_body: truncate_response(response.body),
      delivered_at: DateTime.utc_now()
    })
  end

  defp log_delivery_failure(endpoint, session, message, reason) do
    Agents.log_delivery(%{
      agent_id: session.agent_id,
      session_id: session.id,
      message_id: message.id,
      endpoint_url: endpoint.origin_url,
      status_code: nil,
      response_body: inspect(reason),
      error: inspect(reason),
      delivered_at: DateTime.utc_now()
    })
  end

  defp telemetry_meta(session, message) do
    %{
      agent_id: session.agent_id,
      session_id: session.id,
      message_id: message.id,
      message_kind: message.kind
    }
  end

  defp truncate_response(body) when is_binary(body) do
    if byte_size(body) > 1000 do
      binary_part(body, 0, 1000) <> "..."
    else
      body
    end
  end

  defp truncate_response(body), do: inspect(body)

  defp dispatcher_mode do
    case Application.get_env(:fleetlm, :agent_dispatcher, []) do
      %{mode: :test, pid: pid} when is_pid(pid) -> {:test, pid}
      %{mode: :test} -> {:test, self()}
      _ -> :live
    end
  end

  defp build_test_payload(session, message) do
    %{
      "session" => %{
        "id" => session.id,
        "agent_id" => session.agent_id,
        "initiator_id" => session.initiator_id,
        "peer_id" => session.peer_id,
        "kind" => session.kind,
        "status" => session.status
      },
      "message" => %{
        "id" => message.id || message["id"],
        "session_id" => message.session_id || message["session_id"],
        "sender_id" => message.sender_id || message["sender_id"],
        "kind" => message.kind || message["kind"],
        "content" => message.content || message["content"]
      }
    }
  end
end
