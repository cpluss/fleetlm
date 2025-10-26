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
end
