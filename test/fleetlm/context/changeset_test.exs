defmodule Fleetlm.Context.ChangesetTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset
  alias Fleetlm.Context.Changeset, as: ContextChangeset

  defmodule TestSchema do
    use Ecto.Schema
    import Ecto.Changeset

    embedded_schema do
      field :context_strategy, :string
      field :context_strategy_config, :map
    end

    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:context_strategy, :context_strategy_config])
      |> ContextChangeset.validate_strategy(:context_strategy, :context_strategy_config)
    end
  end

  describe "validate_strategy/3" do
    test "accepts valid strategy with valid config" do
      changeset =
        TestSchema.changeset(%TestSchema{}, %{
          context_strategy: "last_n",
          context_strategy_config: %{"limit" => 10}
        })

      assert changeset.valid?
    end

    test "rejects unknown strategy" do
      changeset =
        TestSchema.changeset(%TestSchema{}, %{
          context_strategy: "unknown_strategy",
          context_strategy_config: %{}
        })

      refute changeset.valid?
      assert "is not registered" in errors_on(changeset).context_strategy
    end

    test "rejects invalid strategy config" do
      changeset =
        TestSchema.changeset(%TestSchema{}, %{
          context_strategy: "last_n",
          context_strategy_config: %{"limit" => -1}
        })

      refute changeset.valid?
      assert ":invalid_limit" in errors_on(changeset).context_strategy_config
    end

    test "accepts nil strategy" do
      changeset =
        TestSchema.changeset(%TestSchema{}, %{
          context_strategy: nil,
          context_strategy_config: %{}
        })

      # When strategy is nil, validation is skipped
      assert changeset.valid?
    end

    test "rejects non-string strategy" do
      changeset =
        TestSchema.changeset(%TestSchema{}, %{
          context_strategy: :atom_strategy,
          context_strategy_config: %{}
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).context_strategy
    end

    test "rejects non-map config" do
      changeset =
        TestSchema.changeset(%TestSchema{}, %{
          context_strategy: "last_n",
          context_strategy_config: "not a map"
        })

      refute changeset.valid?
      assert "must be a map" in errors_on(changeset).context_strategy_config
    end

    test "accepts webhook strategy with valid config" do
      changeset =
        TestSchema.changeset(%TestSchema{}, %{
          context_strategy: "webhook",
          context_strategy_config: %{
            "url" => "http://localhost:3000/context",
            "limit" => 20
          }
        })

      assert changeset.valid?
    end

    test "rejects webhook strategy without url" do
      changeset =
        TestSchema.changeset(%TestSchema{}, %{
          context_strategy: "webhook",
          context_strategy_config: %{"limit" => 20}
        })

      refute changeset.valid?
      assert ":missing_url" in errors_on(changeset).context_strategy_config
    end
  end

  defp errors_on(changeset) do
    traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
