import type { ClusterStatus } from "@hal-c2/contracts";

import type { OrchestrationShellSnapshot, TuiClient } from "./connection.ts";

type Shell = OrchestrationShellSnapshot;
type ThreadId = Parameters<TuiClient["interrupt"]>[0];

interface Machine {
  readonly id: string;
  readonly label: string;
  readonly client: TuiClient;
  shell: Shell | null;
  readonly stop: () => void;
}

/**
 * One client over every machine of a cluster. An MC serves its own projects
 * and threads, so each connected member gets a client of its own (`connect`,
 * through the MC this terminal is paired with); this merges their shells into
 * one list that names each row's machine, and sends each request to the
 * machine that owns what it is about. A machine on its own passes through.
 *
 * A thread keeps its id when it moves, so its subscription follows it to the
 * machine that owns it now.
 */
export function makeClusterClient(
  home: TuiClient,
  connect: (environmentId: string) => TuiClient,
): TuiClient {
  let status: Extract<ClusterStatus, { clustered: true }> | null = null;
  let homeShell: Shell | null = null;
  /** The other members with a client, by environment id. */
  const members = new Map<string, Machine>();
  const shellListeners = new Set<(snapshot: Shell) => void>();
  const threadSubscriptions = new Set<{
    readonly threadId: ThreadId;
    readonly onThread: Parameters<TuiClient["subscribeThread"]>[1];
    client: TuiClient;
    stop: () => void;
  }>();
  /** What is on screen: the thread last opened, and the project of a draft open over it. */
  let viewedThread: string | null = null;
  let viewedProject: string | null = null;
  let stopHome: (() => void) | null = null;
  let stopConnection: (() => void) | null = null;

  /**
   * The machine a thread lives on. Late in a move both ends list it: the one it is
   * going to holds it by then, whether or not the one it is leaving is still there to let go.
   */
  const clientForThread = (threadId: string): TuiClient => {
    const rows = [{ client: home, shell: homeShell }, ...members.values()].flatMap(
      ({ client, shell }) => {
        const thread = shell?.threads.find((row) => row.id === threadId && !row.movedTo);
        return thread ? [{ client, thread }] : [];
      },
    );
    return (rows.find(({ thread }) => !thread.moving) ?? rows[0])?.client ?? home;
  };
  const clientForProject = (projectId: string): TuiClient => {
    for (const machine of members.values()) {
      if (machine.shell?.projects.some((project) => project.id === projectId)) {
        return machine.client;
      }
    }
    return home;
  };
  /** The machine of the thread on screen, wherever it has moved to since it was opened. */
  const threadClient = (): TuiClient =>
    viewedThread === null ? home : clientForThread(viewedThread);
  /** The machine of what is on screen: where a path that exists on several is meant. */
  const current = (): TuiClient =>
    viewedProject === null ? threadClient() : clientForProject(viewedProject);
  const hasPath = (shell: Shell | null, cwd: string) =>
    shell !== null &&
    (shell.projects.some((project) => project.workspaceRoot === cwd) ||
      shell.threads.some((thread) => thread.worktreePath === cwd));
  const clientForPath = (cwd: string | undefined): TuiClient => {
    if (cwd === undefined || members.size === 0) return home;
    const owners = [
      ...(hasPath(homeShell, cwd) ? [home] : []),
      ...[...members.values()]
        .filter((machine) => hasPath(machine.shell, cwd))
        .map((m) => m.client),
    ];
    return owners.length === 1 ? owners[0]! : current();
  };

  const merged = (): Shell | null => {
    if (homeShell === null) return null;
    if (status === null || status.members.length === 0) return homeShell;
    const parts = [
      { id: status.id, label: status.label, shell: homeShell },
      ...[...members.values()].flatMap((machine) =>
        machine.shell ? [{ id: machine.id, label: machine.label, shell: machine.shell }] : [],
      ),
    ];
    const threads = new Map<string, Shell["threads"][number]>();
    for (const { label, shell } of parts) {
      for (const thread of shell.threads) {
        // The row a machine keeps for a thread that left only says where it went.
        if (thread.movedTo) continue;
        // Late in a move both ends list it: it lives on the one it is going to (clientForThread).
        const listed = threads.get(thread.id);
        if (listed && (thread.moving || !listed.moving)) continue;
        threads.set(thread.id, { ...thread, machine: label });
      }
    }
    return {
      ...homeShell,
      projects: parts.flatMap(({ id, label, shell }) =>
        shell.projects.map((project) => ({ ...project, machine: label, machineId: id })),
      ),
      threads: [...threads.values()],
      machines: [
        { id: status.id, label: status.label, online: true },
        ...status.members.map(({ id, label, connected }) => ({ id, label, online: connected })),
      ],
    };
  };

  const changed = () => {
    for (const subscription of threadSubscriptions) {
      const client = clientForThread(subscription.threadId);
      if (client === subscription.client) continue;
      subscription.stop();
      subscription.client = client;
      subscription.stop = client.subscribeThread(subscription.threadId, subscription.onThread);
    }
    const snapshot = merged();
    if (snapshot) for (const listener of shellListeners) listener(snapshot);
  };

  /** Follow the cluster as the MC reports it: a client per connected member, none for one that left. */
  const apply = (next: ClusterStatus): ClusterStatus => {
    status = next.clustered ? next : null;
    const listed = new Map((status?.members ?? []).map((member) => [member.id, member]));
    for (const [id, machine] of members) {
      if (listed.has(id)) continue;
      machine.stop();
      void machine.client.dispose();
      members.delete(id);
    }
    for (const member of listed.values()) {
      // A member that was never reachable gets its client once it is: its rows are unknown until then.
      if (members.has(member.id) || !member.connected) continue;
      const client = connect(member.id);
      const machine: Machine = {
        id: member.id,
        label: member.label,
        client,
        shell: null,
        stop: client.subscribeShell((snapshot) => {
          machine.shell = snapshot;
          changed();
        }),
      };
      members.set(member.id, machine);
    }
    changed();
    return next;
  };
  const refresh = () =>
    home.clusterStatus().then(apply, () => {
      // An older server has no cluster: this machine stays on its own.
    });

  return {
    ...home,
    // The host reads the cluster whenever the MC says a machine came or went (`subscribeCluster`),
    // which is what keeps the members here current between reconnections.
    clusterStatus: () => home.clusterStatus().then(apply),
    clusterJoin: (link) => home.clusterJoin(link).then(apply),
    clusterRemove: (id) => home.clusterRemove(id).then(apply),
    subscribeShell: (onSnapshot) => {
      shellListeners.add(onSnapshot);
      stopHome ??= home.subscribeShell((snapshot) => {
        homeShell = snapshot;
        changed();
      });
      // Read the cluster on every (re)connection: members may have come and gone meanwhile.
      stopConnection ??= home.subscribeConnection((phase) => {
        if (phase === "connected") void refresh();
      });
      return () => {
        shellListeners.delete(onSnapshot);
      };
    },
    subscribeThread: (threadId, onThread) => {
      const client = clientForThread(threadId);
      viewedThread = threadId;
      const subscription = {
        threadId,
        onThread,
        client,
        stop: client.subscribeThread(threadId, onThread),
      };
      threadSubscriptions.add(subscription);
      return () => {
        threadSubscriptions.delete(subscription);
        subscription.stop();
      };
    },
    loadOlderThreadTurns: (threadId) => clientForThread(threadId).loadOlderThreadTurns(threadId),
    peekThread: (threadId) => clientForThread(threadId).peekThread(threadId),
    moveDestinations: (threadId) => clientForThread(threadId).moveDestinations(threadId),
    moveThread: (input) => clientForThread(input.threadId).moveThread(input),
    subscribeTerminal: (input, onEvent) =>
      clientForThread(input.threadId).subscribeTerminal(input, onEvent),
    sendReply: (thread, ...rest) => clientForThread(thread.id).sendReply(thread, ...rest),
    implementPlan: (thread, planId) => clientForThread(thread.id).implementPlan(thread, planId),
    createThread: (input) => clientForProject(input.projectId).createThread(input),
    interrupt: (threadId) => clientForThread(threadId).interrupt(threadId),
    approve: (threadId, ...rest) => clientForThread(threadId).approve(threadId, ...rest),
    respondUserInput: (threadId, ...rest) =>
      clientForThread(threadId).respondUserInput(threadId, ...rest),
    setRuntimeMode: (threadId, mode) => clientForThread(threadId).setRuntimeMode(threadId, mode),
    setInteractionMode: (threadId, mode) =>
      clientForThread(threadId).setInteractionMode(threadId, mode),
    renameThread: (threadId, title) => clientForThread(threadId).renameThread(threadId, title),
    archiveThread: (threadId) => clientForThread(threadId).archiveThread(threadId),
    unarchiveThread: (threadId) => clientForThread(threadId).unarchiveThread(threadId),
    deleteThread: (threadId) => clientForThread(threadId).deleteThread(threadId),
    settleThread: (threadId) => clientForThread(threadId).settleThread(threadId),
    unsettleThread: (threadId) => clientForThread(threadId).unsettleThread(threadId),
    stopSession: (threadId) => clientForThread(threadId).stopSession(threadId),
    revertCheckpoint: (threadId, turnCount) =>
      clientForThread(threadId).revertCheckpoint(threadId, turnCount),
    getTurnDiff: (threadId, toTurnCount) =>
      clientForThread(threadId).getTurnDiff(threadId, toTurnCount),
    getFullThreadDiff: (threadId, toTurnCount) =>
      clientForThread(threadId).getFullThreadDiff(threadId, toTurnCount),
    terminalWrite: (threadId, ...rest) =>
      clientForThread(threadId).terminalWrite(threadId, ...rest),
    terminalResize: (threadId, ...rest) =>
      clientForThread(threadId).terminalResize(threadId, ...rest),
    terminalClear: (threadId, terminalId) =>
      clientForThread(threadId).terminalClear(threadId, terminalId),
    terminalRestart: (input) => clientForThread(input.threadId).terminalRestart(input),
    terminalClose: (threadId, terminalId) =>
      clientForThread(threadId).terminalClose(threadId, terminalId),
    listTerminalIds: (threadId) => clientForThread(threadId).listTerminalIds(threadId),
    // An attachment belongs to the thread on screen.
    getAttachmentUrl: (attachmentId) => threadClient().getAttachmentUrl(attachmentId),
    getAttachmentImage: (attachmentId, resolvedUrl) =>
      threadClient().getAttachmentImage(attachmentId, resolvedUrl),
    viewProject: (projectId) => {
      viewedProject = projectId;
    },
    browseFilesystem: (partialPath, cwd) => clientForPath(cwd).browseFilesystem(partialPath, cwd),
    subscribeVcsStatus: (cwd, onStatus) => clientForPath(cwd).subscribeVcsStatus(cwd, onStatus),
    runGitStackedAction: (input) => clientForPath(input.cwd).runGitStackedAction(input),
    runGitPull: (cwd) => clientForPath(cwd).runGitPull(cwd),
    listRefs: (cwd) => clientForPath(cwd).listRefs(cwd),
    switchRef: (cwd, refName) => clientForPath(cwd).switchRef(cwd, refName),
    listEntries: (cwd) => clientForPath(cwd).listEntries(cwd),
    readFile: (cwd, relativePath) => clientForPath(cwd).readFile(cwd, relativePath),
    readFileBase64: (cwd, relativePath) => clientForPath(cwd).readFileBase64(cwd, relativePath),
    dispose: async () => {
      stopHome?.();
      stopConnection?.();
      for (const machine of members.values()) machine.stop();
      await Promise.all(
        [home, ...[...members.values()].map((machine) => machine.client)].map((client) =>
          client.dispose(),
        ),
      );
    },
  };
}
