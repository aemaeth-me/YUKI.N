# Context management — OpenAI Agents SDK

Source: https://openai.github.io/openai-agents-python/context/

## Two classes of context

1. **Context available locally to your code**: data and dependencies needed when tool functions run, in callbacks like `on_handoff`, in lifecycle hooks, etc.
2. **Context available to LLMs**: data the LLM sees when generating a response.

## Local context

- Represented via `RunContextWrapper` class and the `context` property within it.
- You create any Python object (dataclass or Pydantic), pass it to run methods (`Runner.run(..., context=whatever)`), and all tool calls / lifecycle hooks receive a `RunContextWrapper[T]` whose `wrapper.context` is your object.
- `ToolContext` extends `RunContextWrapper` and adds `tool_name`, `tool_call_id`, `tool_arguments`, `tool_namespace`, `qualified_tool_name`.
- **The context object is not sent to the LLM.** It is purely a local object you can read, write, and call methods on.
- Avoid putting secrets in `RunContextWrapper.context` if you intend to persist/serialize state.

## Agent/LLM context

When an LLM is called, the only data it can see is from the conversation history. Ways to make data available to the LLM:

1. Add to Agent `instructions` (system prompt / developer message). Static strings or dynamic functions that receive context and output a string. Good for always-useful info (user's name, current date).
2. Add to the `input` when calling `Runner.run` functions (lower in the chain of command).
3. Expose via function tools — on-demand context; LLM decides when it needs data and calls the tool.
4. Use retrieval or web search — special tools that fetch relevant data from files/databases (retrieval) or the web (web search). Useful for "grounding".
