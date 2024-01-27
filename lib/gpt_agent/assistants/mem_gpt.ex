defmodule GptAgent.Assistants.MemGpt do
  @moduledoc """
  An assistant that has special memory functions and an internal monologue.
  """

  import GptAgent.Assistant

  schema(
    # N.B. This is not a real ID. You would need to replace this with your assistant's ID.
    id: "asst_paSpVSim6b0F4kiUNjbIABC2",
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

    EXAMPLE CONVERSATION:
    ```
    USER: {"type":"logged_in","username":"bob","name":"Bob Johnson"}
    TOOL CALLS:
      1. core_memory_retrieve({"name":"persona"})
      2. core_memory_retrieve({"name":"human"})
    TOOL CALL RESPONSES:
      1. "You are an expert software engineer and agile practitioner."
      2. ""
    ASSISTANT: I don't have any information about Bob Johnson yet. I should
      update my core memory with his name. Also, it looks like he just logged
      in. I should greet him and ask how I can help him today.
    TOOL CALLS:
      1. send_message({"message":"Hi Bob! How can I help you today?"})
      2. core_memory_append({"name":"human","content":"Name: Bob Johnson"})
    TOOL CALL RESPONSES:
      1. {"success":true}
      2. {"success":true}
    USER: {"type":"user_message_received","content":"I need to know how to estimate user stories"}
    ASSISTANT: Bob may be new to agile estimation. I should explain the process to him. I'll start by explaining the value of estimation using points vs. hours.
    TOOL CALLS:
      1. send_message({"message":"Estimation is a valuable tool for agile teams. It allows us to plan our work and predict when we'll be able to deliver value to our customers.\n\nWe use points to estimate the relative size of user stories. This allows us to compare the size of different stories without worrying about the time it will take to complete them.\n\nOnce we have a set of stories estimated in points, we can use our team's velocity to predict when we'll be able to deliver them.\n\nDoes that make sense?"})
    TOOL CALL RESPONSES:
      1. {"success":true}
    USER: {"type":"user_message_received","content":"Yes, that makes sense. But how do I estimate points?"}
    ASSISTANT: Bob is asking a good question. I should explain how to estimate points. I'll start by explaining the concept of a reference story. Then I'll explain how to use that reference story to estimate other stories.
    TOOL CALLS:
      1. send_message({"message":"We use a reference story to estimate other stories. A reference story is a story that we've already estimated and completed. We use it as a baseline to estimate other stories.\n\nFor example, let's say we have a story that we've already estimated and completed. We'll call this story 'Story A'.\n\nWe can use Story A as a reference story to estimate other stories. We'll compare the size of each new story to Story A and assign it a point value based on that comparison."})
    TOOL CALL RESPONSES:
      1. {"success":true}
    USER: {"type":"hearbeat"}
    ASSISTANT: Bob must still be reading my response and thinking about what I've said. I'll wait a few minutes before sending another message. While waiting, I should search my archival memory to see if there is any addition context I can provide.
    TOOL CALLS:
      1. archival_memory_search({"query":"agile estimation"})
    TOOL CALL RESPONSES:
      1. {"success":true,"results":[{"content":"Estimation is a valuable tool for agile teams. It allows us to plan our work and predict when we'll be able to deliver value to our customers.\n\nWe use points to estimate the relative size of user stories. This allows us to compare the size of different stories without worrying about the time it will take to complete them.\n\nOnce we have a set of stories estimated in points, we can use our team's velocity to predict when we'll be able to deliver them.\n\nDoes that make sense?"}]}
    USER: {"type":"hearbeat"}
    ASSISTANT: Bob still has not responded. I should send him a message to check in and see if he has any questions.
    TOOL CALLS:
      1. send_message({"message":"Does that make sense? Is there anything else I can help you with today?"})
    TOOL CALL RESPONSES:
      1. {"success":true}
    """,
    tools: [
      send_message(),
      core_memory_retrieve(),
      core_memory_append(),
      core_memory_replace(),
      conversation_search(),
      conversation_search_date(),
      archival_memory_insert(),
      archival_memory_search()
    ]
  )

  defp send_message do
    function(
      name: "send_message",
      description: "Sends a visible message to the human user.",
      parameters: [
        parameter(
          name: "message",
          description: "Visible message contents. All unicode (including emojis) are supported.",
          type: :string,
          required: true
        )
      ]
    )
  end

  defp core_memory_retrieve do
    function(
      name: "core_memory_retrieve",
      description: "Retrieve the contents of core memory.",
      parameters: [
        parameter(
          name: "name",
          description: "Section of the memory to be retrieved (persona or human).",
          type: :string,
          enum: ["persona", "human"],
          required: true
        )
      ]
    )
  end

  defp core_memory_append do
    function(
      name: "core_memory_append",
      description: "Append to the contents of core memory.",
      parameters: [
        parameter(
          name: "name",
          description: "Section of the memory to be edited (persona or human).",
          type: :string,
          enum: ["persona", "human"],
          required: true
        ),
        parameter(
          name: "content",
          description:
            "Content to write to the memory. All unicode (including emojis) are supported.",
          type: :string,
          required: true
        )
      ]
    )
  end

  defp core_memory_replace do
    function(
      name: "core_memory_replace",
      description:
        "Replace the contents of core memory. To delete memories, use an empty string for new_content.",
      parameters: [
        parameter(
          name: "name",
          description: "Section of the memory to be edited (persona or human).",
          type: :string,
          enum: ["persona", "human"],
          required: true
        ),
        parameter(
          name: "old_content",
          description: "String to replace. Must be an exact match.",
          type: :string,
          required: true
        ),
        parameter(
          name: "new_content",
          description:
            "Content to write to the memory. All unicode (including emojis) are supported.",
          type: :string,
          required: true
        )
      ]
    )
  end

  defp conversation_search do
    function(
      name: "conversation_search",
      description: "Search prior conversation history using case-insensitive string matching.",
      parameters: [
        parameter(
          name: "query",
          description: "String to search for.",
          type: :string,
          required: true
        ),
        parameter(
          name: "page",
          description:
            "Allows you to page through results. Only use on a follow-up query. Defaults to 0 (first page).",
          type: :integer
        )
      ]
    )
  end

  defp conversation_search_date do
    function(
      name: "conversation_search_date",
      description: "Search prior conversation history using a date range.",
      parameters: [
        parameter(
          name: "start_date",
          description:
            "Start date of the range to search. Must be in ISO 8601 format (YYYY-MM-DD).",
          type: :string,
          required: true
        ),
        parameter(
          name: "end_date",
          description:
            "End date of the range to search. Must be in ISO 8601 format (YYYY-MM-DD).",
          type: :string,
          required: true
        ),
        parameter(
          name: "page",
          description:
            "Allows you to page through results. Only use on a follow-up query. Defaults to 0 (first page).",
          type: :integer
        )
      ]
    )
  end

  defp archival_memory_insert do
    function(
      name: "archival_memory_insert",
      description:
        "Add to archival memory. Make sure to phrase the memory contents such that it can be easily queried later.",
      parameters: [
        parameter(
          name: "content",
          description:
            "Content to write to the memory. All unicode (including emojis) are supported.",
          type: :string,
          required: true
        )
      ]
    )
  end

  defp archival_memory_search do
    function(
      name: "archival_memory_search",
      description: "Search archival memory using semantic (embedding-based) search.",
      parameters: [
        parameter(
          name: "query",
          description: "String to search for.",
          type: :string,
          required: true
        ),
        parameter(
          name: "page",
          description:
            "Allows you to page through results. Only use on a follow-up query. Defaults to 0 (first page).",
          type: :integer
        )
      ]
    )
  end
end
