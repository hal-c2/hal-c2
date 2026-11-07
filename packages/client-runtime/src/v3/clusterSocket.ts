// @effect-diagnostics globalTimers:off - This transport runs without an Effect runtime.
/* oxlint-disable unicorn/prefer-add-event-listener -- The socket owns its handlers. */

/**
 * One WebSocket to a protocol-3 MC, shared by every environment of its cluster.
 *
 * Subscriptions are multiplexed by id. On reconnect every stream subscription is
 * sent again with the last offset it saw, so the MC replays only what was
 * missed; a shell subscribed with `subscribeShell` says which rows it holds
 * (`have`), so the MC sends only the rows changed since. A `resync` from
 * the MC (this client fell too far behind) is handled the same way. A stream the MC
 * refused with `error` because its MC is out of the cluster is asked again, from
 * its offset, once the MC says on the shell that that MC is back (`shell.mc`).
 */

/** The protocol this client speaks; the MC's `HalC2.Web.Protocol.version()` and Qt's `McClient::kProtocol`. */
export const CLUSTER_SOCKET_PROTOCOL = 3;

/**
 * The socket URL naming the protocol this client speaks: an MC refuses an upgrade
 * that names none, or another, with the side to update.
 */
export function withProtocol(socketUrl: string): string {
  const url = new URL(socketUrl);
  url.searchParams.set("protocol", String(CLUSTER_SOCKET_PROTOCOL));
  return url.toString();
}

export type ShellShape = { readonly type: "shell" };
export type StreamShape = {
  readonly type: "stream";
  readonly mc: string;
  readonly stream: string;
};
// `usageLimitsCommand`: the client answers `/usage-limits` itself, so providers with
// limits offer it.
export type ConfigShape = (
  | { readonly type: "config"; readonly mc: string }
  | { readonly type: "config"; readonly environment: string }
) & { readonly usageLimitsCommand?: true };
export type TerminalShape = {
  readonly type: "terminal";
  readonly mc: string;
  readonly input: Readonly<Record<string, unknown>>;
};
export type TerminalsShape = { readonly type: "terminals"; readonly mc: string };
export type VcsShape = { readonly type: "vcs"; readonly mc: string; readonly cwd: string };
export type ProviderAuthShape = {
  readonly type: "providerAuth";
  readonly mc: string;
  readonly instanceId: string;
};
export type WorktreeSetupShape = {
  readonly type: "worktreeSetup";
  readonly mc: string;
  readonly threadId: string;
};
export type ScheduledTasksShape = { readonly type: "scheduledTasks"; readonly mc: string };
/** Pairing links and clients of the MC the socket is connected to. */
export type AuthAccessShape = { readonly type: "authAccess" };
export type ProjectClonesShape = { readonly type: "projectClones"; readonly mc: string };
export type PreviewShape = { readonly type: "preview"; readonly mc: string };
export type ResourceTelemetryShape = { readonly type: "resourceTelemetry"; readonly mc: string };
export type LocalServersShape = { readonly type: "localServers"; readonly mc: string };
/** An MC's simulators, emulators and open device sessions, whole on every change. */
export type DevicesShape = { readonly type: "devices"; readonly mc: string };
/** An MC's Slack connection (`SlackStatus`), at once and on every change. */
export type SlackShape = { readonly type: "slack"; readonly mc: string };
/** Who else is on an open page of a Space: being subscribed is being on the page. */
export type SpacePresenceShape = {
  readonly type: "spacePresence";
  readonly mc: string;
  readonly spaceId: string;
  readonly pageId: string;
};
/** This client as an MC's browser automation host; the MC ends it when it drops the host. */
export type PreviewAutomationShape = {
  readonly type: "previewAutomation";
  readonly mc: string;
  readonly host: Readonly<Record<string, unknown>>;
};
export type PullRequestRefreshesShape = {
  readonly type: "pullRequestRefreshes";
  readonly mc: string;
};
export type GitActionShape = {
  readonly type: "gitAction";
  readonly mc: string;
  readonly input: Readonly<Record<string, unknown>>;
};
/** Moves the MC to another version (`HalC2.Upgrade`), streaming progress, then ends. */
export type ServerUpdateShape = {
  readonly type: "serverUpdate";
  readonly mc: string;
  readonly input: Readonly<Record<string, unknown>>;
};
export type Shape =
  | ShellShape
  | StreamShape
  | ConfigShape
  | TerminalShape
  | TerminalsShape
  | VcsShape
  | ScheduledTasksShape
  | AuthAccessShape
  | ProjectClonesShape
  | PreviewShape
  | ResourceTelemetryShape
  | LocalServersShape
  | DevicesShape
  | SlackShape
  | SpacePresenceShape
  | PreviewAutomationShape
  | PullRequestRefreshesShape
  | GitActionShape
  | ServerUpdateShape
  | ProviderAuthShape
  | WorktreeSetupShape;

/** A failed RPC or subscription; `detail` is the contract error as `{_tag, ...fields}`. */
export class ClusterRpcError extends Error {
  readonly detail: unknown;
  constructor(message: string, detail: unknown) {
    super(message);
    this.detail = detail;
  }
}

/** A server frame addressed to one subscription (`id` already stripped of meaning). */
export type ShapeFrame = Record<string, unknown> & { readonly t: string };

export interface ClusterSocketStatus {
  readonly connected: boolean;
  readonly mc: string | null;
}

interface Subscription {
  readonly shape: Shape;
  readonly onFrame: (frame: ShapeFrame) => void;
  offset: number | null;
  /**
   * A thread stream held as its newest runs: the turn items the first sub asks for,
   * `floor` the first run it holds (null: all of the thread; undefined: not told
   * yet) and `handle` the log its offset came from. A reconnect keeps the window it
   * has, the turns the user paged in included.
   */
  readonly windowItems?: number;
  floor?: number | null;
  handle?: string;
  /** Items of a `more` the MC has not finished answering; asked again after a resubscription. */
  pendingMore?: number;
  /** A terminal whose client acknowledges what it has handled; every sub says so. */
  readonly acks?: true;
  /** The MC refused the stream (its MC left the cluster) and forgot it. */
  refused?: boolean;
  /** The shell's rows as the client holds them, read on every sub: the MC sends only what came after. */
  readonly have?: () => Readonly<Record<string, readonly [string, number]>>;
}

/** Where a windowed thread stream is: what a subscription on another socket resumes from. */
export interface StreamResumePoint {
  readonly offset: number;
  readonly floor: number | null | undefined;
  readonly handle: string | undefined;
}

/** A thread stream that holds its newest turns; `more` adds the ones before. */
export interface WindowedSubscription {
  readonly unsubscribe: () => void;
  /** Asks for about `items` more turn items; false when the socket is not connected. */
  readonly more: (items: number) => boolean;
  /** Where the stream is now; null before it has an offset. */
  readonly resumePoint: () => StreamResumePoint | null;
}

/** A terminal that acknowledges; `ack` says everything up to `sequence` was handled. */
export interface AcknowledgedSubscription {
  readonly unsubscribe: () => void;
  /** Dropped when the socket is not connected: the next sub starts over from a snapshot. */
  readonly ack: (sequence: number) => void;
}

type SocketLike = Pick<WebSocket, "send" | "close" | "readyState"> & {
  onopen: ((event: Event) => void) | null;
  onmessage: ((event: MessageEvent) => void) | null;
  onclose: ((event: CloseEvent) => void) | null;
  onerror: ((event: Event) => void) | null;
};

export interface ClusterSocketOptions {
  /** `ws(s)://host/ws?token=...` of any MC in the cluster. */
  readonly url: string;
  readonly createSocket?: (url: string) => SocketLike;
  readonly onStatus?: (status: ClusterSocketStatus) => void;
  readonly retryDelaysMs?: ReadonlyArray<number>;
  /**
   * Reconnect after a drop (default). Off when the URL carries a single-use ticket:
   * the owner then reconnects with a fresh URL instead.
   */
  readonly reconnect?: boolean;
  readonly pingIntervalMs?: number;
}

const OPEN = 1;

/** How often a socket pings its MC. It waits on no answer: a slow MC is never asked again. */
export const PING_INTERVAL_MS = 25_000;

export class ClusterSocket {
  private socket: SocketLike | null = null;
  private readonly subscriptions = new Map<number, Subscription>();
  private readonly calls = new Map<
    number,
    { readonly resolve: (value: unknown) => void; readonly reject: (error: Error) => void }
  >();
  private nextId = 1;
  private attempt = 0;
  private mc: string | null = null;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private closed = false;
  // Subscriptions go out only after the MC's hello; until then they are queued.
  private ready = false;
  private readonly options: ClusterSocketOptions;

  constructor(options: ClusterSocketOptions) {
    this.options = options;
    this.connect();
  }

  /**
   * Runs an RPC on the MC that serves `environment`. Rejects with a
   * `ClusterRpcError` from the MC, or when the socket is not connected or drops
   * before the reply.
   */
  call(environment: string, method: string, payload: unknown): Promise<unknown> {
    if (!this.ready) return Promise.reject(new Error("not connected"));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.calls.set(id, { resolve, reject });
      this.send({ t: "rpc", id, environment, method, payload });
    });
  }

  /** The MC this socket is connected to, once it said hello. */
  connectedMc(): string | null {
    return this.mc;
  }

  /** Subscribes to a shape; returns the unsubscribe function. */
  subscribe(
    shape: Shape,
    onFrame: (frame: ShapeFrame) => void,
    offset: number | null = null,
  ): () => void {
    return this.add({ shape, onFrame, offset }).unsubscribe;
  }

  /**
   * Subscribes to the cluster shell, saying on every sub (each socket's first, and a
   * resubscription) which rows the client holds, so the MC answers with what it lacks.
   */
  subscribeShell(
    onFrame: (frame: ShapeFrame) => void,
    have: () => Readonly<Record<string, readonly [string, number]>>,
  ): () => void {
    return this.add({ shape: { type: "shell" }, onFrame, offset: null, have }).unsubscribe;
  }

  /**
   * Subscribes to a thread stream as its newest `items` turn items (`page` frames
   * answer `more`). The folded thread can be shorter than the thread; `snapshot`
   * and `page` frames say where it starts. `floor` opens the window a client already
   * held (a replaced session's) at that run instead (null: all of the thread);
   * `resume` carries on from where another socket's subscription was.
   */
  subscribeWindow(
    shape: StreamShape,
    items: number,
    onFrame: (frame: ShapeFrame) => void,
    floor?: number | null,
    resume?: StreamResumePoint,
  ): WindowedSubscription {
    const window = resume?.floor ?? floor;
    return this.add({
      shape,
      onFrame,
      offset: resume?.offset ?? null,
      windowItems: items,
      ...(window === undefined ? {} : { floor: window }),
      ...(resume?.handle === undefined ? {} : { handle: resume.handle }),
    });
  }

  /**
   * Subscribes to a terminal whose output the MC holds back once too much of it waits
   * unacknowledged (`HalC2.Terminal.OutputWindow`); a reconnect starts over the same way.
   */
  subscribeAcknowledged(
    shape: TerminalShape,
    onFrame: (frame: ShapeFrame) => void,
  ): AcknowledgedSubscription {
    return this.add({ shape, onFrame, offset: null, acks: true });
  }

  private add(subscription: Subscription): WindowedSubscription & AcknowledgedSubscription {
    const id = this.nextId++;
    this.subscriptions.set(id, subscription);
    this.sendSub(id);
    return {
      unsubscribe: () => {
        if (this.subscriptions.delete(id)) this.send({ t: "unsub", id });
      },
      more: (items) => {
        const subscription = this.subscriptions.get(id);
        if (!this.ready || subscription === undefined) return false;
        subscription.pendingMore = items;
        this.send({ t: "more", id, items });
        return true;
      },
      ack: (sequence) => {
        if (this.ready && this.subscriptions.has(id)) this.send({ t: "ack", id, sequence });
      },
      resumePoint: () =>
        subscription.offset === null
          ? null
          : { offset: subscription.offset, floor: subscription.floor, handle: subscription.handle },
    };
  }

  close(): void {
    this.closed = true;
    if (this.retryTimer !== null) clearTimeout(this.retryTimer);
    this.stopPing();
    this.socket?.close();
    this.socket = null;
  }

  private connect(): void {
    const create = this.options.createSocket ?? ((url: string) => new WebSocket(url) as SocketLike);
    const socket = create(withProtocol(this.options.url));
    this.socket = socket;
    socket.onmessage = (event) => this.onMessage(String(event.data));
    socket.onclose = () => this.onClose(socket);
    socket.onerror = () => socket.close();
  }

  private onMessage(data: string): void {
    const frame = JSON.parse(data) as ShapeFrame;
    if (frame.t === "hello") {
      this.ready = true;
      this.attempt = 0;
      this.mc = typeof frame.mc === "string" ? frame.mc : null;
      this.startPing();
      for (const id of this.subscriptions.keys()) this.sendSub(id);
      this.options.onStatus?.({ connected: true, mc: this.mc });
      return;
    }
    if (frame.t === "pong") return;
    if (frame.t === "shell.mc" && frame.online === true) this.resubscribeRefused(frame.mc);
    const id = typeof frame.id === "number" ? frame.id : null;
    if ((frame.t === "rpc.result" || frame.t === "rpc.error") && id !== null) {
      const call = this.calls.get(id);
      this.calls.delete(id);
      if (frame.t === "rpc.result") call?.resolve(frame.result);
      else call?.reject(new ClusterRpcError(String(frame.error), frame.detail));
      return;
    }
    const subscription = id === null ? undefined : this.subscriptions.get(id);
    if (subscription === undefined || id === null) return;
    if (frame.t === "resync") {
      subscription.offset = typeof frame.offset === "number" ? frame.offset : null;
      this.sendSub(id);
      return;
    }
    // The MC ended the shape and already forgot it.
    if (frame.t === "end") this.subscriptions.delete(id);
    // The MC forgot a stream it refused; it is asked again when its MC is back.
    if (frame.t === "error" && subscription.shape.type === "stream") subscription.refused = true;
    if ((frame.t === "events" || frame.t === "live") && typeof frame.offset === "number") {
      subscription.offset = frame.offset;
    }
    if (subscription.windowItems !== undefined) this.followWindow(subscription, frame);
    subscription.onFrame(frame);
  }

  // What a reconnect needs to keep a window: where it starts and the log it is of. A
  // page is the stream as of its offset, whose events came before it.
  private followWindow(subscription: Subscription, frame: ShapeFrame): void {
    if (typeof frame.handle === "string") subscription.handle = frame.handle;
    const floor = frame.floor;
    const holdsFloor = frame.t === "snapshot" || (frame.t === "page" && frame.done === true);
    if (holdsFloor && (typeof floor === "number" || floor === null)) subscription.floor = floor;
    if (frame.t === "page" && frame.done === true) delete subscription.pendingMore;
    if (frame.t === "page" && frame.done === true && typeof frame.offset === "number") {
      subscription.offset = Math.max(subscription.offset ?? 0, frame.offset);
    }
  }

  private onClose(socket: SocketLike): void {
    if (socket !== this.socket) return;
    this.socket = null;
    this.ready = false;
    for (const call of this.calls.values()) call.reject(new Error("disconnected"));
    this.calls.clear();
    this.stopPing();
    this.options.onStatus?.({ connected: false, mc: this.mc });
    if (this.closed || this.options.reconnect === false) return;
    const delays = this.options.retryDelaysMs ?? [500, 1_000, 2_000, 4_000, 8_000];
    const delay = delays[Math.min(this.attempt, delays.length - 1)] ?? 8_000;
    this.attempt++;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      this.connect();
    }, delay);
  }

  private resubscribeRefused(mc: unknown): void {
    for (const [id, subscription] of this.subscriptions) {
      if (subscription.refused !== true || subscription.shape.type !== "stream") continue;
      if (subscription.shape.mc === mc) this.sendSub(id);
    }
  }

  private sendSub(id: number): void {
    const subscription = this.subscriptions.get(id);
    if (subscription === undefined || !this.ready) return;
    delete subscription.refused;
    const offset = subscription.shape.type === "stream" ? subscription.offset : null;
    if (subscription.windowItems === undefined) {
      this.send({
        t: "sub",
        id,
        shape: subscription.shape,
        offset,
        ...(subscription.acks ? { acks: true } : {}),
        ...(subscription.have ? { have: subscription.have() } : {}),
      });
      return;
    }
    this.send({
      t: "sub",
      id,
      shape: subscription.shape,
      offset,
      window:
        subscription.floor === undefined
          ? { items: subscription.windowItems }
          : { floor: subscription.floor },
      ...(offset !== null && subscription.handle !== undefined
        ? { handle: subscription.handle }
        : {}),
    });
    // The MC drops a page owed to the subscription this one replaces.
    if (subscription.pendingMore !== undefined) {
      this.send({ t: "more", id, items: subscription.pendingMore });
    }
  }

  private send(message: unknown): void {
    if (this.socket?.readyState === OPEN) this.socket.send(JSON.stringify(message));
  }

  private startPing(): void {
    this.stopPing();
    this.pingTimer = setInterval(
      () => this.send({ t: "ping" }),
      this.options.pingIntervalMs ?? PING_INTERVAL_MS,
    );
  }

  private stopPing(): void {
    if (this.pingTimer !== null) clearInterval(this.pingTimer);
    this.pingTimer = null;
  }
}
