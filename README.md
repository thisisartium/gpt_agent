# GptAgent

GptAgent is an Elixir-based service that provides a conversational agent
interface using the OpenAI GPT models. It allows for the integration of
GPT-powered conversations within various platforms and services.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `gpt_agent` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gpt_agent, "~> 2.0"}
  ]
end
```

Documentation can be generated with
[ExDoc](https://github.com/elixir-lang/ex_doc) and published on
[HexDocs](https://hexdocs.pm). Once published, the docs can be found at
<https://hexdocs.pm/gpt_agent>.

## Configuration

To configure the GptAgent, you need to set the following environment variables
in your project's runtime config file (usually `config/runtime.exs`):

```elixir
config :open_ai_client, :base_url, System.get_env("OPENAI_BASE_URL") || "https://api.openai.com"
config :open_ai_client, :openai_api_key, System.get_env("OPENAI_API_KEY") || raise("OPENAI_API_KEY is not set")
config :open_ai_client, :openai_organization_id, System.get_env("OPENAI_ORGANIZATION_ID")
config :gpt_agent, :heartbeat_interval_ms, if(config_env() == :test, do: 1, else: 1000)
```

Make sure you have the `OPENAI_API_KEY` and (optionally) `OPENAI_ORGANIZATION_ID`
system environment variable set to the correct values for your API key and OpenAI
organization.

You can also configure the logger level in the config file:

```elixir
config :gpt_agent, :log_level, :warning
```

This will set the logging level to `:warning`, which is the recommended level
for production. You can change it to `:debug` for more verbose logging during
development.


## Usage

First, ensure the supervisor is running in your applications supervision tree.
For example:

```elixir
children = [
  {GptAgent.Supervisor, []}
]

opts = [strategy: :one_for_one, name: MyApp.Supervisor]
Supervisor.start_link(children, opts)
```

Before you can start an agent, you need to have both a thread_id and an
assistant_id from the OpenAI assistants API.

To create an example assistant, you can run `OpenAiClient.post("/v1/assistants",
json: GptAgent.Assistants.MemGpt.schema())` and note the id returned in the
request body.

```elixir
OpenAiClient.post("/v1/assistants", json: GptAgent.Assistants.MemGpt.schema())
#=> {:ok, %Req.Response{ body: %{ "id" => "asst_1Ut1Wxnw0MQAF5G3qWcoMRIQ", ...}, ...}
```

You can create a new thread with:
```elixir
 {:ok, thread_id} = GptAgent.create_thread()
```

Then you can start the agent with:

```elixir
{:ok, pid} = GptAgent.connect(thread_id: thread_id, assistant_id: assistant_id)`
```

This will start the agent process if one is not already running for the thread.
We use a process registry to ensure that there is only one agent process running
for a given thread_id. It will also use `Phoenix.PubSub` to subscribe the
current process to messages published by the thread's process. Expect to receive
the following messages:

  - `%GptAgent.Events.UserMessageAdded{}`: Triggered when a user message is
    added to the thread.
  - `%GptAgent.Events.RunStarted{}`: Indicates that a run has been started for
    the thread.
  - `%GptAgent.Events.ToolCallRequested{}`: Occurs when a tool call is
    requested.
  - `%GptAgent.Events.ToolCallOutputRecorded{}`: Recorded when the output of a
    tool call is captured.
  - `%GptAgent.Events.RunCompleted{}`: Signifies that a run has been completed.
  - `%GptAgent.Events.AssistantMessageAdded{}`: Triggered when an assistant
    message is added to the thread.

To add a user message to the thread and run it with the default assistant: `:ok
= GptAgent.add_user_message(pid, "Hello, world!")`

You must at the very least monitor for the `ToolCallRequested` events (if your
assistant uses tool calls), so that you can submit the results back to the run.
To submit the results, use `GptAgent.submit_tool_output(pid, tool_call_id,
tool_call_result_as_json)`.

### Timeouts

The GptAgent processes will, by default, stay running for 2 minutes, after
which, if no additional activity has taken place, the process will shutdown
normally. If you would like to set a different timeout value, you can pass the
`timeout_ms` option to `GptAgent.connect/1`:

```elixir
# Shut down the process if it has not received any activity within 200ms
{:ok, pid} = GptAgent.connect(thread_id: thread_id, assistant_id: assistant_id, timeout_ms: 200)
```
