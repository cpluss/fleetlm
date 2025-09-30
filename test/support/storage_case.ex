defmodule Fleetlm.StorageCase do
  @moduledoc """
  Test case for storage layer tests.

  Sets up:
  - Ecto sandbox with :shared mode for async processes
  - Temporary disk_log directory per test
  - Proper cleanup on exit
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Fleetlm.Repo
      alias FleetLM.Storage.API
      alias FleetLM.Storage.{SlotLogServer, Entry, DiskLog}
      alias FleetLM.Storage.Model.{Session, Message, Cursor}

      import Fleetlm.StorageCase
    end
  end

  setup _tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Fleetlm.Repo)

    # Use :shared mode so spawned processes (SlotLogServer, async tasks) can access the DB
    Ecto.Adapters.SQL.Sandbox.mode(Fleetlm.Repo, {:shared, self()})

    # Create temporary directory for disk logs
    temp_dir =
      System.tmp_dir!()
      |> Path.join("fleetlm_test_#{System.unique_integer([:positive])}")

    File.rm_rf(temp_dir)
    File.mkdir_p!(temp_dir)

    # Override slot_log_dir for this test
    previous_dir = Application.fetch_env(:fleetlm, :slot_log_dir)
    Application.put_env(:fleetlm, :slot_log_dir, temp_dir)

    on_exit(fn ->
      # Restore previous slot_log_dir
      case previous_dir do
        {:ok, dir} -> Application.put_env(:fleetlm, :slot_log_dir, dir)
        :error -> Application.delete_env(:fleetlm, :slot_log_dir)
      end

      # Clean up temp directory
      File.rm_rf(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  @doc """
  Create a test session in the database.
  Returns the session struct.
  """
  def create_test_session(sender_id \\ "alice", recipient_id \\ "bob", metadata \\ %{}) do
    {:ok, session} = FleetLM.Storage.API.create_session(sender_id, recipient_id, metadata)
    session
  end

  @doc """
  Build an Entry struct for testing (does not persist).
  """
  def build_entry(slot, session_id, seq, opts \\ []) do
    message_id = Keyword.get(opts, :message_id, Ulid.generate())
    sender_id = Keyword.get(opts, :sender_id, "sender-#{seq}")
    recipient_id = Keyword.get(opts, :recipient_id, "recipient-#{seq}")
    kind = Keyword.get(opts, :kind, "text")
    content = Keyword.get(opts, :content, %{"text" => "message #{seq}"})
    metadata = Keyword.get(opts, :metadata, %{})
    idempotency_key = Keyword.get(opts, :idempotency_key, "idem-#{seq}")

    message = %FleetLM.Storage.Model.Message{
      id: message_id,
      session_id: session_id,
      sender_id: sender_id,
      recipient_id: recipient_id,
      seq: seq,
      kind: kind,
      content: content,
      metadata: metadata,
      shard_key: slot,
      inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }

    FleetLM.Storage.Entry.from_message(slot, seq, idempotency_key, message)
  end

  @doc """
  Wait for a slot to flush with a timeout.
  """
  def wait_for_flush(slot, timeout \\ 2_000) do
    FleetLM.Storage.SlotLogServer.notify_next_flush(slot)

    receive do
      :flushed -> :ok
    after
      timeout -> raise "Timeout waiting for slot #{slot} to flush"
    end
  end
end
