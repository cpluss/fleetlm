defmodule Fleetlm.Repo.Migrations.AddPerformanceIndexes do
  use Ecto.Migration

  def change do
    # Optimize unread count queries that join chat_messages with chat_sessions
    # These queries filter by session_id, sender_id, and inserted_at
    create index(:chat_messages, [:session_id, :sender_id, :inserted_at],
             name: :chat_messages_session_sender_inserted_at_idx
           )

    # Optimize queries that filter messages by sender_id != participant_id
    # and order by inserted_at for unread counting
    create index(:chat_messages, [:sender_id, :session_id, :inserted_at],
             name: :chat_messages_sender_session_inserted_at_idx
           )

    # Optimize participant session lookup queries
    # Current index only covers individual columns, this covers the OR condition
    create index(:chat_sessions, [:initiator_id, :peer_id, :inserted_at],
             name: :chat_sessions_participants_inserted_at_idx
           )

    # Optimize session queries that filter by agent_id and status together
    create index(:chat_sessions, [:agent_id, :status, :inserted_at],
             name: :chat_sessions_agent_status_inserted_at_idx
           )
  end
end
