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
  getComposer = () => root?.querySelector?.(".write"),
  requestFrame = globalThis.requestAnimationFrame?.bind(globalThis),
  cancelFrame = globalThis.cancelAnimationFrame?.bind(globalThis),
  Observer = globalThis.MutationObserver,
  ResizeObserver = globalThis.ResizeObserver,
  onFollowingChange = () => {},
  bottomThreshold = 40,
  bottomPadding = 32,
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

  const moveToBottom = (element) => {
    const clientHeight = Number.isFinite(element.clientHeight)
      ? element.clientHeight
      : 0;
    const top = Math.max(0, element.scrollHeight - clientHeight);
    if (Math.abs(element.scrollTop - top) <= 1) return;
    if (typeof element.scrollTo === "function") {
      element.scrollTo({ top, behavior: "auto" });
    } else {
      element.scrollTop = top;
    }
  };

  const moveStreamingReasoningToBottom = (transcript) => {
    const reasoning = transcript?.querySelectorAll?.(
      '[data-streaming="true"] pre',
    );
    if (!reasoning) return;
    for (const element of reasoning) moveToBottom(element);
  };

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
      if (action === "jump" || (action === "measure" && atLatest)) {
        moveToBottom(transcript);
        moveStreamingReasoningToBottom(transcript);
      }
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

  const resizeComposerSpace = () => {
    const transcript = getTranscript();
    const composer = getComposer();
    if (!transcript || !composer) return;
    const height =
      composer.getBoundingClientRect?.().height ?? composer.offsetHeight;
    if (Number.isFinite(height) && height > 0) {
      transcript.style.paddingBottom = `${Math.ceil(height + bottomPadding)}px`;
    }
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
      ? new Observer((records) => {
          if (records.some((record) => insideTranscript(record.target))) {
            schedule("measure");
          }
        })
      : null;
  const composer = getComposer();
  const composerObserver =
    ResizeObserver && composer
      ? new ResizeObserver(resizeComposerSpace)
      : null;
  composerObserver?.observe(composer);
  resizeComposerSpace();
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
      composerObserver?.disconnect();
      root?.removeEventListener?.("scroll", onScroll, true);
      root?.removeEventListener?.("wheel", onWheel, true);
      root?.removeEventListener?.("keydown", onKeyDown, true);
      root?.removeEventListener?.("pointerdown", onPointerDown, true);
      root?.removeEventListener?.("touchmove", onTouchMove, true);
    },
  };
};
