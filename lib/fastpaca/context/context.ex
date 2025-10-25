defmodule Fastpaca.Context do
  @moduledoc """
  Core context entity persisted inside Raft with typed UI messages and LLM view.
  """

  alias Fastpaca.Context.{Config, Message, MessageLog}

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

  defmodule LLMContext do
    @moduledoc "LLM-facing window (context window) of a context"
    @enforce_keys [:messages, :token_count]
    defstruct messages: [], token_count: 0, metadata: %{}

    @type t :: %__MODULE__{
            messages: [Fastpaca.Context.ui_message()],
            token_count: non_neg_integer(),
            metadata: map()
          }
  end

  defmodule Policy do
    @moduledoc "Policy behaviour for building LLM context from the message log"
    alias Fastpaca.Context.LLMContext

    @callback apply([Fastpaca.Context.ui_message()], LLMContext.t(), map()) ::
                {:ok, LLMContext.t(), :compact | :noop} | {:error, term()}
  end

  @enforce_keys [
    :id,
    :config,
    :status,
    :message_log,
    :llm_context,
    :last_seq,
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
    :version,
    :inserted_at,
    :updated_at,
    :metadata
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          config: Config.t(),
          status: :active | :tombstoned,
          # What users care about: message log
          message_log: MessageLog.t(),
          # What the LLM cares about: the LLM context
          llm_context: LLMContext.t(),
          last_seq: non_neg_integer(),
          version: non_neg_integer(),
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t(),
          metadata: %{optional(atom()) => term()}
        }

  @spec new(String.t(), Config.t(), keyword()) :: t()
  def new(id, %Config{} = config, opts \\ []) do
    now = Keyword.get(opts, :timestamp, NaiveDateTime.utc_now())

    %__MODULE__{
      id: id,
      config: config,
      status: Keyword.get(opts, :status, :active),
      metadata: Keyword.get(opts, :metadata, %{}),
      message_log: MessageLog.new(),
      llm_context: llm_initialize(config),
      last_seq: 0,
      version: 0,
      inserted_at: now,
      updated_at: now
    }
  end

  @spec update(t(), Config.t(), keyword()) :: t()
  def update(%__MODULE__{} = context, %Config{} = config, opts) do
    now = NaiveDateTime.utc_now()

    %__MODULE__{
      context
      | config: config,
        status: Keyword.get(opts, :status, context.status),
        metadata: Keyword.get(opts, :metadata, context.metadata || %{}),
        updated_at: now
    }
  end

  @type inbound :: {role(), [part()], %{optional(atom()) => term()}, non_neg_integer()}

  @spec append(t(), [inbound()]) :: {t(), [Message.t()], :compact | :noop}
  def append(%__MODULE__{} = context, inbound_messages) do
    {message_log, appended, last_seq} =
      MessageLog.append(context.message_log, inbound_messages, context.last_seq)

    {llm_context, flag} =
      llm_append(context.config, MessageLog.entries(message_log), appended, context.llm_context)

    new_context = %__MODULE__{
      context
      | message_log: message_log,
        llm_context: llm_context,
        last_seq: last_seq,
        version: context.version + 1,
        updated_at: NaiveDateTime.utc_now()
    }

    {new_context, appended, flag}
  end

  @spec manual_compact(t(), [ui_message()]) :: {t(), LLMContext.t()}
  def manual_compact(%__MODULE__{} = context, replacement) do
    llm_context = llm_manual_compact(context.config, replacement, context.llm_context)

    new_context = %__MODULE__{
      context
      | llm_context: llm_context,
        version: context.version + 1,
        updated_at: NaiveDateTime.utc_now()
    }

    {new_context, llm_context}
  end

  @spec tombstone(t()) :: t()
  def tombstone(%__MODULE__{} = context),
    do: %__MODULE__{context | status: :tombstoned, updated_at: NaiveDateTime.utc_now()}

  @spec messages_after(t(), non_neg_integer(), pos_integer() | :infinity) :: [Message.t()]
  def messages_after(%__MODULE__{} = context, after_seq, limit),
    do: MessageLog.slice(context.message_log, after_seq, limit)

  @spec window(t()) :: %{
          messages: [ui_message()],
          version: non_neg_integer(),
          token_count: non_neg_integer(),
          metadata: %{optional(atom()) => term()},
          needs_compaction: boolean()
        }
  def window(%__MODULE__{} = context) do
    llm = context.llm_context

    %{
      messages: llm.messages,
      version: context.version,
      token_count: llm.token_count,
      metadata: llm.metadata,
      needs_compaction: llm.token_count > (context.config.token_budget * context.config.trigger_ratio)
    }
  end

  # -- LLM helpers -----------------------------------------------------------

  @spec llm_initialize(Config.t()) :: LLMContext.t()
  defp llm_initialize(_config), do: %LLMContext{messages: [], token_count: 0, metadata: %{}}

  @spec llm_append(Config.t(), [Message.t()], [Message.t()], LLMContext.t()) ::
          {LLMContext.t(), :compact | :noop}
  defp llm_append(%Config{} = config, full_log, appended, %LLMContext{} = view) do
    appended_items = Enum.map(appended, &to_view_item/1)
    log_view = Enum.map(full_log, &to_view_item/1)

    view = %LLMContext{
      view
      | messages: view.messages ++ appended_items,
        token_count: view.token_count + sum_tokens(appended_items)
    }

    if exceeds_trigger?(view.token_count, config) do
      run_policy(log_view, view, config)
    else
      {view, :noop}
    end
  end

  @spec llm_manual_compact(Config.t(), [ui_message()], LLMContext.t()) :: LLMContext.t()
  defp llm_manual_compact(_config, replacement, _view) do
    messages = Enum.map(replacement, &normalize_view_item/1)

    %LLMContext{
      messages: messages,
      token_count: sum_tokens(messages),
      metadata: %{strategy: "manual"}
    }
  end

  defp run_policy(messages, view, %Config{policy: %{strategy: id, config: cfg}}) do
    module = policy_module(id)

    case module.apply(messages, view, cfg || %{}) do
      {:ok, %LLMContext{} = new_view, flag} -> {new_view, flag}
      {:error, _reason} -> {view, :noop}
    end
  end

  defp policy_module("skip_parts"), do: Fastpaca.Context.Strategies.SkipParts
  defp policy_module("manual"), do: Fastpaca.Context.Strategies.Manual
  defp policy_module(_), do: Fastpaca.Context.Strategies.LastN

  defp to_view_item(%Message{} = message),
    do: %{
      role: message.role,
      parts: message.parts,
      metadata: message.metadata,
      token_count: message.token_count,
      seq: message.seq,
      inserted_at: message.inserted_at
    }

  defp normalize_view_item(%{
         role: role,
         parts: parts,
         metadata: metadata,
         token_count: token_count,
         seq: seq,
         inserted_at: inserted_at
       }) do
    %{
      role: role,
      parts: parts,
      metadata: metadata,
      token_count: token_count,
      seq: seq,
      inserted_at: inserted_at
    }
  end

  defp sum_tokens(items), do: Enum.reduce(items, 0, fn item, acc -> acc + item.token_count end)

  defp exceeds_trigger?(token_count, %Config{token_budget: budget, trigger_ratio: ratio})
       when is_integer(budget) and budget > 0 and is_float(ratio),
       do: token_count > trunc(budget * ratio)

  defp exceeds_trigger?(_, _), do: false
end
