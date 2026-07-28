import assert from "node:assert/strict";
import test from "node:test";
import { createTranscriptScrollController } from "../web/scroll.js";

class Events {
  listeners = new Map();

  addEventListener(type, listener) {
    const listeners = this.listeners.get(type) ?? [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  removeEventListener(type, listener) {
    this.listeners.set(
      type,
      (this.listeners.get(type) ?? []).filter((item) => item !== listener),
    );
  }

  dispatch(type, event = {}) {
    for (const listener of this.listeners.get(type) ?? []) listener(event);
  }
}

const harness = () => {
  const root = new Events();
  const frames = new Map();
  let nextFrame = 0;
  let scrollTop = 0;
  let writes = 0;
  const transcript = {
    clientHeight: 300,
    scrollHeight: 1000,
    contains: (target) => target === transcript,
    get scrollTop() {
      return scrollTop;
    },
    set scrollTop(value) {
      writes += 1;
      scrollTop = Math.max(
        0,
        Math.min(value, transcript.scrollHeight - transcript.clientHeight),
      );
    },
  };
  const following = [];
  const requestFrame = (callback) => {
    nextFrame += 1;
    frames.set(nextFrame, callback);
    return nextFrame;
  };
  const cancelFrame = (id) => frames.delete(id);
  const flush = () => {
    const pending = [...frames.values()];
    frames.clear();
    pending.forEach((callback) => callback());
  };
  const controller = createTranscriptScrollController({
    root,
    observeRoot: null,
    getTranscript: () => transcript,
    requestFrame,
    cancelFrame,
    Observer: null,
    onFollowingChange: (value) => following.push(value),
  });

  return {
    controller,
    root,
    transcript,
    following,
    flush,
    pending: () => frames.size,
    writes: () => writes,
    setScrollTop: (value) => {
      scrollTop = value;
    },
  };
};

test("content growth is coalesced into one animation frame", () => {
  const state = harness();
  assert.equal(state.pending(), 1);

  state.controller.notifyContentChanged();
  state.controller.notifyContentChanged();
  state.controller.notifyContentChanged();

  assert.equal(state.pending(), 1);
  state.flush();
  assert.equal(state.writes(), 1);
  assert.equal(state.transcript.scrollTop, 700);
});

test("upward wheel cancels a pending follow before it can write", () => {
  const state = harness();

  state.root.dispatch("wheel", {
    target: state.transcript,
    deltaY: -1,
  });
  state.transcript.scrollHeight = 1400;
  state.controller.notifyContentChanged();
  state.flush();

  assert.equal(state.controller.isFollowing(), false);
  assert.equal(state.pending(), 0);
  assert.equal(state.writes(), 0);
  assert.deepEqual(state.following, [false]);
});

test("browse mode never writes scrollTop as content grows", () => {
  const state = harness();
  state.root.dispatch("wheel", {
    target: state.transcript,
    deltaY: -20,
  });

  for (const height of [1100, 1300, 1800]) {
    state.transcript.scrollHeight = height;
    state.controller.notifyContentChanged();
    state.flush();
  }

  assert.equal(state.writes(), 0);
  assert.equal(state.transcript.scrollTop, 0);
});

test("scrolling back to the bottom restores follow mode", () => {
  const state = harness();
  state.root.dispatch("wheel", {
    target: state.transcript,
    deltaY: -20,
  });
  state.setScrollTop(700);

  state.root.dispatch("scroll", { target: state.transcript });

  assert.equal(state.controller.isFollowing(), true);
  assert.deepEqual(state.following, [false, true]);
  assert.equal(state.pending(), 1);
  state.flush();
  assert.equal(state.transcript.scrollTop, 700);
});

test("explicit follow restores and reaches the latest content", () => {
  const state = harness();
  state.root.dispatch("wheel", {
    target: state.transcript,
    deltaY: -20,
  });
  state.transcript.scrollHeight = 1600;

  state.controller.follow();
  state.flush();

  assert.equal(state.controller.isFollowing(), true);
  assert.equal(state.transcript.scrollTop, 1300);
  assert.deepEqual(state.following, [false, true]);
});

test("PageUp inside the transcript and touch movement enter browse mode", () => {
  const keyboard = harness();
  keyboard.root.dispatch("keydown", {
    target: keyboard.transcript,
    key: "PageUp",
  });
  keyboard.flush();
  assert.equal(keyboard.controller.isFollowing(), false);
  assert.equal(keyboard.writes(), 0);

  const touch = harness();
  touch.root.dispatch("touchstart", { target: touch.transcript });
  touch.root.dispatch("touchmove", { target: touch.transcript });
  touch.flush();
  assert.equal(touch.controller.isFollowing(), false);
  assert.equal(touch.writes(), 0);
});

test("a tap inside the transcript pauses pending work without leaving follow mode", () => {
  const state = harness();

  state.root.dispatch("touchstart", { target: state.transcript });
  assert.equal(state.controller.isFollowing(), true);
  assert.equal(state.pending(), 0);

  state.root.dispatch("touchend", { target: state.transcript });
  assert.equal(state.pending(), 1);
  state.flush();
  assert.equal(state.controller.isFollowing(), true);
  assert.equal(state.writes(), 1);
});

test("upward keys outside the transcript do not change follow mode", () => {
  const state = harness();

  state.root.dispatch("keydown", { target: {}, key: "PageUp" });
  state.flush();

  assert.equal(state.controller.isFollowing(), true);
  assert.equal(state.writes(), 1);
});
