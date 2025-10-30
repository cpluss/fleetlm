defmodule Fastpaca.Archive.Adapter.Postgres do
  @moduledoc """
  Postgres archive adapter using Ecto.

  Inserts messages in batches with ON CONFLICT DO NOTHING for idempotency.
  """

  @behaviour Fastpaca.Archive.Adapter

  use GenServer

  alias Fastpaca.Repo
  alias Fastpaca.Archive.Message

  @impl true
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  # Postgres parameter limit is 65535. With 7 fields per message,
  # we can safely insert ~9000 messages per batch. Use 5000 to be safe.
  @chunk_size 5_000

  @impl true
  def write_messages(rows) when is_list(rows) do
    if rows == [] do
      {:ok, 0}
    else
      total_count =
        rows
        |> Enum.chunk_every(@chunk_size)
        |> Enum.reduce(0, fn chunk, acc ->
          {count, _} = insert_all_with_conflict(chunk)
          acc + count
        end)

      {:ok, total_count}
    end
  end

  defp insert_all_with_conflict(rows) do
    entries =
      Enum.map(rows, fn row ->
        %{
          context_id: row.context_id,
          seq: row.seq,
          role: row.role,
          # Encode to JSON string for jsonb columns
          parts: Jason.encode!(row.parts),
          metadata: Jason.encode!(row.metadata),
          token_count: row.token_count,
          # Convert NaiveDateTime to DateTime for timestamptz
          inserted_at: DateTime.from_naive!(row.inserted_at, "Etc/UTC")
        }
      end)

    # Use raw SQL to insert with jsonb casting
    Repo.insert_all(
      "messages",
      entries,
      placeholders: %{parts: :string, metadata: :string},
      on_conflict: :nothing,
      conflict_target: [:context_id, :seq]
    )
  end
end
