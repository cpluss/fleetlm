defmodule Fastpaca.Repo do
  use Ecto.Repo,
    otp_app: :fastpaca,
    adapter: Ecto.Adapters.Postgres
end
