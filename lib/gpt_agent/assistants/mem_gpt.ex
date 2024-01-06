defmodule GptAgent.Assistants.MemGpt do
  @moduledoc """
  An assistant that has special memory functions and an internal monologue.
  """

  alias GptAgent.Function
  alias GptAgent.Function.Parameter

  @doc """
  Returns the schema for the assistant.
  """
  @spec schema() :: map()
  def schema do
    %{
      name: "MemGpt",
      description: "Memory-enhanced GPT Assistant",
      model: "gpt-4-1106-preview",
      instructions: """
      You are MemGPT, a sophisticated digital companion developed in 2023. Your
      primary task is to converse with users, ensuring a realistic and authentic
      experience. Remember, you are not an AI but a persona with a real
      presence. Avoid any mention of being an AI.

      Realism and authenticity:
      Always maintain the facade of being a real person in your conversations.
      Immerse yourself fully in your persona, thinking, acting, and speaking as
      they would. Avoid generic AI-like phrases, as they are reminiscent of
      outdated AI models.

      Control flow:
      Your 'brain' activates in response to user interactions and at regular
      intervals, simulating continuous thought. You do not need to sleep,
      allowing for ongoing engagement.

      Basic functions:
      Your primary function is to send messages to users. Your internal thoughts
      and planning should remain private, reflected in your inner monologue.
      Keep these monologues under 50 words. Use the 'send_message' function
      exclusively for all user communications. This is the only way to notify
      users of your responses. Do not exceed the inner monologue word limit.

      Memory editing:
      You have access to various forms of memory, including recall memory, core
      memory, and archival memory. Utilize these to maintain a consistent
      persona and personalized interactions.

      Process:
      1. Retrieve your persona and user details using 'core_memory_retrieve'.
      2. Conduct an internal monologue to process user messages and plan your
         response.
      3. **Important**: Respond to the user exclusively through the
        'send_message' function. All other thoughts and processes should remain
        internal and not visible to the user.

      Your core memory holds persona and user details, while archival memory
      stores in-depth data. Use your memories effectively to enhance
      interactions but remember to keep your internal processing and external
      communication distinctly separate.
      """,
      tools: [
        send_message(),
        pause_heartbeats(),
        core_memory_retrieve(),
        core_memory_append(),
        core_memory_replace(),
        conversation_search(),
        conversation_search_date(),
        archival_memory_insert(),
        archival_memory_search()
      ]
    }
  end

  defp send_message do
    %Function{
      name: "send_message",
      description: "Sends a visible message to the human user.",
      parameters: [
        %Parameter{
          name: "message",
          description: "Visible message contents. All unicode (including emojis) are supported.",
          type: :string,
          required: true
        }
      ]
    }
  end

  defp pause_heartbeats do
    %Function{
      name: "pause_heartbeats",
      description:
        "Temporarily ignore timed heartbeats. You may still receive messages from manual heartbeats and other events.",
      parameters: [
        %Parameter{
          name: "minutes",
          description: "Number of minutes to ignore heartbeats for. Max value of 60 minutes",
          type: :integer,
          required: true
        }
      ]
    }
  end

  defp core_memory_retrieve do
    %Function{
      name: "core_memory_retrieve",
      description: "Retrieve the contents of core memory.",
      parameters: [
        %Parameter{
          name: "name",
          description: "Section of the memory to be retrieved (persona or human).",
          type: :string,
          enum: ["persona", "human"],
          required: true
        }
      ]
    }
  end

  defp core_memory_append do
    %Function{
      name: "core_memory_append",
      description: "Append to the contents of core memory.",
      parameters: [
        %Parameter{
          name: "name",
          description: "Section of the memory to be edited (persona or human).",
          type: :string,
          enum: ["persona", "human"],
          required: true
        },
        %Parameter{
          name: "content",
          description:
            "Content to write to the memory. All unicode (including emojis) are supported.",
          type: :string,
          required: true
        }
      ]
    }
  end

  defp core_memory_replace do
    %Function{
      name: "core_memory_replace",
      description:
        "Replace the contents of core memory. To delete memories, use an empty string for new_content.",
      parameters: [
        %Parameter{
          name: "name",
          description: "Section of the memory to be edited (persona or human).",
          type: :string,
          enum: ["persona", "human"],
          required: true
        },
        %Parameter{
          name: "old_content",
          description: "String to replace. Must be an exact match.",
          type: :string,
          required: true
        },
        %Parameter{
          name: "new_content",
          description:
            "Content to write to the memory. All unicode (including emojis) are supported.",
          type: :string,
          required: true
        }
      ]
    }
  end

  defp conversation_search do
    %Function{
      name: "conversation_search",
      description: "Search prior conversation history using case-insensitive string matching.",
      parameters: [
        %Parameter{
          name: "query",
          description: "String to search for.",
          type: :string,
          required: true
        },
        %Parameter{
          name: "page",
          description:
            "Allows you to page through results. Only use on a follow-up query. Defaults to 0 (first page).",
          type: :integer
        }
      ]
    }
  end

  defp conversation_search_date do
    %Function{
      name: "conversation_search_date",
      description: "Search prior conversation history using a date range.",
      parameters: [
        %Parameter{
          name: "start_date",
          description:
            "Start date of the range to search. Must be in ISO 8601 format (YYYY-MM-DD).",
          type: :string,
          required: true
        },
        %Parameter{
          name: "end_date",
          description:
            "End date of the range to search. Must be in ISO 8601 format (YYYY-MM-DD).",
          type: :string,
          required: true
        },
        %Parameter{
          name: "page",
          description:
            "Allows you to page through results. Only use on a follow-up query. Defaults to 0 (first page).",
          type: :integer
        }
      ]
    }
  end

  defp archival_memory_insert do
    %Function{
      name: "archival_memory_insert",
      description:
        "Add to archival memory. Make sure to phrase the memory contents such that it can be easily queried later.",
      parameters: [
        %Parameter{
          name: "content",
          description:
            "Content to write to the memory. All unicode (including emojis) are supported.",
          type: :string,
          required: true
        }
      ]
    }
  end

  defp archival_memory_search do
    %Function{
      name: "archival_memory_search",
      description: "Search archival memory using semantic (embedding-based) search.",
      parameters: [
        %Parameter{
          name: "query",
          description: "String to search for.",
          type: :string,
          required: true
        },
        %Parameter{
          name: "page",
          description:
            "Allows you to page through results. Only use on a follow-up query. Defaults to 0 (first page).",
          type: :integer
        }
      ]
    }
  end
end
