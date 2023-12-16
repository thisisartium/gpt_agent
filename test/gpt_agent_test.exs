defmodule GptAgentTest do
  @moduledoc false

  use ExUnit.Case
  doctest GptAgent

  alias GptAgent.Events.{ThreadCreated, UserMessageAdded}

  setup _context do
    bypass = Bypass.open()

    Application.put_env(:open_ai_client, OpenAiClient,
      base_url: "http://localhost:#{bypass.port}",
      openai_api_key: "test",
      openai_organization_id: "test"
    )

    thread_id = Faker.Lorem.word()

    Bypass.stub(bypass, "POST", "/v1/threads", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        201,
        Jason.encode!(%{
          "id" => thread_id,
          "object" => "thread",
          "created_at" => "1699012949",
          "metadata" => %{}
        })
      )
    end)

    {:ok, bypass: bypass, thread_id: thread_id}
  end

  describe "start_link/1" do
    test "starts the agent" do
      {:ok, pid} = GptAgent.start_link(self())
      assert Process.alive?(pid)
    end

    test "creates a thread via the OpenAI API", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/threads", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          201,
          Jason.encode!(%{
            "id" => Faker.Lorem.word(),
            "object" => "thread",
            "created_at" => "1699012949",
            "metadata" => %{}
          })
        )
      end)

      {:ok, pid} = GptAgent.start_link(self())

      assert_receive {GptAgent, ^pid, :ready}, 5_000
    end

    test "sends the ThreadCreated event to the callback handler", %{thread_id: thread_id} do
      {:ok, pid} = GptAgent.start_link(self())

      assert_receive {GptAgent, ^pid, %ThreadCreated{id: ^thread_id}}, 5_000
    end
  end

  describe "start_link/2" do
    test "starts the agent" do
      {:ok, pid} = GptAgent.start_link(self(), Faker.Lorem.word())
      assert Process.alive?(pid)
    end

    test "does not create a thread via the OpenAI API", %{bypass: bypass} do
      Bypass.stub(bypass, "POST", "/v1/threads", fn _conn ->
        raise "Should not have called the OpenAI API to create a thread"
      end)

      {:ok, pid} = GptAgent.start_link(self(), Faker.Lorem.word())

      assert_receive {GptAgent, ^pid, :ready}, 5_000
    end

    test "does not send the ThreadCreated event to the callback handler" do
      {:ok, pid} = GptAgent.start_link(self(), Faker.Lorem.word())

      refute_receive {GptAgent, ^pid, %ThreadCreated{}}, 100
    end
  end

  describe "add_user_message/2" do
    test "adds the user message to the agent's thread via the OpenAI API", %{
      bypass: bypass,
      thread_id: thread_id
    } do
      {:ok, pid} = GptAgent.start_link(self(), thread_id)

      user_message_id = Faker.Lorem.word()
      message_content = Faker.Lorem.paragraph()

      Bypass.expect_once(bypass, "POST", "/v1/threads/#{thread_id}/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          201,
          Jason.encode!(%{
            "id" => user_message_id,
            "object" => "thread.message",
            "created_at" => "1699012949",
            "thread_id" => thread_id,
            "role" => "user",
            "content" => [
              %{
                "type" => "text",
                "text" => %{
                  "value" => message_content,
                  "annotations" => []
                }
              }
            ],
            "file_ids" => [],
            "assistant_id" => nil,
            "run_id" => nil,
            "metadata" => %{}
          })
        )
      end)

      :ok = GptAgent.add_user_message(pid, message_content)

      assert_receive {GptAgent, ^pid,
                      %UserMessageAdded{
                        id: ^user_message_id,
                        thread_id: ^thread_id,
                        content: ^message_content
                      }},
                     5_000
    end
  end
end
