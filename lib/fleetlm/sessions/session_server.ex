defmodule Fleetlm.Sessions.SessionServer do
  @moduledoc """
  Per-session GenServer responsible for orchestrating runtime state.

  Each active session has a dedicated process that:
  * Hydrates and maintains the cached tail in Cachex
  * Broadcasts session messages via `Fleetlm.Sessions.Events`
  * Provides a lightweight `load_tail/1` API for channel joins

  The server does **not** own persistence—that work happens in
  `Fleetlm.Sessions.append_message/2`—but it reacts to persisted changes to
  keep the runtime consistent and fan-out real-time updates.
  """

  use GenServer, restart: :transient

  alias Fleetlm.Sessions
  alias Fleetlm.Sessions.Cache
  alias Fleetlm.Sessions.Events
  alias Fleetlm.Sessions.SessionSupervisor

  @tail_limit 100

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(session_id) when is_binary(session_id) do
    GenServer.start_link(__MODULE__, {session_id, nil}, name: via(session_id))
  end

  def start_link({session_id, opts}) when is_binary(session_id) and is_list(opts) do
    owner = Keyword.get(opts, :sandbox_owner)
    GenServer.start_link(__MODULE__, {session_id, owner}, name: via(session_id))
  end

  @spec append_message(map()) :: :ok
  def append_message(%{session_id: session_id} = message) when is_binary(session_id) do
    SessionSupervisor.ensure_started(session_id)
    GenServer.cast(via(session_id), {:append, message})
  end

  @spec load_tail(String.t()) :: {:ok, [map()]} | {:error, term()}
  def load_tail(session_id) do
    SessionSupervisor.ensure_started(session_id)
    GenServer.call(via(session_id), :tail)
  end

  defp via(session_id), do: {:via, Registry, {Fleetlm.Sessions.SessionRegistry, session_id}}

  @impl true
  def init({session_id, owner}) do
    maybe_put_owner(owner)
    maybe_allow_sandbox(owner)
    tail = warm_cache(session_id)
    {:ok, %{session_id: session_id, tail: tail, sandbox_owner: owner}}
  end

  @impl true
  def handle_cast({:append, message}, %{session_id: session_id} = state) do
    maybe_put_owner(state.sandbox_owner)
    _ = Cache.append_to_tail(session_id, message, limit: @tail_limit)
    Events.publish_message(message)

    {:noreply, %{state | tail: Enum.take([message | state.tail], @tail_limit)}}
  end

  @impl true
  def handle_call(:tail, _from, state) do
    maybe_put_owner(state.sandbox_owner)
    {:reply, {:ok, state.tail}, state}
  end

  defp warm_cache(session_id) do
    case Cache.fetch_tail(session_id, limit: @tail_limit) do
      {:ok, messages} ->
        messages

      :miss ->
        messages = preload_tail(session_id)
        _ = Cache.put_tail(session_id, messages)
        messages

      {:error, _reason} ->
        messages = preload_tail(session_id)
        _ = Cache.put_tail(session_id, messages)
        messages
    end
  end

  defp maybe_allow_sandbox(nil), do: :ok

  defp maybe_allow_sandbox(owner) when is_pid(owner) do
    if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
      Ecto.Adapters.SQL.Sandbox.allow(Fleetlm.Repo, owner, self())
    else
      :ok
    end
  end

  defp maybe_put_owner(nil), do: :ok
  defp maybe_put_owner(owner) when is_pid(owner), do: Process.put(:sandbox_owner, owner)

  defp preload_tail(session_id) do
    session = Sessions.get_session!(session_id)

    Sessions.list_messages(session_id, limit: @tail_limit)
    |> Enum.map(fn message ->
      message
      |> Map.from_struct()
      |> Map.put(:session, session)
    end)
    |> Enum.reverse()
  end
end
