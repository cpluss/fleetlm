defmodule Fastpaca.Runtime do
  @moduledoc """
  Public interface for the Raft-backed runtime. Controllers call into this
  module with sanitised data; no additional validation happens here.
  """

  require Logger

  alias Fastpaca.Context
  alias Fastpaca.Context.{Config, Message}
  alias Fastpaca.Runtime.{RaftFSM, RaftManager, RaftTopology}

  @timeout Application.compile_env(:fastpaca, :raft_command_timeout_ms, 2_000)
  @rpc_timeout Application.compile_env(:fastpaca, :rpc_timeout_ms, 5_000)

  # ---------------------------------------------------------------------------
  # Context lifecycle
  # ---------------------------------------------------------------------------

  @spec upsert_context(String.t(), Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def upsert_context(id, %Config{} = config, opts \\ []) when is_binary(id) do
    group = RaftManager.group_for_context(id)

    call_on_replica(group, :upsert_context_local, [id, config, opts], fn ->
      upsert_context_local(id, config, opts)
    end)
  end

  @doc false
  def upsert_context_local(id, %Config{} = config, opts \\ []) when is_binary(id) do
    status = Keyword.get(opts, :status, :active)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, server_id, lane, group} <- locate(id),
         :ok <- ensure_group_started(group),
         {:ok, {:reply, {:ok, data}}, _leader} <-
           :ra.process_command(
             {server_id, Node.self()},
             {:upsert_context, lane, id, config, status, metadata},
             @timeout
           ) do
      {:ok, data}
    else
      {:timeout, leader} -> {:timeout, leader}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_context(String.t()) :: {:ok, Context.t()} | {:error, term()}
  def get_context(id) when is_binary(id) do
    group = RaftManager.group_for_context(id)

    call_on_replica(group, :get_context_local, [id], fn ->
      get_context_local(id)
    end)
  end

  @doc false
  def get_context_local(id) when is_binary(id) do
    with {:ok, server_id, lane, _group} <- locate(id) do
      case :ra.consistent_query(server_id, fn state ->
             RaftFSM.query_context(state, lane, id)
           end) do
        {:ok, {:ok, context}, _leader} ->
          {:ok, context}

        {:ok, {:error, reason}, _leader} ->
          {:error, reason}

        {:ok, {{_term, _index}, {:ok, context}}, _leader} ->
          {:ok, context}

        {:ok, {{_term, _index}, {:error, reason}}, _leader} ->
          {:error, reason}

        {:timeout, leader} ->
          {:error, {:timeout, leader}}

        other ->
          other
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Messaging
  # ---------------------------------------------------------------------------

  @spec append_messages(String.t(), [Message.inbound_message()], keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:timeout, term()}
  def append_messages(id, message_inputs, opts \\ []) when is_binary(id) do
    group = RaftManager.group_for_context(id)

    call_on_replica(group, :append_messages_local, [id, message_inputs, opts], fn ->
      append_messages_local(id, message_inputs, opts)
    end)
  end

  @doc false
  def append_messages_local(id, message_inputs, opts \\ [])
      when is_binary(id) do
    with {:ok, server_id, lane, group} <- locate(id),
         :ok <- ensure_group_started(group) do
      case :ra.process_command(
             {server_id, Node.self()},
             {:append_batch, lane, id, message_inputs, opts},
             @timeout
           ) do
        {:ok, {:reply, {:ok, reply}}, _leader} -> {:ok, reply}
        {:ok, {:reply, {:error, reason}}, _leader} -> {:error, reason}
        {:timeout, leader} -> {:timeout, leader}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec compact(String.t(), list(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()} | {:timeout, term()}
  def compact(id, replacement, opts \\ []) when is_binary(id) do
    group = RaftManager.group_for_context(id)

    call_on_replica(group, :compact_local, [id, replacement, opts], fn ->
      compact_local(id, replacement, opts)
    end)
  end

  @doc false
  def compact_local(id, replacement, opts \\ []) when is_binary(id) do
    with {:ok, server_id, lane, group} <- locate(id),
         :ok <- ensure_group_started(group) do
      case :ra.process_command(
             {server_id, Node.self()},
             {:compact, lane, id, replacement, opts},
             @timeout
           ) do
        {:ok, {:reply, {:ok, version}}, _leader} -> {:ok, version}
        {:ok, {:reply, {:error, reason}}, _leader} -> {:error, reason}
        {:timeout, leader} -> {:timeout, leader}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec get_context_window(String.t()) :: {:ok, map()} | {:error, term()}
  def get_context_window(id) when is_binary(id) do
    with {:ok, %Context{} = context} <- get_context(id) do
      alias Fastpaca.Context.LLMContext

      {:ok,
       %{
         messages: LLMContext.to_list(context.llm_context),
         version: context.version,
         token_count: context.llm_context.token_count,
         metadata: context.llm_context.metadata,
         needs_compaction: Context.needs_compaction?(context)
       }}
    end
  end

  @doc """
  Retrieves messages from the tail (newest) with offset-based pagination.

  Designed for backward iteration starting from the most recent messages.
  Future-proof for scenarios where older messages may be paged from disk/remote storage.

  ## Parameters
    - `id`: Context ID
    - `offset`: Number of messages to skip from tail (0 = most recent, default: 0)
    - `limit`: Maximum messages to return (must be > 0, default: 100)

  ## Examples
      # Get last 50 messages
      get_messages_tail("ctx-123", 0, 50)

      # Get next page (messages 51-100 from tail)
      get_messages_tail("ctx-123", 50, 50)

  Returns `{:ok, messages}` where messages are in chronological order (oldest to newest).
  """
  @spec get_messages_tail(String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def get_messages_tail(id, offset \\ 0, limit \\ 100)
      when is_binary(id) and is_integer(offset) and offset >= 0 and is_integer(limit) and
             limit > 0 do
    group = RaftManager.group_for_context(id)

    call_on_replica(group, :get_messages_tail_local, [id, offset, limit], fn ->
      get_messages_tail_local(id, offset, limit)
    end)
  end

  # ---------------------------------------------------------------------------
  # Archival acknowledgements (tiered storage integration point)
  # ---------------------------------------------------------------------------

  @spec ack_archived(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()} | {:timeout, term()}
  def ack_archived(id, upto_seq) when is_binary(id) and is_integer(upto_seq) and upto_seq >= 0 do
    group = RaftManager.group_for_context(id)

    call_on_replica(group, :ack_archived_local, [id, upto_seq], fn ->
      ack_archived_local(id, upto_seq)
    end)
  end

  @doc false
  def ack_archived_local(id, upto_seq) when is_binary(id) and is_integer(upto_seq) and upto_seq >= 0 do
    with {:ok, server_id, lane, group} <- locate(id),
         :ok <- ensure_group_started(group) do
      case :ra.process_command(
             {server_id, Node.self()},
             {:ack_archived, lane, id, upto_seq},
             @timeout
           ) do
        {:ok, {:reply, {:ok, reply}}, _leader} -> {:ok, reply}
        {:ok, {:reply, {:error, reason}}, _leader} -> {:error, reason}
        {:timeout, leader} -> {:timeout, leader}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def get_messages_tail_local(id, offset, limit)
      when is_binary(id) and is_integer(offset) and offset >= 0 and is_integer(limit) and
             limit > 0 do
    with {:ok, server_id, lane, _group} <- locate(id) do
      case :ra.consistent_query(server_id, fn state ->
             RaftFSM.query_messages_tail(state, lane, id, offset, limit)
           end) do
        {:ok, messages, _leader} when is_list(messages) ->
          {:ok, messages}

        {:ok, {{_term, _index}, messages}, _leader} when is_list(messages) ->
          {:ok, messages}

        {:timeout, leader} ->
          {:error, {:timeout, leader}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp locate(id) do
    group = RaftManager.group_for_context(id)
    lane = :erlang.phash2(id, 16)
    server_id = RaftManager.server_id(group)
    {:ok, server_id, lane, group}
  end

  defp ensure_group_started(group_id) do
    case RaftManager.start_group(group_id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_on_replica(group_id, fun, args, local_fun) do
    case route_target(group_id) do
      {:local, _node} ->
        local_fun.()

      {:remote, []} ->
        {:error, {:no_available_replicas, []}}

      {:remote, nodes} ->
        try_remote(nodes, fun, args, MapSet.new(), [])
    end
  end

  defp try_remote([], _fun, _args, _visited, failures) do
    {:error, {:no_available_replicas, Enum.reverse(failures)}}
  end

  defp try_remote([node | rest], fun, args, visited, failures) do
    if MapSet.member?(visited, node) do
      try_remote(rest, fun, args, visited, failures)
    else
      visited = MapSet.put(visited, node)

      case safe_rpc_call(node, fun, args) do
        {:badrpc, reason} ->
          Logger.warning("Runtime RPC to #{inspect(node)} failed: #{inspect(reason)}")
          try_remote(rest, fun, args, visited, [{node, {:badrpc, reason}} | failures])

        {:error, {:not_leader, leader}} ->
          rest = maybe_enqueue_leader(leader, rest, visited)
          try_remote(rest, fun, args, visited, [{node, {:not_leader, leader}} | failures])

        {:error, :not_leader} ->
          try_remote(rest, fun, args, visited, [{node, :not_leader} | failures])

        other ->
          other
      end
    end
  end

  defp safe_rpc_call(node, fun, args) do
    :rpc.call(node, __MODULE__, fun, args, @rpc_timeout)
  catch
    :exit, reason ->
      {:badrpc, reason}
  end

  defp maybe_enqueue_leader({server_id, leader_node}, rest, visited)
       when is_atom(server_id) and is_atom(leader_node) do
    cond do
      MapSet.member?(visited, leader_node) -> rest
      Enum.member?(rest, leader_node) -> rest
      true -> [leader_node | rest]
    end
  end

  defp maybe_enqueue_leader(_leader, rest, _visited), do: rest

  @doc false
  def route_target(group_id, opts \\ []) do
    self_node = Keyword.get(opts, :self, Node.self())
    replicas = Keyword.get(opts, :replicas, RaftManager.replicas_for_group(group_id))
    ready_nodes = Keyword.get(opts, :ready_nodes, RaftTopology.ready_nodes())

    cond do
      self_node in replicas ->
        {:local, self_node}

      true ->
        ready_candidates =
          replicas
          |> Enum.filter(&(&1 in ready_nodes))

        fallbacks = replicas -- ready_candidates

        {:remote, Enum.uniq(ready_candidates ++ fallbacks)}
    end
  end
end
