defmodule GptAgentTest do
  @moduledoc false

  use GptAgent.TestCase

  doctest GptAgent

  require Eventually

  alias GptAgent.Events.{
    AssistantMessageAdded,
    OrganizationQuotaExceeded,
    RateLimited,
    RateLimitRetriesExhuasted,
    RunCompleted,
    RunFailed,
    RunStarted,
    ToolCallOutputRecorded,
    ToolCallRequested,
    UserMessageAdded
  }

  alias GptAgent.Types.UserMessage

  @retry_delay Application.compile_env(:gpt_agent, :rate_limit_retry_delay)

  setup _context do
    bypass = Bypass.open()
    Application.put_env(:open_ai_client, :base_url, "http://localhost:#{bypass.port}")

    assistant_id = UUID.uuid4()
    thread_id = UUID.uuid4()
    run_id = UUID.uuid4()

    Bypass.stub(
      bypass,
      "GET",
      "/v1/threads/#{thread_id}/runs",
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "object" => "list",
            "data" => [],
            "first_id" => "",
            "last_id" => "",
            "has_more" => false
          })
        )
      end
    )

    Bypass.stub(bypass, "GET", "/v1/threads/#{thread_id}/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "object" => "list",
          "data" => [],
          "first_id" => "",
          "last_id" => "",
          "has_more" => false
        })
      )
    end)

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

    Bypass.stub(bypass, "GET", "/v1/threads/#{thread_id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
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

    on_exit(fn ->
      Registry.lookup(GptAgent.Registry, thread_id)
      |> Enum.each(fn {pid, :gpt_agent} ->
        # getting the state here ensures that the agent has finished processing
        # any messages prior to the shutdown
        GptAgent.shutdown(pid)
      end)
    end)

    {:ok, bypass: bypass, assistant_id: assistant_id, thread_id: thread_id, run_id: run_id}
  end

  describe "create_thread/0" do
    test "creates a thread via the OpenAI API", %{bypass: bypass} do
      thread_id = UUID.uuid4()

      Bypass.expect_once(bypass, "POST", "/v1/threads", fn conn ->
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

      assert_match(GptAgent.create_thread(), {:ok, ^thread_id})
    end
  end

  describe "connect/1" do
    test "starts a GptAgent process for the given thread ID if no such process is running", %{
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      assert {:ok, pid} =
               GptAgent.connect(
                 thread_id: thread_id,
                 last_message_id: nil,
                 assistant_id: assistant_id
               )

      assert Process.alive?(pid)
    end

    test "does not start a new GptAgent process for the given thread ID if one is already running",
         %{thread_id: thread_id, assistant_id: assistant_id} do
      {:ok, pid1} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      {:ok, pid2} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      assert pid1 == pid2
      GptAgent.shutdown(pid1)
    end

    test "can set a custom timeout that will shut down the GptAgent process if it is idle", %{
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} =
        GptAgent.connect(
          thread_id: thread_id,
          last_message_id: nil,
          assistant_id: assistant_id,
          timeout_ms: 10
        )

      assert Process.alive?(pid)
      refute_eventually(Process.alive?(pid), 20)
    end

    test "returns {:error, :invalid_thread_id} if the thread ID is not a valid OpenAI thread ID",
         %{bypass: bypass} do
      thread_id = "invalid_thread_id"

      Bypass.expect_once(bypass, "GET", "/v1/threads/#{thread_id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, "")
      end)

      assert {:error, :invalid_thread_id} =
               GptAgent.connect(
                 thread_id: thread_id,
                 last_message_id: nil,
                 assistant_id: Faker.Lorem.word()
               )
    end

    test "subscribes to updates for the thread", %{
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      :ok = GptAgent.add_user_message(pid, Faker.Lorem.sentence())
      assert_receive {^pid, %UserMessageAdded{}}
    end

    test "does not subscribe to updates if subsribe option is set to false", %{
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} =
        GptAgent.connect(
          thread_id: thread_id,
          last_message_id: nil,
          assistant_id: assistant_id,
          subscribe: false
        )

      :ok = GptAgent.add_user_message(pid, Faker.Lorem.sentence())
      refute_receive {^pid, %UserMessageAdded{}}
    end

    test "updates the assistant id on an agent if the agent is already running",
         %{thread_id: thread_id, assistant_id: assistant_id} do
      {:ok, pid1} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      new_assistant_id = UUID.uuid4()

      {:ok, pid2} =
        GptAgent.connect(
          thread_id: thread_id,
          last_message_id: nil,
          assistant_id: new_assistant_id
        )

      assert pid1 == pid2
      assert %GptAgent{assistant_id: ^new_assistant_id} = :sys.get_state(pid1)
    end

    test "loads existing thread run status when connecting to thread with a run history", %{
      thread_id: thread_id,
      assistant_id: assistant_id,
      bypass: bypass,
      run_id: run_id
    } do
      Bypass.expect_once(
        bypass,
        "GET",
        "/v1/threads/#{thread_id}/runs",
        fn conn ->
          assert conn.params["order"] == "desc"
          assert conn.params["limit"] == "1"

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              object: "list",
              data: [
                %{
                  "id" => run_id,
                  "object" => "thread.run",
                  "created_at" => 1_699_075_072,
                  "assistant_id" => assistant_id,
                  "thread_id" => thread_id,
                  "status" => "in_progress",
                  "started_at" => 1_699_075_072,
                  "expires_at" => nil,
                  "cancelled_at" => nil,
                  "failed_at" => nil,
                  "completed_at" => nil,
                  "last_error" => nil,
                  "model" => "gpt-3.5-turbo",
                  "instructions" => nil,
                  "tools" => [],
                  "file_ids" => [],
                  "metadata" => %{},
                  "usage" => %{}
                }
              ]
            })
          )
        end
      )

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
            "status" => "in_progress",
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

      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      assert GptAgent.run_in_progress?(pid)

      GptAgent.shutdown(pid)

      Bypass.expect_once(
        bypass,
        "GET",
        "/v1/threads/#{thread_id}/runs",
        fn conn ->
          assert conn.params["order"] == "desc"
          assert conn.params["limit"] == "1"

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              object: "list",
              data: [
                %{
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
                  "model" => "gpt-3.5-turbo",
                  "instructions" => nil,
                  "tools" => [],
                  "file_ids" => [],
                  "metadata" => %{},
                  "usage" => %{}
                }
              ]
            })
          )
        end
      )

      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      refute GptAgent.run_in_progress?(pid)
    end

    test "sets the last_message_id based on the passed value", %{
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} =
        GptAgent.connect(
          thread_id: thread_id,
          last_message_id: "msg_abc123",
          assistant_id: assistant_id
        )

      assert %GptAgent{last_message_id: "msg_abc123"} = :sys.get_state(pid)
    end

    test "updates the last_message_id based on the passed value", %{
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, _pid} =
        GptAgent.connect(
          thread_id: thread_id,
          last_message_id: "msg_abc123",
          assistant_id: assistant_id
        )

      {:ok, pid} =
        GptAgent.connect(
          thread_id: thread_id,
          last_message_id: "msg_abc456",
          assistant_id: assistant_id
        )

      assert %GptAgent{last_message_id: "msg_abc456"} = :sys.get_state(pid)
    end
  end

  describe "shutdown/1" do
    test "shuts down the GptAgent process with the given pid", %{
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      assert Process.alive?(pid)

      assert :ok = GptAgent.shutdown(pid)
      refute Process.alive?(pid)
      assert_eventually(Registry.lookup(GptAgent.Registry, thread_id) == [])
    end

    @tag capture_log: true
    test "returns error if the process was not alive to begin with", %{
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      :ok = GptAgent.shutdown(pid)

      assert {:error, {:process_not_alive, ^pid}} = GptAgent.shutdown(pid)
    end
  end

  describe "add_user_message/2" do
    @tag capture_log: true
    test "returns error if the agent process is not alive", %{
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      :ok = GptAgent.shutdown(pid)

      assert {:error, {:process_not_alive, ^pid}} =
               GptAgent.add_user_message(pid, Faker.Lorem.sentence())
    end

    test "adds the user message to the agent's thread via the OpenAI API", %{
      bypass: bypass,
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

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

      assert_receive {^pid,
                      %UserMessageAdded{
                        id: ^user_message_id,
                        thread_id: ^thread_id,
                        content: %UserMessage{content: content}
                      }},
                     5_000

      assert content == message_content
    end

    test "creates a run against the thread and the assistant via the OpenAI API", %{
      bypass: bypass,
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

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

      assert_receive {^pid,
                      %RunStarted{
                        id: run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id
                      }},
                     5_000

      assert is_binary(run_id)
    end

    test "when the run is completed, sends the RunCompleted event to the callback handler", %{
      bypass: bypass,
      assistant_id: assistant_id,
      thread_id: thread_id,
      run_id: run_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

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
            "metadata" => %{},
            "usage" => %{
              "prompt_tokens" => 1,
              "completion_tokens" => 2,
              "total_tokens" => 3
            }
          })
        )
      end)

      :ok = GptAgent.add_user_message(pid, "Hello")

      assert_receive {^pid,
                      %RunCompleted{
                        id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id,
                        prompt_tokens: 1,
                        completion_tokens: 2,
                        total_tokens: 3
                      }},
                     5_000
    end

    test "when the run is completed, publishes any messages added to the thread by the assistant",
         %{
           bypass: bypass,
           assistant_id: assistant_id,
           thread_id: thread_id,
           run_id: run_id
         } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      message_id = UUID.uuid4()

      message_content =
        "Artificial Intelligence, or AI, is the simulation of human intelligence processes by machines, especially computer systems."

      Bypass.expect_once(bypass, "GET", "/v1/threads/#{thread_id}/messages", fn conn ->
        assert conn.params["order"] == "asc"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "object" => "list",
            "data" => [
              %{
                "id" => "msg_abc456",
                "object" => "thread.message",
                "created_at" => 1_699_016_383,
                "thread_id" => thread_id,
                "role" => "user",
                "content" => [
                  %{
                    "type" => "text",
                    "text" => %{
                      "value" => "Hello, what is AI?",
                      "annotations" => []
                    }
                  }
                ],
                "file_ids" => [
                  "file-abc123"
                ],
                "assistant_id" => nil,
                "run_id" => nil,
                "metadata" => %{}
              },
              %{
                "id" => "msg_abc457",
                "object" => "thread.message",
                "created_at" => 1_699_016_383,
                "thread_id" => thread_id,
                "role" => "user",
                "content" => [],
                "file_ids" => [
                  "file-abc123"
                ],
                "assistant_id" => nil,
                "run_id" => nil,
                "metadata" => %{}
              },
              %{
                "id" => message_id,
                "object" => "thread.message",
                "created_at" => 1_699_016_384,
                "thread_id" => thread_id,
                "role" => "assistant",
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
                "assistant_id" => assistant_id,
                "run_id" => run_id,
                "metadata" => %{}
              }
            ],
            "last_id" => message_id,
            "first_id" => "msg_abc456",
            "has_more" => false
          })
        )
      end)

      :ok = GptAgent.add_user_message(pid, "Hello")

      assert_receive {^pid,
                      %AssistantMessageAdded{
                        run_id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id,
                        message_id: ^message_id,
                        content: ^message_content
                      }},
                     5_000
    end

    test "only publishes messages added by the assistant that were added after the last seen message",
         %{
           bypass: bypass,
           assistant_id: assistant_id,
           thread_id: thread_id,
           run_id: run_id
         } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      message_id_1 = UUID.uuid4()
      message_content_1 = Faker.Lorem.paragraph()

      message_id_2 = UUID.uuid4()
      message_content_2 = Faker.Lorem.paragraph()

      Bypass.expect_once(bypass, "GET", "/v1/threads/#{thread_id}/messages", fn conn ->
        assert conn.params["order"] == "asc"
        refute conn.params["after"]
        refute conn.params["before"]
        refute conn.params["limit"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "object" => "list",
            "data" => [
              %{
                "id" => "msg_abc456",
                "object" => "thread.message",
                "created_at" => 1_699_016_383,
                "thread_id" => thread_id,
                "role" => "user",
                "content" => [
                  %{
                    "type" => "text",
                    "text" => %{
                      "value" => "Hello, what is AI?",
                      "annotations" => []
                    }
                  }
                ],
                "file_ids" => [
                  "file-abc123"
                ],
                "assistant_id" => nil,
                "run_id" => nil,
                "metadata" => %{}
              },
              %{
                "id" => message_id_1,
                "object" => "thread.message",
                "created_at" => 1_699_016_384,
                "thread_id" => thread_id,
                "role" => "assistant",
                "content" => [
                  %{
                    "type" => "text",
                    "text" => %{
                      "value" => message_content_1,
                      "annotations" => []
                    }
                  }
                ],
                "file_ids" => [],
                "assistant_id" => assistant_id,
                "run_id" => run_id,
                "metadata" => %{}
              }
            ],
            "first_id" => "msg_abc456",
            "last_id" => message_id_1,
            "has_more" => false
          })
        )
      end)

      :ok = GptAgent.add_user_message(pid, "Hello")

      assert_receive {^pid,
                      %AssistantMessageAdded{
                        run_id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id,
                        message_id: ^message_id_1,
                        content: ^message_content_1
                      }},
                     5_000

      Bypass.expect_once(
        bypass,
        "GET",
        "/v1/threads/#{thread_id}/messages",
        fn conn ->
          assert conn.params["order"] == "asc"
          assert conn.params["after"] == message_id_1
          refute conn.params["before"]
          refute conn.params["limit"]

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "object" => "list",
              "data" => [
                %{
                  "id" => message_id_2,
                  "object" => "thread.message",
                  "created_at" => 1_699_016_385,
                  "thread_id" => thread_id,
                  "role" => "assistant",
                  "content" => [
                    %{
                      "type" => "text",
                      "text" => %{
                        "value" => message_content_2,
                        "annotations" => []
                      }
                    }
                  ],
                  "file_ids" => [],
                  "assistant_id" => assistant_id,
                  "run_id" => run_id,
                  "metadata" => %{}
                }
              ],
              "first_id" => message_id_2,
              "last_id" => message_id_2,
              "has_more" => false
            })
          )
        end
      )

      :ok = GptAgent.add_user_message(pid, "Hello 2")

      assert_receive {^pid,
                      %AssistantMessageAdded{
                        run_id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id,
                        message_id: ^message_id_2,
                        content: ^message_content_2
                      }},
                     5_000

      refute_receive {^pid,
                      %AssistantMessageAdded{
                        run_id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id,
                        message_id: ^message_id_1,
                        content: ^message_content_1
                      }},
                     500
    end

    test "when the run makes tool calls, sends the ToolCallRequested event to the callback handler for each tool that is called",
         %{
           bypass: bypass,
           assistant_id: assistant_id,
           thread_id: thread_id,
           run_id: run_id
         } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      tool_1_id = UUID.uuid4()
      tool_2_id = UUID.uuid4()

      Bypass.expect(bypass, "GET", "/v1/threads/#{thread_id}/runs/#{run_id}", fn conn ->
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
            "status" => "requires_action",
            "required_action" => %{
              "type" => "submit_tool_outputs",
              "submit_tool_outputs" => %{
                "tool_calls" => [
                  %{
                    "id" => tool_1_id,
                    "type" => "function",
                    "function" => %{"name" => "tool_1", "arguments" => ~s({"foo":"bar","baz":1})}
                  },
                  %{
                    "id" => tool_2_id,
                    "type" => "function",
                    "function" => %{
                      "name" => "tool_2",
                      "arguments" => ~s({"ham":"spam","wham":2})
                    }
                  }
                ]
              }
            },
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

      assert_receive {^pid,
                      %ToolCallRequested{
                        id: ^tool_1_id,
                        thread_id: ^thread_id,
                        run_id: ^run_id,
                        name: "tool_1",
                        arguments: %{"foo" => "bar", "baz" => 1}
                      }},
                     5_000

      assert_receive {^pid,
                      %ToolCallRequested{
                        id: ^tool_2_id,
                        thread_id: ^thread_id,
                        run_id: ^run_id,
                        name: "tool_2",
                        arguments: %{"ham" => "spam", "wham" => 2}
                      }},
                     5_000
    end

    @tag capture_log: true
    test "when the run makes tool calls with invalid JSON in the arguments, it attempts to recover",
         %{
           bypass: bypass,
           assistant_id: assistant_id,
           thread_id: thread_id,
           run_id: run_id
         } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      tool_1_id = UUID.uuid4()
      tool_2_id = UUID.uuid4()

      Bypass.expect(bypass, "GET", "/v1/threads/#{thread_id}/runs/#{run_id}", fn conn ->
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
            "status" => "requires_action",
            "required_action" => %{
              "type" => "submit_tool_outputs",
              "submit_tool_outputs" => %{
                "tool_calls" => [
                  %{
                    "id" => tool_1_id,
                    "type" => "function",
                    "function" => %{
                      "name" => "tool_1",
                      "arguments" => ~s({"foo":"bar\n\nba"z","baz":1})
                    }
                  },
                  %{
                    "id" => tool_2_id,
                    "type" => "function",
                    "function" => %{
                      "name" => "tool_2",
                      "arguments" => ~s({"ham":"spam","wham":2})
                    }
                  }
                ]
              }
            },
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

      expected_error_output =
        Jason.encode!(%{error: "Failed to decode arguments, invalid JSON in tool call."})

      assert_receive {^pid,
                      %ToolCallOutputRecorded{
                        id: ^tool_1_id,
                        thread_id: ^thread_id,
                        run_id: ^run_id,
                        name: "tool_1",
                        output: ^expected_error_output
                      }}

      assert_receive {^pid,
                      %ToolCallRequested{
                        id: ^tool_2_id,
                        thread_id: ^thread_id,
                        run_id: ^run_id,
                        name: "tool_2",
                        arguments: %{"ham" => "spam", "wham" => 2}
                      }},
                     5_000
    end

    test "allow adding additional messages if the run is not complete", %{
      assistant_id: assistant_id,
      thread_id: thread_id,
      run_id: run_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      :ok = GptAgent.add_user_message(pid, Faker.Lorem.sentence())
      assert_receive {^pid, %UserMessageAdded{}}, 5_000

      :ok = GptAgent.add_user_message(pid, Faker.Lorem.sentence())
      assert_receive {^pid, %UserMessageAdded{}}, 5_000

      assert_receive {^pid,
                      %RunCompleted{
                        id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id
                      }},
                     5_000

      assert :ok = GptAgent.add_user_message(pid, Faker.Lorem.sentence())
      assert_receive {^pid, %UserMessageAdded{}}, 5_000
    end

    @tag capture_log: true
    test "when the run fails due to rate limiting, attempt to perform the run again after a delay, up to two more times",
         %{
           bypass: bypass,
           assistant_id: assistant_id,
           thread_id: thread_id,
           run_id: run_id
         } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "GET", "/v1/threads/#{thread_id}/runs/#{run_id}", fn conn ->
        failed_body = %{
          "id" => run_id,
          "object" => "thread.run",
          "created_at" => 1_699_075_072,
          "assistant_id" => assistant_id,
          "thread_id" => thread_id,
          "status" => "failed",
          "started_at" => 1_699_075_072,
          "expires_at" => nil,
          "cancelled_at" => nil,
          "completed_at" => nil,
          "failed_at" => 1_699_075_073,
          "last_error" => %{
            "code" => "rate_limit_exceeded",
            "message" =>
              "Rate limit reached for whatever model blah blah blah, wouldn't it be swell if they used a different error code instead of making me match against a long-ass error message?"
          },
          "model" => "gpt-4-1106-preview",
          "instructions" => nil,
          "tools" => [],
          "file_ids" => [],
          "metadata" => %{}
        }

        response_body =
          case Agent.get_and_update(counter, &{&1, &1 + 1}) do
            0 -> failed_body
            1 -> failed_body
            2 -> failed_body
            3 -> raise "should not have reached a third retry"
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response_body))
      end)

      :ok = GptAgent.add_user_message(pid, "Hello")

      assert_receive {^pid,
                      %RateLimited{
                        run_id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id,
                        retries_remaining: 2
                      }}

      refute_receive {^pid, %RunFailed{}}, @retry_delay - 10

      assert_receive {^pid,
                      %RateLimited{
                        run_id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id,
                        retries_remaining: 1
                      }},
                     20

      refute_receive {^pid, %RunFailed{}}, @retry_delay - 10

      assert_receive {^pid,
                      %RateLimited{
                        run_id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id,
                        retries_remaining: 0
                      }},
                     20

      assert_receive {^pid,
                      %RateLimitRetriesExhuasted{
                        run_id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id
                      }}
    end

    @tag capture_log: true
    test "when the run fails due to quota exceeded, sends the OrganisationQuotaExceeded event to the callback handler",
         %{
           bypass: bypass,
           assistant_id: assistant_id,
           thread_id: thread_id,
           run_id: run_id
         } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

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
            "status" => "failed",
            "started_at" => 1_699_075_072,
            "expires_at" => nil,
            "cancelled_at" => nil,
            "completed_at" => nil,
            "failed_at" => 1_699_075_073,
            "last_error" => %{
              "code" => "rate_limit_exceeded",
              "message" =>
                "You exceeded your current quota, please check your plan and billing details. For more information on this error, read the docs: https://platform.openai.com/docs/guides/error-codes/api-errors."
            },
            "model" => "gpt-4-1106-preview",
            "instructions" => nil,
            "tools" => [],
            "file_ids" => [],
            "metadata" => %{}
          })
        )
      end)

      :ok = GptAgent.add_user_message(pid, "Hello")

      assert_receive {^pid,
                      %OrganizationQuotaExceeded{
                        run_id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id
                      }}

      assert_receive {^pid,
                      %RunFailed{
                        id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id,
                        code: "rate_limit_exceeded",
                        message:
                          "You exceeded your current quota, please check your plan and billing details. For more information on this error, read the docs: https://platform.openai.com/docs/guides/error-codes/api-errors."
                      }}
    end

    @tag capture_log: true
    test "when the run fails for any other reason, sends the RunFailed event to the callback handler",
         %{
           bypass: bypass,
           assistant_id: assistant_id,
           thread_id: thread_id,
           run_id: run_id
         } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      code = Faker.Lorem.word()
      message = Faker.Lorem.sentence()

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
            "status" => "failed",
            "started_at" => 1_699_075_072,
            "expires_at" => nil,
            "cancelled_at" => nil,
            "completed_at" => nil,
            "failed_at" => 1_699_075_073,
            "last_error" => %{
              "code" => code,
              "message" => message
            },
            "model" => "gpt-4-1106-preview",
            "instructions" => nil,
            "tools" => [],
            "file_ids" => [],
            "metadata" => %{}
          })
        )
      end)

      :ok = GptAgent.add_user_message(pid, "Hello")

      assert_receive {^pid,
                      %RunFailed{
                        id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id,
                        code: ^code,
                        message: ^message
                      }}
    end
  end

  describe "submit_tool_output/3" do
    @tag capture_log: true
    test "returns error if the agent process is not alive", %{
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      :ok = GptAgent.shutdown(pid)

      assert {:error, {:process_not_alive, ^pid}} =
               GptAgent.submit_tool_output(pid, UUID.uuid4(), %{})
    end

    test "if there are other tool calls still outstanding, do not submit the tool calls to openai yet",
         %{
           bypass: bypass,
           assistant_id: assistant_id,
           thread_id: thread_id,
           run_id: run_id
         } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      tool_1_id = UUID.uuid4()
      tool_2_id = UUID.uuid4()

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
            "status" => "requires_action",
            "required_action" => %{
              "type" => "submit_tool_outputs",
              "submit_tool_outputs" => %{
                "tool_calls" => [
                  %{
                    "id" => tool_1_id,
                    "type" => "function",
                    "function" => %{"name" => "tool_1", "arguments" => ~s({"foo":"bar","baz":1})}
                  },
                  %{
                    "id" => tool_2_id,
                    "type" => "function",
                    "function" => %{
                      "name" => "tool_2",
                      "arguments" => ~s({"ham":"spam","wham":2})
                    }
                  }
                ]
              }
            },
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

      :ok = GptAgent.add_user_message(pid, Faker.Lorem.sentence())

      assert_receive {^pid,
                      %ToolCallRequested{
                        id: ^tool_1_id,
                        thread_id: ^thread_id,
                        run_id: ^run_id,
                        name: "tool_1",
                        arguments: %{"foo" => "bar", "baz" => 1}
                      }},
                     5_000

      assert_receive {^pid,
                      %ToolCallRequested{
                        id: ^tool_2_id,
                        thread_id: ^thread_id,
                        run_id: ^run_id,
                        name: "tool_2",
                        arguments: %{"ham" => "spam", "wham" => 2}
                      }},
                     5_000

      Bypass.stub(
        bypass,
        "POST",
        "/v1/threads/#{thread_id}/runs/#{run_id}/submit_tool_outputs",
        fn _conn ->
          raise "Should not have called the OpenAI API to submit tool outputs"
        end
      )

      :ok = GptAgent.submit_tool_output(pid, tool_2_id, %{some: "result"})
    end

    test "if all tool calls have been fulfilled, submit the output to openai",
         %{
           bypass: bypass,
           assistant_id: assistant_id,
           thread_id: thread_id,
           run_id: run_id
         } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      tool_1_id = UUID.uuid4()
      tool_2_id = UUID.uuid4()

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
            "status" => "requires_action",
            "required_action" => %{
              "type" => "submit_tool_outputs",
              "submit_tool_outputs" => %{
                "tool_calls" => [
                  %{
                    "id" => tool_1_id,
                    "type" => "function",
                    "function" => %{"name" => "tool_1", "arguments" => ~s({"foo":"bar","baz":1})}
                  },
                  %{
                    "id" => tool_2_id,
                    "type" => "function",
                    "function" => %{
                      "name" => "tool_2",
                      "arguments" => ~s({"ham":"spam","wham":2})
                    }
                  }
                ]
              }
            },
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

      :ok = GptAgent.add_user_message(pid, Faker.Lorem.sentence())

      assert_receive {^pid,
                      %ToolCallRequested{
                        id: ^tool_1_id,
                        thread_id: ^thread_id,
                        run_id: ^run_id,
                        name: "tool_1",
                        arguments: %{"foo" => "bar", "baz" => 1}
                      }},
                     5_000

      assert_receive {^pid,
                      %ToolCallRequested{
                        id: ^tool_2_id,
                        thread_id: ^thread_id,
                        run_id: ^run_id,
                        name: "tool_2",
                        arguments: %{"ham" => "spam", "wham" => 2}
                      }},
                     5_000

      Bypass.expect(
        bypass,
        "POST",
        "/v1/threads/#{thread_id}/runs/#{run_id}/submit_tool_outputs",
        fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          body = Jason.decode!(body)
          assert Map.keys(body) == ["tool_outputs"]
          assert length(body["tool_outputs"]) == 2

          assert %{"tool_call_id" => tool_1_id, "output" => ~s({"another":"answer"})} in body[
                   "tool_outputs"
                 ]

          assert %{"tool_call_id" => tool_2_id, "output" => ~s({"some":"result"})} in body[
                   "tool_outputs"
                 ]

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "id" => "run_abc123",
              "object" => "thread.run",
              "created_at" => 1_699_075_592,
              "assistant_id" => "asst_abc123",
              "thread_id" => "thread_abc123",
              "status" => "queued",
              "started_at" => 1_699_075_592,
              "expires_at" => 1_699_076_192,
              "cancelled_at" => nil,
              "failed_at" => nil,
              "completed_at" => nil,
              "last_error" => nil,
              "model" => "gpt-4",
              "instructions" => "You tell the weather.",
              "tools" => [
                %{
                  "type" => "function",
                  "function" => %{
                    "name" => "get_weather",
                    "description" => "Determine weather in my location",
                    "parameters" => %{
                      "type" => "object",
                      "properties" => %{
                        "location" => %{
                          "type" => "string",
                          "description" => "The city and state e.g. San Francisco, CA"
                        },
                        "unit" => %{
                          "type" => "string",
                          "enum" => ["c", "f"]
                        }
                      },
                      "required" => ["location"]
                    }
                  }
                }
              ],
              "file_ids" => [],
              "metadata" => %{}
            })
          )
        end
      )

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

      :ok = GptAgent.submit_tool_output(pid, tool_2_id, %{some: "result"})

      assert_receive {^pid, %ToolCallOutputRecorded{}}, 5_000

      :ok = GptAgent.submit_tool_output(pid, tool_1_id, %{another: "answer"})

      assert_receive {^pid, %ToolCallOutputRecorded{}}, 5_000

      assert_receive {^pid, %RunCompleted{}}, 5_000
    end
  end

  describe "run_in_progress?/1" do
    @tag capture_log: true
    test "returns error if the agent process is not alive", %{
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      :ok = GptAgent.shutdown(pid)

      assert {:error, {:process_not_alive, ^pid}} = GptAgent.run_in_progress?(pid)
    end

    test "returns true if the agent has a run in progress", %{
      assistant_id: assistant_id,
      thread_id: thread_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      assert :ok = GptAgent.add_user_message(pid, Faker.Lorem.sentence())

      assert_receive {^pid, %RunStarted{}}, 5_000

      assert GptAgent.run_in_progress?(pid)
    end

    test "returns false if the agent does not have a run in progress", %{
      assistant_id: assistant_id,
      thread_id: thread_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      refute GptAgent.run_in_progress?(pid)
    end
  end

  describe "set_assistant_id/2" do
    @tag capture_log: true
    test "returns error if the agent process is not alive", %{
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      :ok = GptAgent.shutdown(pid)

      assert {:error, {:process_not_alive, ^pid}} = GptAgent.set_assistant_id(pid, UUID.uuid4())
    end

    test "updates the assistant_id in the agent's state", %{
      assistant_id: assistant_id,
      thread_id: thread_id
    } do
      {:ok, pid} =
        GptAgent.connect(thread_id: thread_id, last_message_id: nil, assistant_id: assistant_id)

      assert %GptAgent{assistant_id: ^assistant_id} = :sys.get_state(pid)

      new_assistant_id = UUID.uuid4()
      :ok = GptAgent.set_assistant_id(pid, new_assistant_id)

      assert %GptAgent{assistant_id: ^new_assistant_id} = :sys.get_state(pid)
    end
  end
end
