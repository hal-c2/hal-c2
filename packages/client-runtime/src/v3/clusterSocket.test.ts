import { describe, expect, it, vi } from "vite-plus/test";

import { ClusterSocket, type ShapeFrame } from "./clusterSocket.ts";

class FakeSocket {
  readyState: WebSocket["readyState"] = 0;
  sent: Array<Record<string, unknown>> = [];
  onopen: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: ((event: CloseEvent) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;

  send(data: string) {
    this.sent.push(JSON.parse(data));
  }
  close() {
    this.readyState = 3;
    this.onclose?.({} as CloseEvent);
  }
  serve(frame: Record<string, unknown>) {
    this.readyState = 1;
    this.onmessage?.({ data: JSON.stringify(frame) } as MessageEvent);
  }
}

function setup() {
  const sockets: FakeSocket[] = [];
  const socket = new ClusterSocket({
    url: "ws://mc/ws",
    createSocket: () => {
      const fake = new FakeSocket();
      sockets.push(fake);
      return fake;
    },
    retryDelaysMs: [10],
    pingIntervalMs: 60_000,
  });
  return { socket, sockets };
}

describe("ClusterSocket", () => {
  it("subscribes after hello and routes frames by subscription", () => {
    const { socket, sockets } = setup();
    const frames: ShapeFrame[] = [];
    socket.subscribe({ type: "shell" }, (frame) => frames.push(frame));
    const [first] = sockets;
    first!.serve({ t: "hello", mc: "hal_c2@a", protocol: 3 });
    expect(first!.sent).toEqual([{ t: "sub", id: 1, shape: { type: "shell" }, offset: null }]);

    first!.serve({ t: "shell", id: 1, rows: [] });
    first!.serve({ t: "shell", id: 99, rows: [] });
    expect(frames).toEqual([{ t: "shell", id: 1, rows: [] }]);
    socket.close();
  });

  it("reconnects and resumes each stream from the last offset it saw", async () => {
    vi.useFakeTimers();
    const { socket, sockets } = setup();
    const shape = { type: "stream", mc: "hal_c2@b", stream: "thread-1" } as const;
    socket.subscribe(shape, () => {});
    sockets[0]!.serve({ t: "hello", mc: "hal_c2@a" });
    sockets[0]!.serve({ t: "live", id: 1, offset: 40 });
    sockets[0]!.serve({ t: "events", id: 1, offset: 42, events: [] });

    sockets[0]!.close();
    await vi.advanceTimersByTimeAsync(10);
    sockets[1]!.serve({ t: "hello", mc: "hal_c2@a" });
    expect(sockets[1]!.sent).toEqual([{ t: "sub", id: 1, shape, offset: 42 }]);
    socket.close();
    vi.useRealTimers();
  });

  it("a resync resubscribes from the offset the MC names", () => {
    const { socket, sockets } = setup();
    const frames: ShapeFrame[] = [];
    socket.subscribe({ type: "stream", mc: "hal_c2@b", stream: "thread-1" }, (frame) =>
      frames.push(frame),
    );
    sockets[0]!.serve({ t: "hello", mc: "hal_c2@a" });
    sockets[0]!.serve({ t: "resync", id: 1, offset: 7 });
    expect(sockets[0]!.sent.at(-1)).toMatchObject({ t: "sub", id: 1, offset: 7 });
    expect(frames).toEqual([]);
    socket.close();
  });

  describe("a windowed subscription", () => {
    const shape = { type: "stream", mc: "hal_c2@b", stream: "thread-1" } as const;

    it("asks for its first window, then grows it on request", () => {
      const { socket, sockets } = setup();
      const subscription = socket.subscribeWindow(shape, 200, () => {});
      expect(subscription.more(200)).toBe(false);
      sockets[0]!.serve({ t: "hello", mc: "hal_c2@a" });
      expect(sockets[0]!.sent).toEqual([
        { t: "sub", id: 1, shape, offset: null, window: { items: 200 } },
      ]);

      expect(subscription.more(200)).toBe(true);
      expect(sockets[0]!.sent.at(-1)).toEqual({ t: "more", id: 1, items: 200 });
      subscription.unsubscribe();
      expect(subscription.more(200)).toBe(false);
      socket.close();
    });

    it("resumes by the floor and handle the MC gave, and the offset a page reached", async () => {
      vi.useFakeTimers();
      const { socket, sockets } = setup();
      const frames: ShapeFrame[] = [];
      socket.subscribeWindow(shape, 200, (frame) => frames.push(frame));
      sockets[0]!.serve({ t: "hello", mc: "hal_c2@a" });
      sockets[0]!.serve({
        t: "snapshot",
        id: 1,
        rows: [],
        part: 0,
        done: true,
        offset: 40,
        floor: 12,
        handle: "h1",
      });
      sockets[0]!.serve({ t: "live", id: 1, offset: 40 });
      // A page that is not finished yet moves nothing.
      sockets[0]!.serve({ t: "page", id: 1, rows: [], done: false, offset: 44, floor: 5 });
      sockets[0]!.serve({ t: "events", id: 1, offset: 42, events: [] });
      sockets[0]!.serve({ t: "page", id: 1, rows: [], done: true, offset: 41, floor: 5 });

      sockets[0]!.close();
      await vi.advanceTimersByTimeAsync(10);
      sockets[1]!.serve({ t: "hello", mc: "hal_c2@a" });
      // The events after the page are not asked for again: the offset only ever moves forward.
      expect(sockets[1]!.sent).toEqual([
        { t: "sub", id: 1, shape, offset: 42, window: { floor: 5 }, handle: "h1" },
      ]);
      expect(frames.map((frame) => frame.t)).toEqual([
        "snapshot",
        "live",
        "page",
        "events",
        "page",
      ]);
      socket.close();
      vi.useRealTimers();
    });

    it("asks for a page again when a resync or a reconnect dropped it", async () => {
      vi.useFakeTimers();
      const { socket, sockets } = setup();
      const subscription = socket.subscribeWindow(shape, 200, () => {});
      sockets[0]!.serve({ t: "hello", mc: "hal_c2@a" });
      sockets[0]!.serve({
        t: "snapshot",
        id: 1,
        rows: [],
        part: 0,
        done: true,
        offset: 40,
        floor: 12,
        handle: "h1",
      });
      subscription.more(150);

      sockets[0]!.serve({ t: "resync", id: 1, offset: 41 });
      expect(sockets[0]!.sent.slice(-2)).toMatchObject([
        { t: "sub", id: 1, window: { floor: 12 } },
        { t: "more", id: 1, items: 150 },
      ]);

      sockets[0]!.close();
      await vi.advanceTimersByTimeAsync(10);
      sockets[1]!.serve({ t: "hello", mc: "hal_c2@a" });
      expect(sockets[1]!.sent).toMatchObject([
        { t: "sub", id: 1, window: { floor: 12 } },
        { t: "more", id: 1, items: 150 },
      ]);

      // Once the page is whole it is not asked for again.
      sockets[1]!.serve({ t: "page", id: 1, rows: [], done: true, offset: 41, floor: 5 });
      sockets[1]!.serve({ t: "resync", id: 1, offset: 42 });
      expect(sockets[1]!.sent.at(-1)).toMatchObject({ t: "sub", id: 1, window: { floor: 5 } });
      socket.close();
      vi.useRealTimers();
    });

    it("opens at the floor a replaced session held", () => {
      const { socket, sockets } = setup();
      socket.subscribeWindow(shape, 200, () => {}, 5);
      socket.subscribeWindow(shape, 200, () => {}, null);
      sockets[0]!.serve({ t: "hello", mc: "hal_c2@a" });
      expect(sockets[0]!.sent).toEqual([
        { t: "sub", id: 1, shape, offset: null, window: { floor: 5 } },
        { t: "sub", id: 2, shape, offset: null, window: { floor: null } },
      ]);
      socket.close();
    });
  });
});
