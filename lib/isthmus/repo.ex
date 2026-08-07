defmodule Isthmus.Repo do
  use Ecto.Repo,
    otp_app: :isthmus,
    adapter: Ecto.Adapters.SQLite3
end
