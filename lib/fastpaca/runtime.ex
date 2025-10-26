defmodule Fastpaca.Runtime do
  @moduledoc """
  Public interface for the Raft-backed runtime. Controllers call into this
  module with sanitised data; no additional validation happens here.
  """

  alias Fastpaca.Context
  alias Fastpaca.Context.{Config, Message}
  alias Fastpaca.Runtime.{RaftManager, RaftFSM}

  @timeout Application.compile_env(:fastpaca, :raft_command_timeout_ms, 2_000)

  # ---------------------------------------------------------------------------
  # Context lifecycle
  # ---------------------------------------------------------------------------

  @spec upsert_context(String.t(), Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def upsert_context(id, %Config{} = config, opts \\ []) when is_binary(id) do
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
end
