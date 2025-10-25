defmodule Fastpaca.Repo do
  use Ecto.Repo,
    otp_app: :fastpaca,
    adapter: Ecto.Adapters.Postgres
end

# Temporary alias for compatibility
defmodule Fleetlm.Repo do
  defdelegate all(queryable, opts \\ []), to: Fastpaca.Repo
  defdelegate get(queryable, id, opts \\ []), to: Fastpaca.Repo
  defdelegate get!(queryable, id, opts \\ []), to: Fastpaca.Repo
  defdelegate get_by(queryable, clauses, opts \\ []), to: Fastpaca.Repo
  defdelegate insert(struct_or_changeset, opts \\ []), to: Fastpaca.Repo
  defdelegate insert!(struct_or_changeset, opts \\ []), to: Fastpaca.Repo
  defdelegate insert_all(schema_or_source, entries, opts \\ []), to: Fastpaca.Repo
  defdelegate update(changeset, opts \\ []), to: Fastpaca.Repo
  defdelegate delete(struct_or_changeset, opts \\ []), to: Fastpaca.Repo
  defdelegate delete_all(queryable, opts \\ []), to: Fastpaca.Repo
  defdelegate transaction(fun_or_multi, opts \\ []), to: Fastpaca.Repo
  defdelegate get_dynamic_repo(), to: Fastpaca.Repo
end
