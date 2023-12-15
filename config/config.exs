import Config

case config_env() do
  :dev ->
    config :mix_test_interactive, clear: true

  _ ->
    nil
end
