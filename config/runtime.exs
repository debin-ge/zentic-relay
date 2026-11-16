import Config

if config_env() == :prod do
  {:ok, operations} = ZenticRelay.Config.load()

  config :zentic_relay,
    runtime: operations
end
