import { postAgentControl } from "./control.js";
import { copyToClipboard } from "./clipboard.js";
import { createTranscriptScrollController } from "./scroll.js";

const node = document.getElementById("app");
const query = new URLSearchParams(window.location.search);
const THREAD_KEY = "yuki.n/threadId";
const INCARNATION_KEY = "yuki.n/incarnationId";

const persistThreadId = (id) => {
  try {
    localStorage.setItem(THREAD_KEY, id);
  } catch {
    // storage unavailable — session stays ephemeral
  }
};

const storedThreadId = () => {
  try {
    return localStorage.getItem(THREAD_KEY);
  } catch {
    return null;
  }
};

const persistIncarnationId = (id) => {
  try {
    localStorage.setItem(INCARNATION_KEY, id);
  } catch {
    // storage unavailable — identity selection stays ephemeral
  }
};

const storedIncarnationId = () => {
  try {
    return localStorage.getItem(INCARNATION_KEY);
  } catch {
    return null;
  }
};

const freshThreadId = () =>
  typeof crypto.randomUUID === "function"
    ? `thread-${crypto.randomUUID()}`
    : `thread-${Date.now().toString(36)}`;

const threadId = storedThreadId() || freshThreadId();
const incarnationId = storedIncarnationId() || "yuki";
persistThreadId(threadId);
persistIncarnationId(incarnationId);

const app = Elm.Main.init({
  node,
  flags: {
    endpoint: query.get("endpoint") || "/agent",
    threadId,
    incarnationId,
    runStamp: Date.now().toString(36),
  },
});

const transcriptScroll = createTranscriptScrollController({
  root: document,
  observeRoot: node,
  onFollowingChange: (following) =>
    app.ports.transcriptFollowChanged.send(following),
});

app.ports.followTranscript.subscribe(() => transcriptScroll.follow());

let active;

const transport = (kind, extra = {}) =>
  app.ports.transportEvent.send({ kind, ...extra });

const decodeEvent = (payload) => {
  try {
    app.ports.agentEvent.send(JSON.parse(payload));
  } catch (error) {
    throw new Error(`invalid AG-UI event: ${error.message}`);
  }
};

const consumeSse = async (body, emit) => {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let data = [];

  const flush = () => {
    if (data.length > 0) {
      emit(data.join("\n"));
      data = [];
    }
  };

  const line = (raw) => {
    const value = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    if (value === "") {
      flush();
    } else if (value.startsWith("data:")) {
      data.push(value.slice(5).replace(/^ /, ""));
    }
  };

  while (true) {
    const { value, done } = await reader.read();
    buffer += decoder.decode(value, { stream: !done });

    let newline = buffer.indexOf("\n");
    while (newline >= 0) {
      line(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
      newline = buffer.indexOf("\n");
    }

    if (done) {
      if (buffer !== "") line(buffer);
      flush();
      return;
    }
  }
};

const run = async (command) => {
  active?.controller.abort();

  const controller = new AbortController();
  const token = Symbol(command.runId);
  active = { controller, token, runId: command.runId, cancelTimer: undefined };
  transport("connecting", { runId: command.runId });

  try {
    const response = await fetch(command.endpoint || "/agent", {
      method: "POST",
      headers: {
        accept: "text/event-stream",
        "content-type": "application/json",
      },
      body: JSON.stringify(command.input),
      signal: controller.signal,
    });

    if (!response.ok) {
      const detail = (await response.text()).slice(0, 4096);
      throw new Error(`HTTP ${response.status}${detail ? ` · ${detail}` : ""}`);
    }
    if (!response.body) throw new Error("streaming response body unavailable");

    transport("open", { runId: command.runId });
    await consumeSse(response.body, decodeEvent);
    if (active?.token === token) transport("closed", { runId: command.runId });
  } catch (error) {
    if (active?.token !== token) return;
    if (error.name === "AbortError") {
      transport("cancelled", { runId: command.runId });
    } else {
      transport("error", { runId: command.runId, message: error.message });
    }
  } finally {
    if (active?.token === token) {
      clearTimeout(active.cancelTimer);
      active = undefined;
    }
  }
};

const cancel = async (command) => {
  const current = active;
  if (!current || current.runId !== command.runId) return;

  const abort = () => {
    if (active?.token === current.token) active.controller.abort();
  };
  current.cancelTimer = setTimeout(abort, 1500);

  try {
    await postAgentControl(command, "cancel");
  } catch {
    clearTimeout(current.cancelTimer);
    abort();
  }
};

app.ports.runAgent.subscribe((command) => void run(command));
app.ports.cancelAgent.subscribe((command) => void cancel(command));
app.ports.persistThreadId.subscribe(persistThreadId);
app.ports.persistIncarnationId.subscribe(persistIncarnationId);
app.ports.copyText.subscribe((text) => void copyToClipboard(text));

app.ports.exportSessionFile.subscribe(({ threadId: id, bundle }) => {
  const safe = String(id || "session").replace(/[^A-Za-z0-9._-]/g, "-");
  const blob = new Blob([`${JSON.stringify(bundle, null, 2)}\n`], {
    type: "application/json",
  });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `${safe}.yuki-session.json`;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 0);
});

app.ports.chooseSessionImport.subscribe(() => {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = "application/json,.json,.yuki-session.json";
  input.addEventListener(
    "change",
    async () => {
      const file = input.files?.[0];
      if (!file) return;
      try {
        app.ports.sessionImportData.send({
          bundle: JSON.parse(await file.text()),
        });
      } catch (error) {
        app.ports.sessionImportData.send({
          bundle: null,
          importError: error.message,
        });
      }
    },
    { once: true },
  );
  input.click();
});

const inspectionBase = (endpoint) => {
  const url = new URL(endpoint || "/agent", window.location.href);
  url.pathname = url.pathname.replace(/[^/]*$/, "");
  url.search = "";
  url.hash = "";
  return url;
};

const inspect = async (request) => {
  const base = inspectionBase(request.endpoint);
  const url = new URL(String(request.path ?? "").replace(/^\/+/, ""), base);
  let status = 0;
  let body = null;
  try {
    const response = await fetch(url, {
      method: request.method || "GET",
      headers:
        request.body === undefined
          ? undefined
          : { "content-type": "application/json" },
      body:
        request.body === undefined ? undefined : JSON.stringify(request.body),
    });
    status = response.status;
    const text = await response.text();
    const type = response.headers.get("content-type") ?? "";
    if (type.includes("application/json")) {
      try {
        body = JSON.parse(text);
      } catch {
        body = text;
      }
    } else {
      body = text;
    }
  } catch (error) {
    body = error.message;
  }
  app.ports.inspectionResult.send({ kind: request.kind, status, body });
};

app.ports.inspect.subscribe((request) => void inspect(request));
