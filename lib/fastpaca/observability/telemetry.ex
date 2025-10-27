defmodule Fastpaca.Observability.Telemetry do
  @moduledoc """
  Centralised telemetry helpers so event names and metadata are consistent.

  Exposes small, purpose-built emitters that wrap `:telemetry.execute/3`.
  """

  @type token_source :: :client | :server

  @doc """
  Emit an event when a message is appended, including token counting source.

  Measurements:
    - `:token_count` – integer token count for the message

  Metadata:
    - `:context_id` – context identifier
    - `:source` – `:client` or `:server` depending on who supplied the count
    - `:role` – message role (user/assistant/system)
  """
  @spec message_appended(token_source(), non_neg_integer(), String.t(), String.t()) :: :ok
  def message_appended(source, token_count, context_id, role)
      when source in [:client, :server] and is_integer(token_count) and token_count >= 0 and
             is_binary(context_id) and is_binary(role) do
    :telemetry.execute(
      [:fastpaca, :messages, :append],
      %{token_count: token_count},
      %{context_id: context_id, source: source, role: role}
    )

    :ok
  end

  @doc """
  Emit an event describing the result of a runtime drain.

  Measurements:
    - `:elapsed_ms` – total time spent draining

  Metadata:
    - `:status` – `:ok`, `:partial`, or `:eviction_timeout`
    - `:total_groups` – total number of local groups inspected
    - `:snapshot_ok` – snapshots completed successfully
    - `:snapshot_errors` – snapshots that failed or timed out
    - `:eviction` – `:ok` or `:timeout` while waiting for membership removal
  """
  @spec drain_result(
          atom(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          atom(),
          non_neg_integer()
        ) ::
          :ok
  def drain_result(status, total_groups, snapshot_ok, snapshot_errors, eviction, elapsed_ms)
      when is_atom(status) and is_atom(eviction) and is_integer(total_groups) and
             total_groups >= 0 and
             is_integer(snapshot_ok) and snapshot_ok >= 0 and is_integer(snapshot_errors) and
             snapshot_errors >= 0 and is_integer(elapsed_ms) and elapsed_ms >= 0 do
    :telemetry.execute(
      [:fastpaca, :runtime, :drain],
      %{elapsed_ms: elapsed_ms},
      %{
        status: status,
        total_groups: total_groups,
        snapshot_ok: snapshot_ok,
        snapshot_errors: snapshot_errors,
        eviction: eviction
      }
    )

    :ok
  end
end
