defmodule Fleetlm.Webhook.Client do
  @moduledoc """
  Reusable HTTP client for agent and compaction webhooks.

  Uses Finch with HTTP/2 pooling, handles JSONL streaming.
  """

  require Logger

  alias Fleetlm.Webhook.Assembler

  @type agent :: map()
  @type payload :: map()
  @type stream_handler :: (map(), map() -> {:ok, map()} | {:error, term(), map()})

  @doc """
  Call agent webhook with messages, stream JSONL responses back.

  Returns a stream of actions that can be processed by the caller.
  Handler receives {:chunk, data} and {:finalize, message, meta} actions.
  """
  @spec call_agent_webhook(agent(), payload(), stream_handler()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def call_agent_webhook(agent, payload, handler) do
    url = build_agent_url(agent)
    payload_json = Jason.encode!(payload)

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
      | custom_headers(agent)
    ]

    acc = %{
      buffer: "",
      count: 0,
      status: nil,
      assembler: Assembler.new(role: "assistant"),
      handler: handler,
      ttft_emitted: false
    }

    request =
      Finch.build(:post, url, headers, payload_json)
      |> Finch.stream(Fleetlm.Webhook.HTTP, acc, &handle_stream_chunk/2,
        receive_timeout: agent.timeout_ms || 30_000,
        pool_timeout: agent.timeout_ms || 30_000
      )

    case request do
      {:ok, %{assembler: _} = acc} ->
        case flush_buffer(acc) do
          {:ok, final_acc} -> handle_stream_result(final_acc)
          {:error, reason} -> {:error, reason}
        end

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, {:error, reason, _acc}} ->
        # Handler returned error with accumulator
        {:error, reason}

      {:ok, other} ->
        {:error, {:invalid_accumulator, other}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Call compaction webhook, returns summary.

  Simpler than agent webhook - just POST and get JSON response.
  No streaming needed.
  """
  @spec call_compaction_webhook(String.t(), payload()) ::
          {:ok, map()} | {:error, term()}
  def call_compaction_webhook(url, payload) do
    payload_json = Jason.encode!(payload)

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    request =
      Finch.build(:post, url, headers, payload_json)
      |> Finch.request(Fleetlm.Webhook.HTTP, receive_timeout: 60_000)

    case request do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, summary} -> {:ok, summary}
          {:error, reason} -> {:error, {:json_decode_failed, reason}}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  ## Private

  defp handle_stream_chunk({:status, status}, acc), do: %{acc | status: status}
  defp handle_stream_chunk({:headers, _headers}, acc), do: acc

  defp handle_stream_chunk({:data, data}, acc) when is_map(acc) and is_map_key(acc, :assembler) do
    new_buffer = acc.buffer <> data
    lines = String.split(new_buffer, "\n")
    {complete_lines, [remaining]} = Enum.split(lines, -1)

    result =
      Enum.reduce_while(complete_lines, {:ok, %{acc | buffer: ""}}, fn line, {:ok, acc} ->
        case process_line(line, acc) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, reason, acc} -> {:halt, {:error, reason, acc}}
        end
      end)

    case result do
      {:ok, acc} -> %{acc | buffer: remaining}
      {:error, reason} -> {:error, reason}
    end
  end

  defp flush_buffer(%{buffer: buffer, assembler: _} = acc) when is_binary(buffer) do
    trimmed = String.trim(buffer)

    cond do
      buffer == "" ->
        {:ok, acc}

      trimmed == "" ->
        {:ok, %{acc | buffer: ""}}

      true ->
        case process_line(trimmed, %{acc | buffer: ""}) do
          {:ok, acc} -> {:ok, acc}
          {:error, reason, _acc} -> {:error, reason}
        end
    end
  end

  defp process_line(line, %{assembler: _} = acc) do
    trimmed = String.trim(line)

    if trimmed == "" do
      {:ok, acc}
    else
      case Jason.decode(trimmed) do
        {:ok, chunk} ->
          ingest_chunk(chunk, acc)

        {:error, reason} ->
          {:error, {:json_decode_failed, reason}, acc}
      end
    end
  end

  defp ingest_chunk(chunk, %{assembler: assembler} = acc) when is_map(chunk) do
    case Assembler.ingest(assembler, chunk) do
      {:ok, new_state, actions} ->
        acc = %{acc | assembler: new_state}

        case apply_stream_actions(acc, actions) do
          {:ok, acc} -> {:ok, acc}
          {:error, reason, acc} -> {:error, reason, acc}
        end

      {:error, reason, new_state, actions} ->
        acc = %{acc | assembler: new_state}

        case apply_stream_actions(acc, actions) do
          {:ok, acc} -> {:error, reason, acc}
          {:error, reason2, acc} -> {:error, reason2, acc}
        end
    end
  end

  defp apply_stream_actions(acc, actions) do
    Enum.reduce_while(actions, {:ok, acc}, fn action, {:ok, acc} ->
      case handle_stream_action(acc, action) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason, acc} -> {:halt, {:error, reason, acc}}
      end
    end)
  end

  defp handle_stream_action(acc, {:chunk, _chunk} = action) do
    case acc.handler.(action, acc) do
      {:ok, acc} -> {:ok, acc}
      {:error, reason, acc} -> {:error, reason, acc}
    end
  end

  defp handle_stream_action(acc, {:finalize, _message, _meta} = action) do
    case acc.handler.(action, acc) do
      {:ok, acc} ->
        {:ok, %{acc | count: acc.count + 1, assembler: Assembler.new(role: "assistant")}}

      {:error, reason, acc} ->
        {:error, reason, acc}
    end
  end

  defp handle_stream_action(acc, {:abort, _chunk}) do
    {:ok, acc}
  end

  defp handle_stream_result(%{status: status, count: count})
       when is_integer(status) and status in 200..299 do
    {:ok, count}
  end

  defp handle_stream_result(%{status: status}) when is_integer(status) do
    {:error, {:http_error, status}}
  end

  defp handle_stream_result(_acc) do
    {:error, {:request_failed, :missing_status}}
  end

  defp build_agent_url(agent) do
    uri = URI.parse(agent.origin_url)
    base_path = uri.path || "/"
    webhook_path = agent.webhook_path || "/webhook"
    path = Path.join(base_path, webhook_path)

    %{uri | path: path}
    |> URI.to_string()
  end

  defp custom_headers(agent) do
    agent.headers
    |> Map.new(fn {k, v} -> {String.downcase(to_string(k)), v} end)
    |> Enum.to_list()
  end
end
