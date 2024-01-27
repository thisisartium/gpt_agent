import Config

case config_env() do
  :dev ->
    config :mix_test_interactive,
      clear: true,
      exclude: [~r{priv/repo/migrations/.*}, ~r{_build/.*}, ~r{.elixir_ls/.*}]

    config :logger, level: :debug

  :test ->
    config :open_ai_client, :openai_api_key, "test"
    config :open_ai_client, :openai_organization_id, "test"

    config :logger, level: :warning

  _ ->
    nil
end
