defmodule Fleetlm.Webhook.Worker do
  @moduledoc """
  Per-session state machine that orchestrates agent catch-up work. The worker
  holds any cached context snapshot between dispatches so we can avoid
  rebuilding transient summaries from scratch on every message.
  """

  @behaviour :gen_statem

  require Logger

  alias Fleetlm.Runtime
  alias Fleetlm.Webhook.Executor

  defstruct session_id: nil,
            agent_id: nil,
            user_id: nil,
            epoch: 0,
            target_seq: 0,
            last_sent_seq: 0,
            user_message_sent_at: nil,
            context_snapshot: nil,
            compaction_job: nil

  @type state_data :: %__MODULE__{}

  ## Public API

  def child_spec(session_id) do
    %{
      id: {:webhook_worker, session_id},
      start: {__MODULE__, :start_link, [session_id]},
      restart: :temporary
    }
  end

  def start_link(session_id) do
    :gen_statem.start_link(
      {:via, Registry, {Fleetlm.Webhook.WorkerRegistry, session_id}},
      __MODULE__,
      session_id,
      []
    )
  end

  ## :gen_statem callbacks

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(session_id) do
    {:ok, :idle, %__MODULE__{session_id: session_id}}
  end

  ### Idle state

  def idle(:cast, {:catch_up, params}, data) do
    data =
      data
      |> assign_catch_up(params)

    {:next_state, :catching_up, data, {:next_event, :internal, :run}}
  end

  def idle(:cast, {:compact, params}, data) do
    data = assign_compaction(data, params)
    {:next_state, :compacting, data, {:next_event, :internal, :run}}
  end

  def idle(_event_type, _event_content, data) do
    {:keep_state, data}
  end

  ### Catching-up state

  def catching_up(:cast, {:catch_up, params}, data) do
    updated = assign_catch_up(data, params)
    {:next_state, :catching_up, updated, {:next_event, :internal, :run}}
  end

  def catching_up(:cast, {:compact, params}, data) do
    updated = assign_compaction(data, params)
    {:next_state, :compacting, updated, {:next_event, :internal, :run}}
  end

  def catching_up(:internal, :run, %{target_seq: target, last_sent_seq: sent} = data)
      when target <= sent do
    Runtime.agent_caught_up(data.session_id, data.epoch, sent)

    {:next_state, :idle, reset_after_catch_up(data)}
  end

  def catching_up(:internal, :run, data) do
    Logger.debug("Webhook worker processing catch-up",
      session_id: data.session_id,
      epoch: data.epoch,
      target_seq: data.target_seq,
      last_sent_seq: data.last_sent_seq
    )

    case Executor.catch_up(%{
           session_id: data.session_id,
           agent_id: data.agent_id,
           user_id: data.user_id,
           from_seq: data.last_sent_seq,
           to_seq: data.target_seq,
           user_message_sent_at: data.user_message_sent_at,
           context_snapshot: data.context_snapshot
         }) do
      {:ok, %{last_sent_seq: new_seq, snapshot: snapshot}} ->
        Runtime.agent_caught_up(data.session_id, data.epoch, new_seq)

        {:next_state, :idle,
         reset_after_catch_up(%{data | last_sent_seq: new_seq, context_snapshot: snapshot})}

      {:error, reason} ->
        Runtime.agent_catchup_failed(data.session_id, data.epoch, reason)
        {:next_state, :idle, reset_after_catch_up(data)}
    end
  end

  def catching_up(_type, _content, data) do
    {:keep_state, data}
  end

  ### Compacting state

  def compacting(:cast, {:catch_up, params}, data) do
    data = assign_catch_up(data, params)
    {:keep_state, data}
  end

  def compacting(:cast, {:compact, params}, data) do
    data = assign_compaction(data, params)
    {:keep_state, data}
  end

  def compacting(:internal, :run, %{compaction_job: nil} = data) do
    {:next_state, :idle, data}
  end

  def compacting(:internal, :run, %{compaction_job: job} = data) do
    Logger.debug("Webhook worker compaction run", session_id: data.session_id)

    case Executor.compact(job) do
      {:ok, result} ->
        Runtime.context_compaction_complete(data.session_id, result)
        {:next_state, :idle, reset_after_compaction(data)}

      {:error, reason} ->
        Runtime.context_compaction_failed(data.session_id, reason)
        {:next_state, :idle, reset_after_compaction(data)}
    end
  end

  def compacting(_type, _content, data) do
    {:keep_state, data}
  end

  @impl true
  def terminate(_reason, _state, _data) do
    :ok
  end

  ## Internal helpers

  defp assign_catch_up(data, %{
         epoch: epoch,
         agent_id: agent_id,
         user_id: user_id,
         target_seq: target_seq,
         last_sent_seq: last_sent_seq,
         user_message_sent_at: sent_at
       }) do
    %{
      data
      | epoch: epoch,
        agent_id: agent_id,
        user_id: user_id,
        target_seq: target_seq,
        last_sent_seq: last_sent_seq,
        user_message_sent_at: sent_at
    }
  end

  defp assign_compaction(data, %{job: job}) do
    %{data | compaction_job: job}
  end

  defp reset_after_catch_up(data) do
    %{
      data
      | user_message_sent_at: nil,
        target_seq: data.last_sent_seq
    }
  end

  defp reset_after_compaction(data) do
    %{data | compaction_job: nil}
  end
end
