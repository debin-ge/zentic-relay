defmodule ZenticRelay.RuntimeSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(config), do: Supervisor.start_link(__MODULE__, config, name: __MODULE__)

  @impl true
  def init(config) do
    children = [
      {ZenticRelay.Capacity, config},
      {ZenticRelay.Listener, ref: ZenticRelay.Listener, config: config}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
