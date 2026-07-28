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
  let following = true;
  let frame = null;
  let pointerActive = false;

  const setFollowing = (next) => {
    if (following === next) return;
    following = next;
    onFollowingChange(next);
  };

  const cancelPending = () => {
    if (frame === null) return;
    cancelFrame?.(frame);
    frame = null;
  };

  const atBottom = (transcript) =>
    transcript.scrollHeight -
      transcript.scrollTop -
      transcript.clientHeight <=
    bottomThreshold;

  const schedule = () => {
    if (!following || pointerActive || frame !== null || !requestFrame) return;
    frame = requestFrame(() => {
      frame = null;
      if (!following || pointerActive) return;
      const transcript = getTranscript();
      if (transcript) transcript.scrollTop = transcript.scrollHeight;
    });
  };

  const browse = () => {
    cancelPending();
    setFollowing(false);
  };

  const insideTranscript = (target) => {
    const transcript = getTranscript();
    return (
      transcript !== null &&
      transcript !== undefined &&
      (target === transcript || transcript.contains?.(target) === true)
    );
  };

  const onScroll = (event) => {
    const transcript = getTranscript();
    if (!transcript || event.target !== transcript) return;
    if (atBottom(transcript)) {
      setFollowing(true);
      schedule();
    } else {
      browse();
    }
  };

  const onWheel = (event) => {
    if (event.deltaY < 0 && insideTranscript(event.target)) browse();
  };

  const onKeyDown = (event) => {
    if (
      !editable(event.target) &&
      upwardKeys.has(event.key) &&
      insideTranscript(event.target)
    ) {
      browse();
    }
  };

  const onPointerDown = (event) => {
    if (!insideTranscript(event.target)) return;
    pointerActive = true;
    cancelPending();
  };

  const onPointerUp = () => {
    if (!pointerActive) return;
    pointerActive = false;
    schedule();
  };

  const onTouchStart = (event) => {
    onPointerDown(event);
  };

  const onTouchMove = (event) => {
    if (insideTranscript(event.target)) browse();
  };

  root?.addEventListener?.("scroll", onScroll, true);
  root?.addEventListener?.("wheel", onWheel, { capture: true, passive: true });
  root?.addEventListener?.("keydown", onKeyDown, true);
  root?.addEventListener?.("pointerdown", onPointerDown, true);
  root?.addEventListener?.("pointerup", onPointerUp, true);
  root?.addEventListener?.("pointercancel", onPointerUp, true);
  root?.addEventListener?.("touchstart", onTouchStart, {
    capture: true,
    passive: true,
  });
  root?.addEventListener?.("touchmove", onTouchMove, {
    capture: true,
    passive: true,
  });
  root?.addEventListener?.("touchend", onPointerUp, true);
  root?.addEventListener?.("touchcancel", onPointerUp, true);

  const observer =
    Observer && observeRoot
      ? new Observer(() => schedule())
      : null;
  observer?.observe(observeRoot, {
    childList: true,
    characterData: true,
    subtree: true,
  });

  schedule();

  return {
    follow: () => {
      pointerActive = false;
      setFollowing(true);
      schedule();
    },
    isFollowing: () => following,
    notifyContentChanged: schedule,
    destroy: () => {
      cancelPending();
      observer?.disconnect();
      root?.removeEventListener?.("scroll", onScroll, true);
      root?.removeEventListener?.("wheel", onWheel, true);
      root?.removeEventListener?.("keydown", onKeyDown, true);
      root?.removeEventListener?.("pointerdown", onPointerDown, true);
      root?.removeEventListener?.("pointerup", onPointerUp, true);
      root?.removeEventListener?.("pointercancel", onPointerUp, true);
      root?.removeEventListener?.("touchstart", onTouchStart, true);
      root?.removeEventListener?.("touchmove", onTouchMove, true);
      root?.removeEventListener?.("touchend", onPointerUp, true);
      root?.removeEventListener?.("touchcancel", onPointerUp, true);
    },
  };
};
