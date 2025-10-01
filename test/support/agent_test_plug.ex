defmodule Fleetlm.Agent.TestPlug do
  @moduledoc """
  Test plug for agent webhooks. Intercepts requests and sends them to the test process.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Read the request body
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    payload = Jason.decode!(body)

    # Find the test process by looking up via process registry or application env
    test_pid =
      case Application.get_env(:fleetlm, :agent_test_pid) do
        nil -> raise "No test PID configured"
        pid -> pid
      end

    # Notify test process and wait for response synchronously
    send(test_pid, {:agent_webhook_called, payload, self()})

    # Get response from test process - note we're the plug process now
    response_data =
      receive do
        {:agent_response, data} -> data
      after
        5000 -> %{"kind" => "text", "content" => %{"text" => "timeout"}}
      end

    # Return JSONL response as regular body (not chunked)
    # This works with Req's plug adapter which doesn't support real streaming
    jsonl_line = Jason.encode!(response_data) <> "\n"

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, jsonl_line)
  end
end
