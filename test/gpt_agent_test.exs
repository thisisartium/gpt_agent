defmodule GptAgentTest do
  @moduledoc false

  use ExUnit.Case
  doctest GptAgent

  alias GptAgent.Events.{RunCompleted, RunStarted, ThreadCreated, UserMessageAdded}
  alias GptAgent.Values.NonblankString

  setup _context do
    bypass = Bypass.open()

    Application.put_env(:open_ai_client, OpenAiClient,
      base_url: "http://localhost:#{bypass.port}",
      openai_api_key: "test",
      openai_organization_id: "test"
    )

    assistant_id = UUID.uuid4()
    thread_id = UUID.uuid4()
    run_id = UUID.uuid4()

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

    Bypass.stub(bypass, "POST", "/v1/threads/#{thread_id}/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        201,
        Jason.encode!(%{
          "id" => UUID.uuid4(),
          "object" => "thread.message",
          "created_at" => "1699012949",
          "thread_id" => thread_id,
          "role" => "user",
          "content" => [
            %{
              "type" => "text",
              "text" => %{
                "value" => "Hello",
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

    Bypass.stub(bypass, "POST", "/v1/threads/#{thread_id}/runs", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        201,
        Jason.encode!(%{
          "id" => run_id,
          "object" => "thread.run",
          "created_at" => "1699012949",
          "thread_id" => thread_id,
          "assistant_id" => assistant_id,
          "metadata" => %{}
        })
      )
    end)

    Bypass.stub(bypass, "GET", "/v1/threads/#{thread_id}/runs/#{run_id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => run_id,
          "object" => "thread.run",
          "created_at" => 1_699_075_072,
          "assistant_id" => assistant_id,
          "thread_id" => thread_id,
          "status" => "completed",
          "started_at" => 1_699_075_072,
          "expires_at" => nil,
          "cancelled_at" => nil,
          "failed_at" => nil,
          "completed_at" => 1_699_075_073,
          "last_error" => nil,
          "model" => "gpt-4-1106-preview",
          "instructions" => nil,
          "tools" => [],
          "file_ids" => [],
          "metadata" => %{}
        })
      )
    end)

    {:ok, bypass: bypass, assistant_id: assistant_id, thread_id: thread_id, run_id: run_id}
  end

  describe "start_link/2" do
    test "starts the agent" do
      {:ok, pid} = GptAgent.start_link(self(), UUID.uuid4())
      assert Process.alive?(pid)
    end

    test "creates a thread via the OpenAI API", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/threads", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          201,
          Jason.encode!(%{
            "id" => UUID.uuid4(),
            "object" => "thread",
            "created_at" => "1699012949",
            "metadata" => %{}
          })
        )
      end)

      {:ok, pid} = GptAgent.start_link(self(), UUID.uuid4())

      assert_receive {GptAgent, ^pid, :ready}, 5_000
    end

    test "sends the ThreadCreated event to the callback handler", %{thread_id: thread_id} do
      {:ok, pid} = GptAgent.start_link(self(), UUID.uuid4())

      assert_receive {GptAgent, ^pid, %ThreadCreated{id: ^thread_id}}, 5_000
    end
  end

  describe "start_link/3" do
    test "starts the agent" do
      {:ok, pid} = GptAgent.start_link(self(), UUID.uuid4(), UUID.uuid4())
      assert Process.alive?(pid)
    end

    test "does not create a thread via the OpenAI API", %{bypass: bypass} do
      Bypass.stub(bypass, "POST", "/v1/threads", fn _conn ->
        raise "Should not have called the OpenAI API to create a thread"
      end)

      {:ok, pid} = GptAgent.start_link(self(), UUID.uuid4(), UUID.uuid4())

      assert_receive {GptAgent, ^pid, :ready}, 5_000
    end

    test "does not send the ThreadCreated event to the callback handler" do
      {:ok, pid} = GptAgent.start_link(self(), UUID.uuid4(), UUID.uuid4())

      refute_receive {GptAgent, ^pid, %ThreadCreated{}}, 100
    end
  end

  describe "add_user_message/2" do
    test "adds the user message to the agent's thread via the OpenAI API", %{
      bypass: bypass,
      thread_id: thread_id
    } do
      {:ok, pid} = GptAgent.start_link(self(), UUID.uuid4(), thread_id)

      user_message_id = UUID.uuid4()
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
                        content: %NonblankString{} = content
                      }},
                     5_000

      assert content.value == message_content
    end

    test "creates a run against the thread and the assistant via the OpenAI API", %{
      bypass: bypass,
      thread_id: thread_id
    } do
      assistant_id = UUID.uuid4()
      {:ok, pid} = GptAgent.start_link(self(), assistant_id, thread_id)

      Bypass.expect_once(bypass, "POST", "/v1/threads/#{thread_id}/runs", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"assistant_id" => ^assistant_id} = Jason.decode!(body)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          201,
          Jason.encode!(%{
            "id" => UUID.uuid4(),
            "object" => "thread.run",
            "created_at" => "1699012949",
            "thread_id" => thread_id,
            "assistant_id" => assistant_id,
            "metadata" => %{}
          })
        )
      end)

      :ok = GptAgent.add_user_message(pid, "Hello")

      assert_receive {GptAgent, ^pid,
                      %RunStarted{
                        id: run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id
                      }},
                     5_000

      assert is_binary(run_id)
    end

    test "when the run is finished, sends the RunFinished event to the callback handler", %{
      bypass: bypass,
      assistant_id: assistant_id,
      thread_id: thread_id,
      run_id: run_id
    } do
      {:ok, pid} = GptAgent.start_link(self(), assistant_id, thread_id)

      Bypass.expect_once(bypass, "GET", "/v1/threads/#{thread_id}/runs/#{run_id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => run_id,
            "object" => "thread.run",
            "created_at" => 1_699_075_072,
            "assistant_id" => assistant_id,
            "thread_id" => thread_id,
            "status" => "completed",
            "started_at" => 1_699_075_072,
            "expires_at" => nil,
            "cancelled_at" => nil,
            "failed_at" => nil,
            "completed_at" => 1_699_075_073,
            "last_error" => nil,
            "model" => "gpt-4-1106-preview",
            "instructions" => nil,
            "tools" => [],
            "file_ids" => [],
            "metadata" => %{}
          })
        )
      end)

      :ok = GptAgent.add_user_message(pid, "Hello")

      assert_receive {GptAgent, ^pid,
                      %RunCompleted{
                        id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id
                      }},
                     5_000
    end
  end
end
