defmodule Fleetlm.Context.Strategies.StripToolResults do
  @moduledoc """
  Drops tool/tool_result messages and then applies a last-N window.
  """

  @behaviour Fleetlm.Context.Strategy

  alias Fleetlm.Context.{Snapshot, Strategy}

  @default_limit 50
  @strip_kinds ["tool_result", "tool"]

  @impl true
  def validate_config(config) do
    Fleetlm.Context.Strategies.LastN.validate_config(config)
  end

  @impl true
  def append_message(nil, message, config, _opts) do
    limit = Map.get(config, "limit", Map.get(config, :limit, @default_limit))
    max_tokens = token_budget(config)
    normalized = ensure_seq(message)

    {queue, removed} = maybe_enqueue(:queue.new(), normalized, limit, 0)
    {queue, tokens} = enforce_token_budget(queue, max_tokens)
    pending = :queue.to_list(queue)

    {:ok,
     %Snapshot{
       strategy_id: "strip_tool_results",
       summary_messages: [],
       pending_messages: pending,
       token_count: tokens,
       last_compacted_seq: 0,
       last_included_seq: message_seq(normalized),
       metadata: %{
         removed_tool_messages: removed,
         compaction_inflight: false,
         pending_queue: queue,
         token_budget: max_tokens
       }
     }}
  end

  @impl true
  def append_message(%Snapshot{} = snapshot, message, config, _opts) do
    limit = Map.get(config, "limit", Map.get(config, :limit, @default_limit))
    max_tokens = token_budget(config)
    normalized = ensure_seq(message)

    metadata = snapshot.metadata || %{}
    removed = Map.get(metadata, :removed_tool_messages, 0)

    queue =
      metadata
      |> Map.get(:pending_queue, :queue.from_list(snapshot.pending_messages || []))

    {queue, removed} = maybe_enqueue(queue, normalized, limit, removed)

    {queue, tokens} = enforce_token_budget(queue, max_tokens)
    pending = :queue.to_list(queue)

    {:ok,
     %Snapshot{
       snapshot
       | pending_messages: pending,
         summary_messages: [],
         token_count: tokens,
         last_included_seq: message_seq(normalized),
         metadata:
           Map.merge(metadata, %{
             removed_tool_messages: removed,
             compaction_inflight: false,
             pending_queue: queue,
             token_budget: max_tokens
           })
     }}
  end

  @impl true
  def apply_compaction(snapshot, _result, _config, _opts), do: {:ok, snapshot}

  defp tool_message?(%{kind: kind}) when is_binary(kind), do: kind in @strip_kinds
  defp tool_message?(%{"kind" => kind}) when is_binary(kind), do: kind in @strip_kinds
  defp tool_message?(_), do: false

  defp estimate_tokens(messages) do
    messages
    |> Enum.map(&(Map.get(&1, :content) || Map.get(&1, "content") || %{}))
    |> Enum.map(&extract_text/1)
    |> Enum.map(&String.length/1)
    |> Enum.sum()
    |> div(4)
  end

  defp extract_text(%{"text" => text}) when is_binary(text), do: text
  defp extract_text(%{text: text}) when is_binary(text), do: text
  defp extract_text(_), do: ""

  defp maybe_enqueue(queue, message, limit, removed) do
    if tool_message?(message) do
      {queue, removed + 1}
    else
      queue = :queue.in(message, queue)
      queue = trim_queue(queue, limit)
      {queue, removed}
    end
  end

  defp trim_queue(_queue, limit) when limit <= 0, do: :queue.new()

  defp trim_queue(queue, limit) do
    if :queue.len(queue) > limit do
      case :queue.out(queue) do
        {{:value, _}, rest} -> trim_queue(rest, limit)
        {:empty, _} -> queue
      end
    else
      queue
    end
  end

  defp token_budget(config) do
    requested = Map.get(config, "max_tokens", Map.get(config, :max_tokens))
    Strategy.clamp_token_budget(requested)
  end

  defp enforce_token_budget(_queue, max_tokens) when max_tokens <= 0 do
    {:queue.new(), 0}
  end

  defp enforce_token_budget(queue, max_tokens) do
    tokens = queue_token_count(queue)
    do_enforce_token_budget(queue, tokens, max_tokens)
  end

  defp do_enforce_token_budget(queue, tokens, max_tokens) when tokens <= max_tokens do
    {queue, max(tokens, 0)}
  end

  defp do_enforce_token_budget(queue, tokens, max_tokens) do
    case :queue.out(queue) do
      {{:value, dropped}, rest} ->
        dropped_tokens = estimate_tokens([dropped])
        do_enforce_token_budget(rest, tokens - dropped_tokens, max_tokens)

      {:empty, _} ->
        {:queue.new(), 0}
    end
  end

  defp queue_token_count(queue) do
    queue
    |> :queue.to_list()
    |> estimate_tokens()
  end

  defp ensure_seq(%{"seq" => _} = message), do: message
  defp ensure_seq(%{seq: _} = message), do: Map.put_new(message, "seq", message.seq)
  defp ensure_seq(message), do: Map.put_new(message, "seq", Map.get(message, :seq, 0))

  defp message_seq(%{"seq" => seq}) when is_integer(seq), do: seq
  defp message_seq(%{seq: seq}) when is_integer(seq), do: seq
  defp message_seq(_), do: 0
end
