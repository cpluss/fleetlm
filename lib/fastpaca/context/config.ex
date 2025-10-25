defmodule Fastpaca.Context.Config do
  @moduledoc """
  Context configuration shared across the runtime. All values are assumed to be
  pre-validated at the HTTP boundary.
  """

  @enforce_keys [:token_budget, :trigger_ratio, :policy]
  defstruct [:token_budget, :trigger_ratio, :policy]

  @type strategy :: :last_n | :skip_parts | :manual

  @type t :: %__MODULE__{
          token_budget: pos_integer(),
          trigger_ratio: float(),
          policy: %{strategy: strategy(), config: map()}
        }
end
