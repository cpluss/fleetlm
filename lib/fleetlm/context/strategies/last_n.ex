defmodule Fleetlm.Context.Strategies.LastN do
  @moduledoc """
  Keeps only the last *N* messages in the transcript. No external compaction.
  """

  @behaviour Fleetlm.Context.Strategy

  alias Fleetlm.Context.{Snapshot, Strategy}

  @default_limit 50

  @impl true
  def validate_config(config) when is_map(config) do
    limit = Map.get(config, "limit", Map.get(config, :limit, @default_limit))

    if is_integer(limit) and limit > 0 do
      with :ok <- validate_token_budget(config) do
        :ok
      end
    else
      {:error, :invalid_limit}
    end
  end

  def validate_config(_), do: {:error, :invalid_config}

  @impl true
  def append_message(nil, message, config, _opts) do
    limit = Map.get(config, "limit", Map.get(config, :limit, @default_limit))
    max_tokens = token_budget(config)
    normalized = ensure_seq(message)

    queue =
      :queue.in(normalized, :queue.new())
      |> trim_queue(limit)

    {queue, tokens} = enforce_token_budget(queue, max_tokens)
    pending = :queue.to_list(queue)

    {:ok,
     %Snapshot{
       strategy_id: "last_n",
       summary_messages: [],
       pending_messages: pending,
       token_count: tokens,
       last_compacted_seq: 0,
       last_included_seq: message_seq(normalized),
       metadata: %{
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

    queue =
      snapshot.metadata
      |> Map.get(:pending_queue, :queue.from_list(snapshot.pending_messages || []))

    queue = :queue.in(normalized, queue)
    queue = trim_queue(queue, limit)
    {queue, tokens} = enforce_token_budget(queue, max_tokens)
    pending = :queue.to_list(queue)
    metadata = snapshot.metadata || %{}

    {:ok,
     %Snapshot{
       snapshot
       | pending_messages: pending,
         summary_messages: [],
         token_count: tokens,
         last_included_seq: message_seq(normalized),
         metadata:
           metadata
           |> Map.put(:compaction_inflight, false)
           |> Map.put(:pending_queue, queue)
           |> Map.put(:token_budget, max_tokens)
     }}
  end

  @impl true
  def apply_compaction(snapshot, _result, _config, _opts) do
    {:ok, snapshot}
  end

  defp validate_token_budget(config) do
    budget = Map.get(config, "max_tokens", Map.get(config, :max_tokens))

    cond do
      is_nil(budget) ->
        :ok

      is_integer(budget) and budget > 0 ->
        if budget > Strategy.max_token_budget() do
          {:error, :token_budget_exceeds_system_limit}
        else
          :ok
        end

      true ->
        {:error, :invalid_token_budget}
    end
  end

  defp token_budget(config) do
    requested = Map.get(config, "max_tokens", Map.get(config, :max_tokens))
    Strategy.clamp_token_budget(requested)
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

  defp enforce_token_budget(_queue, max_tokens) when max_tokens <= 0 do
    queue = :queue.new()
    {queue, 0}
  end

  defp enforce_token_budget(queue, max_tokens) do
    tokens = queue_token_count(queue)
    do_enforce_token_budget(queue, tokens, max_tokens)
  end

  defp do_enforce_token_budget(queue, tokens, max_tokens)
       when tokens <= max_tokens do
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

  defp extract_text(%{"parts" => parts}) when is_list(parts),
    do: Enum.map_join(parts, " ", &extract_part/1)

  defp extract_text(%{parts: parts}) when is_list(parts),
    do: Enum.map_join(parts, " ", &extract_part/1)

  defp extract_text(_), do: ""

  defp extract_part(%{"text" => text}) when is_binary(text), do: text
  defp extract_part(%{text: text}) when is_binary(text), do: text
  defp extract_part(_), do: ""

  defp ensure_seq(%{"seq" => _} = message), do: message
  defp ensure_seq(%{seq: _} = message), do: Map.put_new(message, "seq", message.seq)
  defp ensure_seq(message), do: Map.put_new(message, "seq", Map.get(message, :seq, 0))

  defp message_seq(%{"seq" => seq}) when is_integer(seq), do: seq
  defp message_seq(%{seq: seq}) when is_integer(seq), do: seq
  defp message_seq(_), do: 0
end
