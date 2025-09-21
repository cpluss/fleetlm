defmodule Fleetlm.Chat do
  import Ecto.Query, warn: false
  alias Fleetlm.Repo
  alias Fleetlm.Chat.Threads.{Thread, Participant, Message}

  # Build DM key for two participants (unordered), "a:b"
  def dm_key(a, b) do
    [x, y] = Enum.sort([a, b])
    "#{x}:#{y}"
  end

  def get_or_create_dm!(a_id, b_id) do
    key = dm_key(a_id, b_id)
    Repo.transaction(fn ->
      case Repo.get_by(Therad, dm_key: key) do
        %Thread{} = thread -> thread
        nil ->
          {:ok, thread} = Thread.changeset(%Thread{}, %{dm_key: key, kind: "dm"}) |> Repo.insert()
          upsert_participant!(thread, a_id, "user")
          upsert_participant!(thread, b_id, "user")
          thread
        end
    end) |> case do
      {:ok, thread} -> thread
      {:error, reason} -> raise(reason)
    end
  end

  defp upsert_participant!(thread_id, participant_id, role) do
    changes = %{
      thread_id: thread_id,
      participant_id: participant_id,
      role: role
    }

    Repo.insert!(
      Participant.changeset(%Participant{}, changes),
      on_conflict: [set, [role: role]],
      conflict_target: [:thread_id, :participant_id]
    )
  end

end
