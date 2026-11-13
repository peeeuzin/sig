import Config

# Sig uses the host application's repo. The test suite provides its own
# (Sig.Test.Repo, in test/support). Its connection parameters and :redis_url
# are injected at runtime by test/test_helper.exs from Testcontainers.
config :sig, repo: Sig.Test.Repo

config :sig, Sig.Test.Repo,
  database: "sig_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning
