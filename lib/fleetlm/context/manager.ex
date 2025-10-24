defmodule Fleetlm.Context.Manager do
  @moduledoc """
  Incrementally maintains agent context snapshots and produces payloads
  for dispatch. Strategies are responsible for trimming or compacting the
  context window while this module orchestrates persistence and normalization.
  """

  require Logger

  alias Fleetlm.Context.{Registry, Snapshot}
  alias Fleetlm.Observability.Telemetry

  @type normalized_result ::
          {:ok, Snapshot.t()}
          | {:compact, Snapshot.t(), {:webhook, map()}}
          | {:error, term()}

  @spec append_message(
          map(),
          Snapshot.t() | nil,
          map(),
          Fleetlm.Agent.t(),
          keyword()
        ) :: normalized_result()
  def append_message(conversation, snapshot, message, agent, opts \\ []) do
    strategy_id = agent.context_strategy || "last_n"
    config = agent.context_strategy_config || %{}
    start_time = System.monotonic_time(:microsecond)

    result =
      with {:ok, strategy_mod} <- Registry.fetch(strategy_id),
           :ok <- validate_config(strategy_mod, config) do
        snapshot = ensure_snapshot_version(snapshot, strategy_id, config)

        _conversation = normalize_conversation(conversation)

        case strategy_mod.append_message(
               snapshot,
               normalize_message(message),
               config,
               opts
             ) do
          {:ok, %Snapshot{} = updated} ->
            {:ok, stamp(updated, strategy_id, config)}

          {:compact, %Snapshot{} = interim, {:webhook, job}} ->
            {:compact, stamp(interim, strategy_id, config), {:webhook, job}}

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, {:invalid_strategy_response, other}}
        end
      end

    duration = System.monotonic_time(:microsecond) - start_time
    emit_build_telemetry(result, strategy_id, duration)

    result
  end

  @spec apply_compaction(
          map(),
          Snapshot.t(),
          map(),
          Fleetlm.Agent.t(),
          keyword()
        ) :: {:ok, Snapshot.t()} | {:error, term()}
  def apply_compaction(conversation, snapshot, result, agent, opts \\ []) do
    strategy_id = agent.context_strategy || "last_n"
    config = agent.context_strategy_config || %{}

    with {:ok, strategy_mod} <- Registry.fetch(strategy_id),
         :ok <- validate_config(strategy_mod, config) do
      _conversation = normalize_conversation(conversation)

      case strategy_mod.apply_compaction(snapshot, normalize_result(result), config, opts) do
        {:ok, %Snapshot{} = updated} ->
          {:ok, stamp(updated, strategy_id, config)}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, {:invalid_strategy_response, other}}
      end
    end
  end

  @spec compaction_failed(Snapshot.t()) :: Snapshot.t()
  def compaction_failed(%Snapshot{} = snapshot) do
    metadata = Map.put(snapshot.metadata || %{}, :compaction_inflight, false)
    %{snapshot | metadata: metadata}
  end

  @spec payload_from_snapshot(Snapshot.t()) :: %{messages: [map()], context: map()}
  def payload_from_snapshot(%Snapshot{} = snapshot) do
    messages = (snapshot.summary_messages || []) ++ (snapshot.pending_messages || [])

    %{
      messages: messages,
      context: %{
        strategy: snapshot.strategy_id,
        metadata: %{
          token_count: snapshot.token_count,
          last_compacted_seq: snapshot.last_compacted_seq,
          last_included_seq: snapshot.last_included_seq
        }
      }
    }
  end

  defp validate_config(strategy_mod, config) do
    if function_exported?(strategy_mod, :validate_config, 1) do
      strategy_mod.validate_config(config)
    else
      :ok
    end
  end

  defp normalize_conversation(%{__struct__: _} = conversation), do: Map.from_struct(conversation)
  defp normalize_conversation(conversation) when is_map(conversation), do: conversation
  defp normalize_conversation(_), do: %{}

  defp normalize_message(%{__struct__: _} = message),
    do: Map.from_struct(message) |> normalize_message()

  defp normalize_message(message) when is_map(message) do
    message
    |> Map.update(:inserted_at, Map.get(message, "inserted_at"), fn
      %NaiveDateTime{} = dt -> NaiveDateTime.to_iso8601(dt)
      other -> other
    end)
  end

  defp normalize_message(message), do: %{"content" => inspect(message)}

  defp normalize_result(result) when is_map(result), do: result
  defp normalize_result(result), do: %{"result" => result}

  defp ensure_snapshot_version(nil, _strategy_id, _config), do: nil

  defp ensure_snapshot_version(%Snapshot{} = snapshot, strategy_id, config) do
    current = stamp(%Snapshot{snapshot | metadata: snapshot.metadata || %{}}, strategy_id, config)
    %{current | strategy_id: snapshot.strategy_id || strategy_id}
  end

  defp stamp(%Snapshot{} = snapshot, strategy_id, config) do
    %{snapshot | strategy_id: strategy_id, strategy_version: config_version(config)}
  end

  defp config_version(config), do: :erlang.phash2(config)

  defp emit_build_telemetry({:ok, %Snapshot{} = snapshot}, strategy, duration) do
    Telemetry.emit_context_build(
      :ok,
      strategy,
      duration,
      %{
        token_count: snapshot.token_count,
        summary_count: length(snapshot.summary_messages || []),
        pending_count: length(snapshot.pending_messages || []),
        token_budget: Map.get(snapshot.metadata || %{}, :token_budget),
        decision: :ok
      }
    )
  end

  defp emit_build_telemetry({:compact, %Snapshot{} = snapshot, _job}, strategy, duration) do
    Telemetry.emit_context_build(
      :ok,
      strategy,
      duration,
      %{
        token_count: snapshot.token_count,
        summary_count: length(snapshot.summary_messages || []),
        pending_count: length(snapshot.pending_messages || []),
        token_budget: Map.get(snapshot.metadata || %{}, :token_budget),
        decision: :compact
      }
    )
  end

  defp emit_build_telemetry({:error, reason}, strategy, duration) do
    Telemetry.emit_context_build(
      :error,
      strategy,
      duration,
      %{reason: inspect(reason)}
    )
  end

  defp emit_build_telemetry(_other, _strategy, _duration), do: :ok
end
