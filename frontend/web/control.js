export const agentActionUrl = (
  endpoint,
  action,
  base = globalThis.location?.href ?? "http://127.0.0.1/",
) => {
  const root = new URL(endpoint || "/agent", base);
  root.pathname = root.pathname.replace(/[^/]*$/, "");
  root.search = "";
  root.hash = "";
  return new URL(`agent/${action}`, root);
};

export const contextualizeAgentEvent = (payload, context) => {
  const event = JSON.parse(payload);
  return {
    ...event,
    threadId: event.threadId ?? context.threadId,
    runId: event.runId ?? context.runId,
  };
};

export const postAgentControl = async (
  command,
  action,
  fetchImpl = globalThis.fetch,
  base,
) => {
  const response = await fetchImpl(agentActionUrl(command.endpoint, action, base), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      runId: command.runId,
      ...(command.text === undefined ? {} : { text: command.text }),
    }),
  });

  if (!response.ok) {
    const detail = (await response.text()).slice(0, 4096);
    const error = new Error(
      `HTTP ${response.status}${detail ? ` · ${detail}` : ""}`,
    );
    error.status = response.status;
    throw error;
  }

  return response;
};
