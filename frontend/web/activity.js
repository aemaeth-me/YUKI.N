const FRAME_KINDS = [
  "snapshot",
  "status",
  "run.end",
  "delivery",
  "fschange",
  "draft",
  "draft.resolved",
];

export const startActivityStream = ({ onFrame, onConnection }) => {
  let source = null;
  let failures = 0;
  let degradedNotified = false;

  const stop = () => {
    if (source) {
      source.close();
      source = null;
    }
  };

  const start = () => {
    stop();
    source = new EventSource("/activity/stream");

    source.onopen = () => {
      failures = 0;
      if (degradedNotified) {
        degradedNotified = false;
      }
      onConnection("live");
    };

    source.onerror = () => {
      failures += 1;
      if (failures >= 3 && !degradedNotified) {
        degradedNotified = true;
        onConnection("degraded");
      }
    };

    for (const kind of FRAME_KINDS) {
      source.addEventListener(kind, (event) => {
        try {
          onFrame({ kind, data: JSON.parse(event.data) });
        } catch {
          // malformed frame — ignore, stream stays alive
        }
      });
    }
  };

  start();
  return { stop, restart: start };
};
