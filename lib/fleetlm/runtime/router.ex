defmodule Fleetlm.Runtime.Router do
  @moduledoc """
  Edge node router that directs session operations to the correct owner node.

  Responsibilities:
  - Determine owner node for a session using HashRing
  - Route calls to SessionServer on owner node (local or remote via :erpc)
  - Provide stateless API boundary for SessionChannel and other clients

  This module is called from edge nodes (where clients connect via WebSocket)
  and routes to owner nodes (where SessionServer processes live).
  """

  require Logger

  alias Fleetlm.Runtime.Sharding.HashRing
  alias Fleetlm.Runtime.SessionServer
  alias Fleetlm.Runtime.SessionSupervisor

  @doc """
  Append a message to a session.
  Routes to the owner node for the session.
  """
  @spec append_message(String.t(), String.t(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def append_message(session_id, sender_id, kind, content, metadata \\ %{}) do
    case route_to_owner(session_id, :append_message, [
           session_id,
           sender_id,
           kind,
           content,
           metadata
         ]) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} = error ->
        Logger.error("Failed to append message to session #{session_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Join a session and get message replay.
  Routes to the owner node for the session.
  """
  @spec join(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def join(session_id, participant_id, opts \\ []) do
    case route_to_owner(session_id, :join, [session_id, participant_id, opts]) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} = error ->
        Logger.error("Failed to join session #{session_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Drain a session for graceful shutdown.
  Routes to the owner node for the session.
  """
  @spec drain(String.t()) :: :ok | {:error, term()}
  def drain(session_id) do
    case route_to_owner(session_id, :drain, [session_id]) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error("Failed to drain session #{session_id}: #{inspect(reason)}")
        error
    end
  end

  # Private helpers

  defp route_to_owner(session_id, function, args) do
    slot = HashRing.slot_for_session(session_id)
    owner_node = HashRing.owner_node(slot)

    cond do
      # Owner is local node - call directly
      owner_node == Node.self() ->
        call_local(session_id, function, args)

      # Owner is remote node - use :erpc
      true ->
        call_remote(owner_node, session_id, function, args)
    end
  end

  defp call_local(session_id, function, args) do
    # Ensure SessionServer is started
    case SessionSupervisor.ensure_started(session_id) do
      {:ok, _pid} ->
        apply(SessionServer, function, args)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_remote(owner_node, session_id, function, args) do
    try do
      # Ensure SessionServer is started on remote node
      case :erpc.call(owner_node, SessionSupervisor, :ensure_started, [session_id]) do
        {:ok, _pid} ->
          # Call the function on the remote SessionServer
          :erpc.call(owner_node, SessionServer, function, args)

        {:error, reason} ->
          {:error, reason}
      end
    catch
      :error, {:erpc, reason} ->
        Logger.error(
          "ERPC failed for session #{session_id} on node #{owner_node}: #{inspect(reason)}"
        )

        {:error, {:erpc_failed, reason}}
    end
  end
end
