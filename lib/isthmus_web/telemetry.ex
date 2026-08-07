defmodule IsthmusWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      {TelemetryMetricsPrometheus.Core, metrics: prometheus_metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # LiveDashboard can render summaries; Prometheus Core cannot.
  def metrics, do: dashboard_metrics() ++ prometheus_metrics()

  def prometheus_metrics do
    [
      counter("phoenix.socket_drain.count"),
      counter("isthmus.nostr.relay.connected.count", tags: [:url]),
      counter("isthmus.nostr.relay.disconnected.count", tags: [:url]),
      counter("isthmus.nostr.relay.event.count", tags: [:url]),
      counter("isthmus.nostr.relay.publish_ok.count", tags: [:url]),
      counter("isthmus.nostr.relay.publish_fail.count", tags: [:url]),
      sum("isthmus.nostr.publish.ok"),
      sum("isthmus.nostr.publish.total"),
      last_value("isthmus.adapters.online"),
      counter("isthmus.backup.count")
    ]
  end

  defp dashboard_metrics do
    [
      summary("phoenix.endpoint.start.system_time", unit: {:native, :millisecond}),
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration", unit: {:native, :millisecond}),
      summary("phoenix.channel_joined.duration", unit: {:native, :millisecond}),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),
      summary("isthmus.repo.query.total_time", unit: {:native, :millisecond}),
      summary("isthmus.repo.query.decode_time", unit: {:native, :millisecond}),
      summary("isthmus.repo.query.query_time", unit: {:native, :millisecond}),
      summary("isthmus.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("isthmus.repo.query.idle_time", unit: {:native, :millisecond}),
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [{__MODULE__, :measure_adapters, []}]
  end

  def measure_adapters do
    online =
      try do
        health = Isthmus.Networks.health_all()

        Enum.count(health, fn {_id, h} ->
          status = h[:status] || h["status"]
          status in [:online, :running, "online", "running"]
        end)
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end

    :telemetry.execute([:isthmus, :adapters], %{online: online}, %{})
  end
end
