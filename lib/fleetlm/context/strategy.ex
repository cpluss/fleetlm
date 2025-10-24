defmodule Fleetlm.Context.Strategy do
  @moduledoc """
  Behaviour implemented by context strategies.

  Each strategy receives the full message list (or the slice fetched for this
  invocation) alongside the previous snapshot. It must decide whether the
  transcript is ready (`{:ok, snapshot}`) or if we need to run an external
  compaction (`{:compact, snapshot, {:webhook, job}}`). If a webhook is used,
  the strategy gets a chance to merge the response back via
  `apply_compaction/5`.
  """

  alias Fleetlm.Context.Snapshot

  @type config :: map()

  @max_token_budget Application.compile_env(:fleetlm, :max_context_tokens, 1_000_000)

  @callback validate_config(config) :: :ok | {:error, term()}

  @callback append_message(
              Snapshot.t() | nil,
              map(),
              config,
              keyword()
            ) ::
              {:ok, Snapshot.t()}
              | {:compact, Snapshot.t(), {:webhook, map()}}
              | {:error, term()}

  @callback apply_compaction(
              Snapshot.t(),
              map(),
              config,
              keyword()
            ) :: {:ok, Snapshot.t()} | {:error, term()}

  @optional_callbacks apply_compaction: 4, validate_config: 1

  @doc """
  Hard ceiling for context payloads. Enforced across all strategies.
  """
  @spec max_token_budget() :: pos_integer()
  def max_token_budget, do: @max_token_budget

  @doc """
  Clamp a requested token budget to the global ceiling, returning the ceiling
  when the provided value is missing or invalid.
  """
  @spec clamp_token_budget(term()) :: pos_integer()
  def clamp_token_budget(requested) when is_integer(requested) and requested > 0 do
    min(requested, @max_token_budget)
  end

  def clamp_token_budget(_requested), do: @max_token_budget
end
