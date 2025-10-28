defmodule Fastpaca.Context do
  @moduledoc """
  Core context entity persisted inside Raft with typed UI messages and LLM view.
  """

  alias __MODULE__, as: Context
  alias Fastpaca.Context.{Config, LLMContext, MessageLog}

  @type role :: String.t()
  @type part :: %{required(:type) => String.t(), optional(atom()) => term()}
  @type ui_message :: %{
          role: role(),
          parts: [part()],
          seq: non_neg_integer(),
          inserted_at: NaiveDateTime.t(),
          token_count: non_neg_integer(),
          metadata: map()
        }
  @type inbound :: {role(), [part()], map(), non_neg_integer()}

  @enforce_keys [
    :id,
    :config,
    :status,
    :message_log,
    :llm_context,
    :last_seq,
    :archived_seq,
    :version,
    :inserted_at,
    :updated_at
  ]
  defstruct [
    :id,
    :config,
    :status,
    :message_log,
    :llm_context,
    :last_seq,
    :archived_seq,
    :version,
    :inserted_at,
    :updated_at,
    :metadata,
    :retention
  ]

  @type t :: %Context{
          id: String.t(),
          config: Config.t(),
          status: :active | :tombstoned,
          # What users care about: message log
          message_log: MessageLog.t(),
          # What the LLM cares about: the LLM context
          llm_context: LLMContext.t(),
          last_seq: non_neg_integer(),
          archived_seq: non_neg_integer(),
          version: non_neg_integer(),
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t(),
          metadata: %{optional(atom()) => term()},
          retention: %{tail_keep: pos_integer()}
        }

  @spec new(String.t(), Config.t(), keyword()) :: t()
  def new(id, %Config{} = config, opts \\ []) do
    now = Keyword.get(opts, :timestamp, NaiveDateTime.utc_now())

    tail_keep =
      opts[:tail_keep] || Application.get_env(:fastpaca, :tail_keep, 1_000)

    %Context{
      id: id,
      config: config,
      status: Keyword.get(opts, :status, :active),
      metadata: Keyword.get(opts, :metadata, %{}),
      message_log: MessageLog.new(),
      llm_context: LLMContext.new(),
      last_seq: 0,
      archived_seq: 0,
      version: 0,
      inserted_at: now,
      updated_at: now,
      retention: %{tail_keep: tail_keep}
    }
  end

  @spec update(t(), Config.t(), keyword()) :: t()
  def update(%Context{} = context, %Config{} = config, opts) do
    now = NaiveDateTime.utc_now()

    %Context{
      context
      | config: config,
        status: Keyword.get(opts, :status, context.status),
        metadata: Keyword.get(opts, :metadata, context.metadata),
        updated_at: now
    }
  end

  @spec append(t(), [inbound()]) :: {t(), [ui_message()], :compact | :noop}
  def append(%Context{} = context, inbound_messages) do
    {message_log, appended, last_seq} =
      MessageLog.append(context.message_log, inbound_messages, context.last_seq)

    llm_context = LLMContext.append(context.llm_context, appended)

    {new_llm_context, flag} =
      if exceeds_trigger?(llm_context.token_count, context.config) do
        {:ok, new_llm_context, flag} =
          case context.config.policy.strategy do
            :skip_parts ->
              Fastpaca.Context.Policies.SkipParts.apply(llm_context, context.config.policy.config)

            :manual ->
              Fastpaca.Context.Policies.Manual.apply(llm_context, context.config.policy.config)

            :last_n ->
              Fastpaca.Context.Policies.LastN.apply(llm_context, context.config.policy.config)
          end

        {new_llm_context, flag}
      else
        {llm_context, :noop}
      end

    new_context = %Context{
      context
      | message_log: message_log,
        llm_context: new_llm_context,
        last_seq: last_seq,
        version: context.version + 1,
        updated_at: NaiveDateTime.utc_now()
    }

    {new_context, appended, flag}
  end

  @spec compact(t(), [ui_message()]) :: {t(), LLMContext.t()}
  def compact(%Context{} = context, replacement) when is_list(replacement) do
    llm_context = LLMContext.compact(context.llm_context, replacement)

    new_context = %Context{
      context
      | llm_context: llm_context,
        version: context.version + 1,
        updated_at: NaiveDateTime.utc_now()
    }

    {new_context, llm_context}
  end

  @spec tombstone(t()) :: t()
  def tombstone(%Context{} = context),
    do: %Context{context | status: :tombstoned, updated_at: NaiveDateTime.utc_now()}

  @doc """
  Retrieves messages from the tail (newest) with offset-based pagination.

  Designed for backward iteration from the most recent messages. Future-proof
  for scenarios where older messages may be paged from disk/remote storage.

  ## Parameters
    - `offset`: Number of messages to skip from tail (0 = most recent)
    - `limit`: Maximum messages to return

  Returns messages in chronological order (oldest to newest).
  """
  @spec messages_tail(t(), non_neg_integer(), pos_integer()) :: [ui_message()]
  def messages_tail(%Context{} = context, offset, limit),
    do: MessageLog.tail_with_offset(context.message_log, offset, limit)

  @spec needs_compaction?(t()) :: boolean()
  def needs_compaction?(%Context{} = context) do
    context.llm_context.token_count > context.config.token_budget * context.config.trigger_ratio
  end

  # -- Helpers -----------------------------------------------------------

  defp exceeds_trigger?(token_count, %Config{token_budget: budget, trigger_ratio: ratio})
       when is_integer(budget) and budget > 0 and is_float(ratio),
       do: token_count > trunc(budget * ratio)

  defp exceeds_trigger?(_, _), do: false

  @doc """
  Apply an archive acknowledgement up to `upto_seq`, trimming the log while
  retaining a bounded tail below the boundary.
  """
  @spec persist_ack(t(), non_neg_integer()) :: {t(), non_neg_integer()}
  def persist_ack(%Context{} = context, upto_seq) when is_integer(upto_seq) and upto_seq >= 0 do
    tail_keep = context.retention.tail_keep
    archived_seq = max(context.archived_seq, upto_seq)
    {message_log, trimmed} = MessageLog.trim_ack(context.message_log, archived_seq, tail_keep)

    {%Context{
       context
       | archived_seq: archived_seq,
         message_log: message_log,
         updated_at: NaiveDateTime.utc_now()
     }, trimmed}
  end
end
