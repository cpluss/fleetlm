defmodule Fleetlm.Repo do
  use Ecto.Repo,
    otp_app: :fleetlm,
    adapter: Ecto.Adapters.Postgres
end
