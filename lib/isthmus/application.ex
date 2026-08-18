defmodule Isthmus.Application do
  @moduledoc false

  use Application

  # Mix is not in the release. Capture env at compile time so Docker/prod boot
  # can skip test-only paths without calling Mix.env/0.
  @env Mix.env()

  @impl true
  def start(_type, _args) do
    children = [
      IsthmusWeb.Telemetry,
      Isthmus.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:isthmus, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:isthmus, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Isthmus.PubSub},
      Isthmus.Auth.Store,
      Isthmus.Backup,
      Isthmus.Networks.Supervisor,
      IsthmusWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Isthmus.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Bootstrap admin allowlist from ISTHMUS_ADMIN_NPUBS after Repo is up.
    Task.start(fn ->
      Process.sleep(100)

      try do
        Isthmus.Accounts.bootstrap_from_env!()
      rescue
        _ -> :ok
      end

      if @env != :test do
        try do
          Isthmus.Networks.Agent.Settings.hydrate_from_policy()
          Isthmus.Networks.Agent.Bridge.reconnect()
        rescue
          _ -> :ok
        end
      end
    end)

    result
  end

  @impl true
  def config_change(changed, _new, removed) do
    IsthmusWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    System.get_env("RELEASE_NAME") == nil
  end
end
