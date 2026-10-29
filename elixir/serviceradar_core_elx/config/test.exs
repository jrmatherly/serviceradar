import Config

config :ash, :validate_domain_config_inclusion?, false

config :logger, level: :warning

config :serviceradar_core, Oban, false
config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Test

# :test lets ServiceRadar.Vault use its dev fallback key instead of requiring CLOAK_KEY.
config :serviceradar_core,
  env: :test,
  repo_enabled: false

config :swoosh, :api_client, false
