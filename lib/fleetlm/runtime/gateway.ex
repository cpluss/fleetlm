defmodule Fleetlm.Runtime.Gateway do
  @moduledoc """
  Stateless boundary used by gateway processes (HTTP/WS) to interact with
  the chat session runtime. This layer is intentionally thin today so we can
  evolve the underlying session orchestration without leaking persistence
  details to Phoenix controllers or channels.
  """

  alias Fleetlm.Sessions
  alias Fleetlm.Sessions.ChatMessage
  alias Fleetlm.Sessions.ChatSession

  @doc """
  Append a message to the session and return the persisted record.
  """
  @spec append_message(String.t(), map()) :: {:ok, ChatMessage.t()} | {:error, term()}
  def append_message(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    Sessions.append_message(session_id, attrs)
  end

  @doc """
  Replay a slice of messages for the session, ordered by ULID ascending.
  """
  @spec replay_messages(String.t(), keyword()) :: [ChatMessage.t()]
  def replay_messages(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    Sessions.list_messages(session_id, opts)
  end

  @doc """
  Mark a session as read for a participant.
  """
  @spec mark_read(String.t(), String.t(), keyword()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def mark_read(session_id, participant_id, opts \\ [])
      when is_binary(session_id) and is_binary(participant_id) and is_list(opts) do
    Sessions.mark_read(session_id, participant_id, opts)
  end
end
