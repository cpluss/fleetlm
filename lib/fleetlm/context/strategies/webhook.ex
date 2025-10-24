defmodule Fleetlm.Context.Strategies.Webhook do
  @moduledoc """
  Delegates transcript compaction to an external webhook when the current
  transcript exceeds a configured token budget.
  """

  @behaviour Fleetlm.Context.Strategy

  alias Fleetlm.Context.{Snapshot, Strategy}

  @default_token_budget 2_000

  @impl true
  def validate_config(config) when is_map(config) do
    with :ok <- validate_urls(config),
         :ok <- validate_token_budget(config) do
      :ok
    end
  end

  def validate_config(_), do: {:error, :invalid_config}

  defp validate_urls(config) do
    cond do
      is_nil(Map.get(config, "url")) and is_nil(Map.get(config, :url)) and
        is_nil(Map.get(config, "build_url")) and is_nil(Map.get(config, :build_url)) ->
        {:error, :missing_url}

      true ->
        :ok
    end
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
    requested = Map.get(config, "max_tokens", Map.get(config, :max_tokens, @default_token_budget))
    Strategy.clamp_token_budget(requested)
  end

  defp enforce_pending_budget(_queue, allowed_tokens) when allowed_tokens <= 0 do
    {:queue.new(), 0}
  end

  defp enforce_pending_budget(queue, allowed_tokens) do
    tokens = queue_token_count(queue)
    do_enforce_pending_budget(queue, tokens, allowed_tokens)
  end

  defp do_enforce_pending_budget(queue, tokens, allowed_tokens) when tokens <= allowed_tokens do
    {queue, max(tokens, 0)}
  end

  defp do_enforce_pending_budget(queue, tokens, allowed_tokens) do
    case :queue.out(queue) do
      {{:value, dropped}, rest} ->
        dropped_tokens = estimate_tokens([dropped])
        do_enforce_pending_budget(rest, tokens - dropped_tokens, allowed_tokens)

      {:empty, _} ->
        {:queue.new(), 0}
    end
  end

  defp queue_token_count(queue) do
    queue
    |> :queue.to_list()
    |> estimate_tokens()
  end

  @impl true
  def append_message(nil, message, config, _opts) do
    max_tokens = token_budget(config)
    normalized = ensure_seq(message)
    queue = :queue.in(normalized, :queue.new())
    {queue, pending_tokens} = enforce_pending_budget(queue, max_tokens)
    pending = :queue.to_list(queue)
    summary_tokens = 0
    token_count = summary_tokens + pending_tokens

    {:ok,
     %Snapshot{
       strategy_id: "webhook",
       summary_messages: [],
       pending_messages: pending,
       token_count: token_count,
       last_compacted_seq: 0,
       last_included_seq: message_seq(normalized),
       metadata: %{
         compaction_inflight: false,
         pending_queue: queue,
         summary_token_count: summary_tokens,
         token_budget: max_tokens
       }
     }}
  end

  @impl true
  def append_message(%Snapshot{} = snapshot, message, config, _opts) do
    max_tokens = token_budget(config)
    absolute_limit = Strategy.max_token_budget()
    compaction_url = Map.get(config, "compaction_url") || Map.get(config, :compaction_url)

    normalized = ensure_seq(message)
    metadata = snapshot.metadata || %{}
    summary = snapshot.summary_messages || []
    summary_tokens = Map.get(metadata, :summary_token_count, estimate_tokens(summary))

    if summary_tokens > absolute_limit do
      {:error, :summary_over_token_budget}
    else
      base_queue =
        Map.get(metadata, :pending_queue, :queue.from_list(snapshot.pending_messages || []))

      queue = :queue.in(normalized, base_queue)

      allowed_pending_tokens = max(absolute_limit - summary_tokens, 0)
      {queue, pending_tokens} = enforce_pending_budget(queue, allowed_pending_tokens)

      pending = :queue.to_list(queue)
      token_count = summary_tokens + pending_tokens

      compaction_inflight? = Map.get(metadata, :compaction_inflight, false)

      base_metadata =
        metadata
        |> Map.put(:pending_queue, queue)
        |> Map.put(:summary_token_count, summary_tokens)
        |> Map.put(:last_message_at, message_seq(normalized))
        |> Map.put(:token_budget, max_tokens)

      cond do
        token_count <= max_tokens or is_nil(compaction_url) ->
          {:ok,
           %Snapshot{
             snapshot
             | pending_messages: pending,
               token_count: token_count,
               last_included_seq: message_seq(normalized),
               metadata: Map.put(base_metadata, :compaction_inflight, false)
           }}

        compaction_inflight? ->
          {:ok,
           %Snapshot{
             snapshot
             | pending_messages: pending,
               token_count: token_count,
               last_included_seq: message_seq(normalized),
               metadata: base_metadata
           }}

        true ->
          interim = %Snapshot{
            snapshot
            | pending_messages: pending,
              token_count: token_count,
              last_included_seq: message_seq(normalized),
              metadata: Map.put(base_metadata, :compaction_inflight, true)
          }

          job = %{
            url: compaction_url,
            payload: %{
              strategy: "webhook",
              summary_messages: summary,
              pending_messages: pending,
              token_budget: max_tokens
            }
          }

          {:compact, interim, {:webhook, job}}
      end
    end
  end

  @impl true
  def apply_compaction(snapshot, result, config, _opts) do
    summary_messages =
      result
      |> Map.get("messages", Map.get(result, :messages, []))
      |> Enum.map(&ensure_seq/1)

    last_seq =
      summary_messages
      |> Enum.map(&message_seq/1)
      |> Enum.max(fn -> snapshot.last_compacted_seq || 0 end)

    max_tokens = token_budget(config)
    summary_tokens = estimate_tokens(summary_messages)

    cond do
      summary_tokens > max_tokens ->
        {:error, :summary_over_token_budget}

      summary_tokens > Strategy.max_token_budget() ->
        {:error, :summary_over_token_budget}

      true ->
        metadata =
          (snapshot.metadata || %{})
          |> Map.put(:compaction_inflight, false)
          |> Map.put(:pending_queue, :queue.new())
          |> Map.put(:summary_token_count, summary_tokens)
          |> Map.put(:token_budget, max_tokens)

        {:ok,
         %Snapshot{
           snapshot
           | summary_messages: summary_messages,
             pending_messages: [],
             token_count: summary_tokens,
             last_compacted_seq: last_seq,
             metadata: metadata
         }}
    end
  end

  defp ensure_seq(%{"seq" => _} = message), do: message
  defp ensure_seq(%{seq: _} = message), do: Map.put_new(message, "seq", message.seq)
  defp ensure_seq(message), do: Map.put_new(message, "seq", Map.get(message, :seq, 0))

  defp message_seq(%{"seq" => seq}) when is_integer(seq), do: seq
  defp message_seq(%{seq: seq}) when is_integer(seq), do: seq
  defp message_seq(_), do: 0

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
end
