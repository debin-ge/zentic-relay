defmodule ZenticRelay.Application do
  use Application

  @impl true
  def start(_type, _args) do
    config =
      ZenticRelay.Config.normalize(
        Application.get_env(:zentic_relay, :runtime, ZenticRelay.Config.defaults())
      )

    children = [
      {DNSCluster, query: config.cluster_query || :ignore},
      {ZenticRelay.StaticCluster, nodes: config.cluster_nodes},
      {ZenticRelay.Drain, config.drain},
      ZenticRelay.Metrics,
      {ZenticRelay.RuntimeSupervisor, config}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ZenticRelay.Supervisor)
  end
end
