import Config

case config_env() do
  :dev ->
    config :mix_test_interactive,
      clear: true,
      exclude: [~r{priv/repo/migrations/.*}, ~r{_build/.*}, ~r{.elixir_ls/.*}]

    config :logger, level: :debug

    config :gpt_agent, :rate_limit_retry_delay, 30_000
    config :gpt_agent, :rate_limit_max_retries, 10

    config :gpt_agent, :tool_output_retry_delay, 1_000

  :test ->
    config :open_ai_client, :openai_api_key, "test"
    config :open_ai_client, :openai_organization_id, "test"

    config :logger, level: :warning

    config :gpt_agent, :rate_limit_retry_delay, 100
    config :gpt_agent, :rate_limit_max_retries, 2

    config :gpt_agent, :tool_output_retry_delay, 0

  _ ->
    nil
end
