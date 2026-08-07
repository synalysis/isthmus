# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Isthmus.Relays

relays = [
  "wss://relay.damus.io",
  "wss://nos.lol",
  "wss://relay.primal.net"
]

for url <- relays do
  case Relays.create_relay(%{url: url, enabled: true, read: true, write: true, priority: 100}) do
    {:ok, _} -> IO.puts("Added relay #{url}")
    {:error, _} -> :ok
  end
end

IO.puts("""
Isthmus seeds complete.

Set admin allowlist before signing in to /admin:
  export ISTHMUS_ADMIN_NPUBS=npub1...
""")
