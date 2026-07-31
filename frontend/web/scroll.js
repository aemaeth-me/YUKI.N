const upwardKeys = new Set(["ArrowUp", "Home", "PageUp"]);

const editable = (target) => {
  const tag = target?.tagName?.toLowerCase();
  return (
    target?.isContentEditable === true ||
    tag === "input" ||
    tag === "textarea" ||
    tag === "select"
  );
};

export const createTranscriptScrollController = ({
  root = globalThis.document,
  observeRoot = root?.body,
  getTranscript = () => root?.getElementById?.("transcript"),
  requestFrame = globalThis.requestAnimationFrame?.bind(globalThis),
  cancelFrame = globalThis.cancelAnimationFrame?.bind(globalThis),
  Observer = globalThis.MutationObserver,
  onFollowingChange = () => {},
  bottomThreshold = 40,
} = {}) => {
  let atLatest = true;
  let frame = null;
  let pending = null;

  const setAtLatest = (next) => {
    if (atLatest === next) return;
    atLatest = next;
    onFollowingChange(next);
  };

  const cancelPending = () => {
    if (frame !== null) cancelFrame?.(frame);
    frame = null;
    pending = null;
  };

  const isAtBottom = (transcript) =>
    transcript.scrollHeight -
      transcript.scrollTop -
      transcript.clientHeight <=
    bottomThreshold;

  const schedule = (kind) => {
    if (!requestFrame) return;
    if (frame !== null) {
      if (kind === "jump") pending = "jump";
      return;
    }
    pending = kind;
    frame = requestFrame(() => {
      frame = null;
      const action = pending;
      pending = null;
      const transcript = getTranscript();
      if (!transcript) return;
      if (action === "jump") transcript.scrollTop = transcript.scrollHeight;
      setAtLatest(isAtBottom(transcript));
    });
  };

  const insideTranscript = (target) => {
    const transcript = getTranscript();
    return (
      transcript !== null &&
      transcript !== undefined &&
      (target === transcript || transcript.contains?.(target) === true)
    );
  };

  const beginBrowsing = () => {
    cancelPending();
    setAtLatest(false);
  };

  const onScroll = (event) => {
    const transcript = getTranscript();
    if (!transcript || event.target !== transcript) return;
    setAtLatest(isAtBottom(transcript));
  };

  const onWheel = (event) => {
    if (event.deltaY < 0 && insideTranscript(event.target)) beginBrowsing();
  };

  const onKeyDown = (event) => {
    if (
      !editable(event.target) &&
      upwardKeys.has(event.key) &&
      insideTranscript(event.target)
    ) {
      beginBrowsing();
    }
  };

  const onPointerDown = (event) => {
    if (insideTranscript(event.target)) cancelPending();
  };

  const onTouchMove = (event) => {
    if (insideTranscript(event.target)) beginBrowsing();
  };

  root?.addEventListener?.("scroll", onScroll, true);
  root?.addEventListener?.("wheel", onWheel, { capture: true, passive: true });
  root?.addEventListener?.("keydown", onKeyDown, true);
  root?.addEventListener?.("pointerdown", onPointerDown, true);
  root?.addEventListener?.("touchmove", onTouchMove, {
    capture: true,
    passive: true,
  });

  const observer =
    Observer && observeRoot
      ? new Observer(() => schedule("measure"))
      : null;
  observer?.observe(observeRoot, {
    childList: true,
    characterData: true,
    subtree: true,
  });

  schedule("jump");

  return {
    follow: () => schedule("jump"),
    isFollowing: () => atLatest,
    notifyContentChanged: () => schedule("measure"),
    destroy: () => {
      cancelPending();
      observer?.disconnect();
      root?.removeEventListener?.("scroll", onScroll, true);
      root?.removeEventListener?.("wheel", onWheel, true);
      root?.removeEventListener?.("keydown", onKeyDown, true);
      root?.removeEventListener?.("pointerdown", onPointerDown, true);
      root?.removeEventListener?.("touchmove", onTouchMove, true);
    },
  };
};
