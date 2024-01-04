defmodule GptAgentTest do
  @moduledoc false

  use GptAgent.TestCase, async: true

  doctest GptAgent

  alias GptAgent.Events.{
    RunCompleted,
    RunStarted,
    ToolCallRequested,
    UserMessageAdded
  }

  alias GptAgent.Values.NonblankString

  setup _context do
    bypass = Bypass.open()

    Application.put_env(:open_ai_client, :base_url, "http://localhost:#{bypass.port}")

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

  describe "connect/2" do
    test "starts a GptAgent process for the given thread ID if no such process is running", %{
      thread_id: thread_id
    } do
      assert {:ok, pid} = GptAgent.connect(self(), thread_id)
      assert Process.alive?(pid)
      assert {:ok, ^thread_id} = GptAgent.thread_id(pid)
    end

    test "does not start a new GptAgent process for the given thread ID if one is already running",
         %{thread_id: thread_id} do
      {:ok, pid1} = GptAgent.connect(self(), thread_id)
      {:ok, pid2} = GptAgent.connect(self(), thread_id)
      assert pid1 == pid2
    end

    test "returns {:error, :invalid_thread_id} if the thread ID is not a valid OpenAI thread ID",
         %{bypass: bypass} do
      thread_id = "invalid_thread_id"

      Bypass.expect_once(bypass, "GET", "/v1/threads/#{thread_id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, "")
      end)

      assert {:error, :invalid_thread_id} = GptAgent.connect(self(), thread_id)
    end
  end

  describe "set_default_assistant/2 and default_assistant_id/1" do
    test "sets the default assistant ID that will be used to process user messages" do
      {:ok, pid} = GptAgent.start_link(callback_handler: self(), thread_id: UUID.uuid4())

      new_assistant_id = UUID.uuid4()
      assert :ok = GptAgent.set_default_assistant(pid, new_assistant_id)

      assert GptAgent.default_assistant(pid) == {:ok, new_assistant_id}
    end
  end

  describe "add_user_message/2" do
    test "adds the user message to the agent's thread via the OpenAI API", %{
      bypass: bypass,
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} = GptAgent.start_link(callback_handler: self(), thread_id: thread_id)
      :ok = GptAgent.set_default_assistant(pid, assistant_id)

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
      thread_id: thread_id,
      assistant_id: assistant_id
    } do
      {:ok, pid} = GptAgent.start_link(callback_handler: self(), thread_id: thread_id)
      :ok = GptAgent.set_default_assistant(pid, assistant_id)

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

    test "when the run is completed, sends the RunCompleted event to the callback handler", %{
      bypass: bypass,
      assistant_id: assistant_id,
      thread_id: thread_id,
      run_id: run_id
    } do
      {:ok, pid} = GptAgent.start_link(callback_handler: self(), thread_id: thread_id)
      :ok = GptAgent.set_default_assistant(pid, assistant_id)

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

    test "when the run makes tool calls, sends the ToolCallRequested event to the callback handler for each tool that is called",
         %{
           bypass: bypass,
           assistant_id: assistant_id,
           thread_id: thread_id,
           run_id: run_id
         } do
      {:ok, pid} = GptAgent.start_link(callback_handler: self(), thread_id: thread_id)
      :ok = GptAgent.set_default_assistant(pid, assistant_id)

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

      assert_receive {GptAgent, ^pid,
                      %ToolCallRequested{
                        id: ^tool_1_id,
                        thread_id: ^thread_id,
                        run_id: ^run_id,
                        name: "tool_1",
                        arguments: %{"foo" => "bar", "baz" => 1}
                      }},
                     5_000

      assert_receive {GptAgent, ^pid,
                      %ToolCallRequested{
                        id: ^tool_2_id,
                        thread_id: ^thread_id,
                        run_id: ^run_id,
                        name: "tool_2",
                        arguments: %{"ham" => "spam", "wham" => 2}
                      }},
                     5_000
    end

    test "returns {:error, :pending_tool_calls} if the agent is waiting on tool calls to be submitted",
         %{
           bypass: bypass,
           assistant_id: assistant_id,
           thread_id: thread_id,
           run_id: run_id
         } do
      {:ok, pid} = GptAgent.start_link(callback_handler: self(), thread_id: thread_id)
      :ok = GptAgent.set_default_assistant(pid, assistant_id)

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
                    "id" => UUID.uuid4(),
                    "type" => "function",
                    "function" => %{"name" => "tool_1", "arguments" => ~s({"foo":"bar","baz":1})}
                  },
                  %{
                    "id" => UUID.uuid4(),
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

      assert {:error, :run_in_progress} =
               GptAgent.add_user_message(pid, Faker.Lorem.sentence())
    end

    test "allow adding additional messages if the run is complete", %{
      assistant_id: assistant_id,
      thread_id: thread_id,
      run_id: run_id
    } do
      {:ok, pid} = GptAgent.start_link(callback_handler: self(), thread_id: thread_id)
      :ok = GptAgent.set_default_assistant(pid, assistant_id)

      :ok = GptAgent.add_user_message(pid, Faker.Lorem.sentence())

      assert_receive {GptAgent, ^pid,
                      %RunCompleted{
                        id: ^run_id,
                        thread_id: ^thread_id,
                        assistant_id: ^assistant_id
                      }},
                     5_000

      assert :ok = GptAgent.add_user_message(pid, Faker.Lorem.sentence())
    end
  end

  describe "submit_tool_output/3" do
    test "returns {:error, :not_running} if there is no run in progress", %{
      assistant_id: assistant_id,
      thread_id: thread_id
    } do
      {:ok, pid} = GptAgent.start_link(callback_handler: self(), thread_id: thread_id)
      :ok = GptAgent.set_default_assistant(pid, assistant_id)

      assert {:error, :run_not_in_progress} =
               GptAgent.submit_tool_output(pid, UUID.uuid4(), %{})
    end

    test "returns {:error, :invalid_tool_call_id} if the tool call ID is not one of the outstanding tool calls",
         %{
           bypass: bypass,
           assistant_id: assistant_id,
           thread_id: thread_id,
           run_id: run_id
         } do
      {:ok, pid} = GptAgent.start_link(callback_handler: self(), thread_id: thread_id)
      :ok = GptAgent.set_default_assistant(pid, assistant_id)

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
                    "id" => UUID.uuid4(),
                    "type" => "function",
                    "function" => %{"name" => "tool_1", "arguments" => ~s({"foo":"bar","baz":1})}
                  },
                  %{
                    "id" => UUID.uuid4(),
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

      assert_receive {GptAgent, ^pid, %ToolCallRequested{}}, 5_000

      assert {:error, :invalid_tool_call_id} =
               GptAgent.submit_tool_output(pid, UUID.uuid4(), %{})
    end

    test "if there are other tool calls still outstanding, do not submit the tool calls to openai yet",
         %{
           bypass: bypass,
           assistant_id: assistant_id,
           thread_id: thread_id,
           run_id: run_id
         } do
      {:ok, pid} = GptAgent.start_link(callback_handler: self(), thread_id: thread_id)
      :ok = GptAgent.set_default_assistant(pid, assistant_id)

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

      assert_receive {GptAgent, ^pid,
                      %ToolCallRequested{
                        id: ^tool_1_id,
                        thread_id: ^thread_id,
                        run_id: ^run_id,
                        name: "tool_1",
                        arguments: %{"foo" => "bar", "baz" => 1}
                      }},
                     5_000

      assert_receive {GptAgent, ^pid,
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
      {:ok, pid} = GptAgent.start_link(callback_handler: self(), thread_id: thread_id)
      :ok = GptAgent.set_default_assistant(pid, assistant_id)

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

      assert_receive {GptAgent, ^pid,
                      %ToolCallRequested{
                        id: ^tool_1_id,
                        thread_id: ^thread_id,
                        run_id: ^run_id,
                        name: "tool_1",
                        arguments: %{"foo" => "bar", "baz" => 1}
                      }},
                     5_000

      assert_receive {GptAgent, ^pid,
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

      :ok = GptAgent.submit_tool_output(pid, tool_2_id, %{some: "result"})
      :ok = GptAgent.submit_tool_output(pid, tool_1_id, %{another: "answer"})
    end
  end
end
