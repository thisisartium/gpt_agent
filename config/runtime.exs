import Config

config :open_ai_client, :base_url, System.get_env("OPENAI_BASE_URL") || "https://api.openai.com"

config :open_ai_client,
       :openai_api_key,
       System.get_env("OPENAI_API_KEY") || raise("OPENAI_API_KEY is not set")

config :open_ai_client, :openai_organization_id, System.get_env("OPENAI_ORGANIZATION_ID")

config :gpt_agent, :heartbeat_interval_ms, if(config_env() == :test, do: 1, else: 1000)
