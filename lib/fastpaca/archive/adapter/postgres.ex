defmodule Fastpaca.Archive.Adapter.Postgres do
  @moduledoc """
  Minimal Postgres archive adapter using Postgrex.

  Creates the `messages` table if it does not exist and inserts messages in
  batches with ON CONFLICT DO NOTHING for idempotency.
  """

  @behaviour Fastpaca.Archive.Adapter

  use GenServer

  @impl true
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    db_url = Keyword.fetch!(opts, :url)
    pool_size = Keyword.get(opts, :pool_size, 5)
    bootstrap? = Keyword.get(opts, :bootstrap, true)

    url = normalize_url(db_url)

    {:ok, conn} = start_connection(url, pool_size)

    if bootstrap? do
      :ok = ensure_schema(conn)
    end

    {:ok, %{conn: conn}}
  end

  defp normalize_url("ecto://" <> rest), do: "postgres://" <> rest
  defp normalize_url(url), do: url

  defp start_connection(url, _pool_size) do
    opts = [name: __MODULE__.DB, backoff_type: :stop, url: url]
    {:ok, pid} = Postgrex.start_link(opts)
    {:ok, pid}
  end

  defp ensure_schema(conn) do
    # Create table if not exists with PK and a helpful index
    ddl = [
      "CREATE TABLE IF NOT EXISTS messages (",
      "  context_id text NOT NULL,",
      "  seq bigint NOT NULL,",
      "  role text NOT NULL,",
      "  parts jsonb NOT NULL,",
      "  metadata jsonb NOT NULL,",
      "  token_count integer NOT NULL,",
      "  inserted_at timestamptz NOT NULL,",
      "  PRIMARY KEY(context_id, seq)",
      ")",
      ";",
      "CREATE INDEX IF NOT EXISTS messages_context_seq_desc_idx ON messages (context_id, seq DESC);"
    ]

    Enum.each(Enum.join(ddl, "\n") |> String.split(";", trim: true), fn statement ->
      case Postgrex.query(conn, statement, []) do
        {:ok, _} -> :ok
        {:error, %Postgrex.Error{postgres: %{code: :duplicate_table}}} -> :ok
        {:error, _} = err -> throw(err)
      end
    end)

    :ok
  catch
    {:error, _} -> :ok
  end

  @impl true
  def write_messages(rows) when is_list(rows) do
    if rows == [] do
      {:ok, 0}
    else
      conn = Process.whereis(__MODULE__.DB)

      {sql, params} = build_insert(rows)

      case Postgrex.query(conn, sql, params) do
        {:ok, %Postgrex.Result{num_rows: _}} -> {:ok, length(rows)}
        {:error, %Postgrex.Error{} = err} -> {:error, err}
      end
    end
  end

  defp build_insert(rows) do
    # Build VALUES tuples with parameter placeholders
    base =
      "INSERT INTO messages (context_id, seq, role, parts, metadata, token_count, inserted_at) VALUES "

    {values_sql, params} =
      Enum.reduce(Enum.with_index(rows, 0), {[], []}, fn {row, i}, {acc_sql, acc_params} ->
        offset = i * 7

        tuple_sql =
          "($#{offset + 1}, $#{offset + 2}, $#{offset + 3}, $#{offset + 4}::jsonb, $#{offset + 5}::jsonb, $#{offset + 6}, $#{offset + 7})"

        row_params = [
          row.context_id,
          row.seq,
          row.role,
          Jason.encode!(row.parts),
          Jason.encode!(row.metadata),
          row.token_count,
          row.inserted_at
        ]

        {[tuple_sql | acc_sql], row_params ++ acc_params}
      end)

    values = values_sql |> Enum.reverse() |> Enum.join(", ")
    sql = base <> values <> " ON CONFLICT (context_id, seq) DO NOTHING"

    {sql, Enum.reverse(params)}
  end
end
