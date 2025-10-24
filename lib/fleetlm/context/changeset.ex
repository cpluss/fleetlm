defmodule Fleetlm.Context.Changeset do
  @moduledoc """
  Changeset helpers for validating context strategy selections.
  """

  import Ecto.Changeset

  alias Fleetlm.Context.Registry

  @doc """
  Ensure the strategy exists and its config passes validation.
  """
  @spec validate_strategy(Ecto.Changeset.t(), atom(), atom()) :: Ecto.Changeset.t()
  def validate_strategy(changeset, strategy_field, config_field) do
    strategy = get_field(changeset, strategy_field)
    config = get_field(changeset, config_field, %{})

    cond do
      is_nil(strategy) ->
        changeset

      not is_binary(strategy) ->
        add_error(changeset, strategy_field, "is invalid")

      not is_map(config) ->
        add_error(changeset, config_field, "must be a map")

      true ->
        with {:ok, module} <- Registry.fetch(strategy),
             :ok <- module.validate_config(config) do
          changeset
        else
          {:error, :unknown_strategy} ->
            add_error(changeset, strategy_field, "is not registered")

          {:error, reason} ->
            add_error(changeset, config_field, format_reason(reason))
        end
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
