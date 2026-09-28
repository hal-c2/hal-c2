import { useAtomValue } from "@effect/atom-react";
import { canCreateProjectInEnvironment } from "@hal-c2/client-runtime/operations/projects";
import {
  parseScopedThreadKey,
  scopeProjectRef,
  scopeThreadRef,
  scopedProjectKey,
  scopedThreadKey,
} from "@hal-c2/client-runtime/environment";
import type { EnvironmentId } from "@hal-c2/contracts";
import { ClientSettingsPatch } from "@hal-c2/contracts/settings";
import type {
  ShellNativeState,
  ShellRoute,
  ShellSidebarDraft,
  ShellSidebarState,
} from "@hal-c2/contracts/shell";
import { useParams, useRouter } from "@tanstack/react-router";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { partitionSidebarThreads, resolveAdjacentThreadId } from "../components/Sidebar.logic";
import { openCommandPalette } from "../commandPaletteBus";
import { composerDraftHasUserContent, DraftId, useComposerDraftStore } from "../composerDraftStore";
import { isHalC2ShellEmbed } from "../env";
import { useNewThreadHandler } from "../hooks/useHandleNewThread";
import { useNowMinute } from "../hooks/useNowMinute";
import { persistClientSettingsPatch, useClientSettings } from "../hooks/useSettings";
import { useSidebarProjectGroups } from "../hooks/useSidebarProjectGroups";
import { useThreadActionMenu } from "../hooks/useThreadActionMenu";
import {
  resolveShortcutCommand,
  threadJumpIndexFromCommand,
  threadTraversalDirectionFromCommand,
} from "../keybindings";
import { isTerminalFocused } from "../lib/terminalFocus";
import { requestShellRename } from "./shellRenameRequest";
import { environmentServerConfigsAtom, primaryServerKeybindingsAtom } from "../state/server";
import { useThreadShells } from "../state/entities";
import { usePrimaryEnvironment } from "../state/environments";
import { buildThreadRouteParams, resolveThreadRouteTarget } from "../threadRoutes";
import { useUiStateStore } from "../uiStateStore";
import { buildShellKeybindings } from "./shellKeybindings";
import { sameShellRoute, shellRouteFromPath } from "./shellRoute";
import { isSettingsPath } from "./shellSettingsState";
import {
  buildLogicalProjectKeyMap,
  buildShellSidebarInput,
  buildShellSidebarState,
} from "./shellSidebarState";
import { useShellActions } from "./useShellActions";
import { useShellPublish } from "./useShellPublish";
import { useShellDesktopNotifications } from "./useShellDesktopNotifications";
import { useShellThreadRowActions } from "./useShellThreadRowActions";
import { resolveShellLocalEnvironmentId } from "./shellLocalProjects";
import { requestShellProjectRemoval } from "./shellProjectRemovalRequest";

const decodeClientSettingsPatch = Schema.decodeUnknownOption(ClientSettingsPatch);

/**
 * Feeds the native shell (window.halC2Shell) the sidebar view model and turns
 * its actions into navigation. Mounted only when hosted by the shell; the
 * HTML sidebar hides itself in that case (AppSidebarLayout). Everything here
 * is derived with the same logic the HTML sidebar uses, so the two never
 * disagree about rows, order, or status. Once the shell's own node
 * connection takes the sidebar over (`shell.native`), this publishes only
 * `sidebarInput` and the shell sends the row actions itself.
 */
export function HalC2ShellBridge() {
  const router = useRouter();
  const primaryEnvironment = usePrimaryEnvironment();
  const localEnvironmentId = resolveShellLocalEnvironmentId({
    primaryEnvironmentId: primaryEnvironment?.environmentId ?? null,
    connected: canCreateProjectInEnvironment(primaryEnvironment?.connection.phase),
    hostname: window.location.hostname,
  });
  const threads = useThreadShells();
  useShellDesktopNotifications(threads);
  const { projectGroups } = useSidebarProjectGroups(threads);
  const serverConfigs = useAtomValue(environmentServerConfigsAtom);
  const keybindings = useAtomValue(primaryServerKeybindingsAtom);
  const nowMinute = useNowMinute();
  const lastVisitedAtByKey = useUiStateStore((store) => store.threadLastVisitedAtById);
  const handleNewThread = useNewThreadHandler();
  const timestampFormat = useClientSettings((settings) => settings.timestampFormat);
  const [native, setNative] = useState<ShellNativeState | null>(null);
  const [scopeProjectKey, setScopeProjectKey] = useState<string | null>(null);
  const routeTarget = useParams({
    strict: false,
    select: (params) => resolveThreadRouteTarget(params),
  });
  const activeThreadKey =
    routeTarget?.kind === "server" ? scopedThreadKey(routeTarget.threadRef) : null;
  const [menuTarget, setMenuTarget] = useState<{
    key: string;
    x: number;
    y: number;
    seq: number;
  } | null>(null);
  const menuThreadRef = menuTarget ? parseScopedThreadKey(menuTarget.key) : null;
  const menuThreadShell = useMemo(
    () =>
      menuThreadRef
        ? threads.find(
            (thread) =>
              thread.environmentId === menuThreadRef.environmentId &&
              thread.id === menuThreadRef.threadId,
          )
        : undefined,
    [menuThreadRef, threads],
  );
  const menuProjectCwd = useMemo(() => {
    if (!menuThreadShell) return null;
    for (const group of projectGroups) {
      const member = group.memberProjects.find(
        (project) =>
          project.environmentId === menuThreadShell.environmentId &&
          project.id === menuThreadShell.projectId,
      );
      if (member) return member.workspaceRoot;
    }
    return null;
  }, [menuThreadShell, projectGroups]);
  const { openMenu: openThreadMenu } = useThreadActionMenu({
    threadRef: menuThreadRef,
    projectCwd: menuProjectCwd,
    onStartRename: () => {
      if (!menuThreadRef) return;
      void router.navigate({
        to: "/$environmentId/$threadId",
        params: buildThreadRouteParams(menuThreadRef),
      });
      // The workspace bridge for that thread claims the request once mounted.
      requestShellRename(scopedThreadKey(menuThreadRef));
    },
  });
  useEffect(() => {
    if (!menuTarget || !menuThreadRef) return;
    void Promise.resolve().then(() => {
      openThreadMenu({ x: menuTarget.x, y: menuTarget.y, surface: "shell" });
    });
    // Only re-open for a new request, not for hook identity churn.
  }, [menuTarget?.seq]);
  const draftSessions = useComposerDraftStore((store) => store.draftThreadsByThreadKey);
  const draftContents = useComposerDraftStore((store) => store.draftsByThreadKey);

  const scopedGroup = useMemo(
    () =>
      scopeProjectKey === null
        ? null
        : (projectGroups.find((group) => group.projectKey === scopeProjectKey) ?? null),
    [projectGroups, scopeProjectKey],
  );
  const scopedProjectKeys = useMemo(
    () =>
      scopedGroup === null ? null : new Set(scopedGroup.memberProjectRefs.map(scopedProjectKey)),
    [scopedGroup],
  );
  useEffect(() => {
    if (scopeProjectKey !== null && scopedGroup === null) {
      setScopeProjectKey(null);
    }
  }, [scopeProjectKey, scopedGroup]);

  const capabilitiesFor = useCallback(
    (environmentId: EnvironmentId) => serverConfigs.get(environmentId)?.environment.capabilities,
    [serverConfigs],
  );
  const partition = useMemo(
    () =>
      partitionSidebarThreads({
        threads,
        scopedProjectKeys,
        capabilitiesFor,
        preciseNow: new Date().toISOString(),
      }),
    // nowMinute re-runs the partition so snoozed threads wake on time.
    [capabilitiesFor, nowMinute, scopedProjectKeys, threads],
  );
  const rowActions = useShellThreadRowActions({ partition, activeThreadKey });

  const threadCountByLogicalKey = useMemo(() => {
    const logicalKeyByPhysicalKey = buildLogicalProjectKeyMap(projectGroups);
    const counts = new Map<string, number>();
    for (const thread of threads) {
      if (thread.archivedAt !== null) continue;
      const key = logicalKeyByPhysicalKey.get(
        scopedProjectKey(scopeProjectRef(thread.environmentId, thread.projectId)),
      );
      if (key === undefined) continue;
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
    return counts;
  }, [projectGroups, threads]);

  const allDrafts = useMemo((): ReadonlyArray<ShellSidebarDraft> => {
    const logicalKeyByPhysicalKey = buildLogicalProjectKeyMap(projectGroups);
    const result: ShellSidebarDraft[] = [];
    for (const [draftId, session] of Object.entries(draftSessions)) {
      if (session.promotedTo != null) continue;
      if (!composerDraftHasUserContent(draftContents[draftId])) continue;
      const physicalKey = scopedProjectKey(
        scopeProjectRef(session.environmentId, session.projectId),
      );
      result.push({
        draftId,
        projectKey: logicalKeyByPhysicalKey.get(physicalKey) ?? physicalKey,
        label: "Draft",
      });
    }
    return result;
  }, [draftContents, draftSessions, projectGroups]);
  const drafts = useMemo(
    () =>
      scopeProjectKey === null
        ? allDrafts
        : allDrafts.filter((draft) => draft.projectKey === scopeProjectKey),
    [allDrafts, scopeProjectKey],
  );
  const activeDraftId = routeTarget?.kind === "draft" ? routeTarget.draftId : null;

  const sidebarInput = useMemo(
    () =>
      buildShellSidebarInput({
        projectGroups,
        localEnvironmentId,
        drafts: allDrafts,
        activeThreadKey,
        activeDraftId,
        timestampFormat,
        scopeProjectKey,
      }),
    [
      activeDraftId,
      activeThreadKey,
      allDrafts,
      localEnvironmentId,
      projectGroups,
      scopeProjectKey,
      timestampFormat,
    ],
  );
  useShellPublish("sidebarInput", sidebarInput);

  const state = useMemo(
    (): ShellSidebarState | undefined =>
      native?.sidebar
        ? undefined
        : buildShellSidebarState({
            localEnvironmentId,
            projectGroups,
            scopeProjectKey,
            partition,
            capabilitiesFor,
            threadCountByLogicalKey,
            lastVisitedAtByKey,
            drafts,
            activeThreadKey,
            activeDraftId,
          }),
    [
      activeDraftId,
      activeThreadKey,
      capabilitiesFor,
      drafts,
      lastVisitedAtByKey,
      localEnvironmentId,
      native?.sidebar,
      partition,
      projectGroups,
      scopeProjectKey,
      threadCountByLogicalKey,
    ],
  );

  useShellPublish("sidebar", state);

  const shellKeybindings = useMemo(
    () => buildShellKeybindings(keybindings, navigator.platform),
    [keybindings],
  );
  useShellPublish("keybindings", shellKeybindings);

  // The HTML sidebar owns thread traversal and is not mounted under the
  // shell, so the same keydown handling lives here, over the same order the
  // native rows render in.
  const orderedThreadKeys = useMemo(
    () =>
      [
        ...partition.pinnedThreads,
        ...partition.activeThreads,
        ...partition.snoozedThreads,
        ...partition.settledThreads,
      ].map((thread) => scopedThreadKey(scopeThreadRef(thread.environmentId, thread.id))),
    [partition],
  );
  useEffect(() => {
    const onWindowKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.repeat) return;
      const command = resolveShortcutCommand(event, keybindings, {
        platform: navigator.platform,
        context: { terminalFocus: isTerminalFocused() },
      });
      const direction = threadTraversalDirectionFromCommand(command);
      const jumpIndex = threadJumpIndexFromCommand(command ?? "");
      if (direction === null && jumpIndex === null) return;
      const targetKey =
        direction !== null
          ? resolveAdjacentThreadId({
              threadIds: orderedThreadKeys,
              currentThreadId: activeThreadKey,
              direction,
            })
          : (orderedThreadKeys[jumpIndex ?? -1] ?? null);
      const threadRef = targetKey === null ? null : parseScopedThreadKey(targetKey);
      if (threadRef === null) return;
      event.preventDefault();
      event.stopPropagation();
      void router.navigate({
        to: "/$environmentId/$threadId",
        params: buildThreadRouteParams(threadRef),
      });
    };
    window.addEventListener("keydown", onWindowKeyDown);
    return () => window.removeEventListener("keydown", onWindowKeyDown);
  }, [activeThreadKey, keybindings, orderedThreadKeys, router]);

  const newThreadIn = (projectKey: string | undefined) => {
    const group =
      projectKey === undefined
        ? projectGroups[0]
        : projectGroups.find((item) => item.projectKey === projectKey);
    if (group === undefined) {
      // A stale key (project removed, environment gone) must not land
      // the thread in whichever project sorts first.
      if (projectKey === undefined) openCommandPalette({ open: "add-project" });
      return;
    }
    void handleNewThread(scopeProjectRef(group.environmentId, group.id));
  };

  // The shell owns the route once it has its node (`route.follow`); the page
  // reports where its own links and redirects take it (`route.open`), except
  // to the route it was just told to show.
  const shownRouteRef = useRef<ShellRoute | null>(null);
  useEffect(() => {
    if (isHalC2ShellEmbed) return;
    return router.history.subscribe(({ location, action }) => {
      const route = shellRouteFromPath(location.pathname);
      if (route === null) return;
      if (shownRouteRef.current !== null && sameShellRoute(route, shownRouteRef.current)) return;
      shownRouteRef.current = route;
      void window.halC2Shell?.dispatch("route.open", {
        ...route,
        replace: action.type === "REPLACE",
      });
    });
  }, [router]);
  const followRoute = (route: ShellRoute) => {
    // Pairing and onboarding finish before the page shows anything else.
    if (isHalC2ShellEmbed || shellRouteFromPath(router.state.location.pathname) === null) return;
    shownRouteRef.current = route;
    switch (route.kind) {
      case "home":
        void router.navigate({ to: "/" });
        return;
      case "thread": {
        const threadRef = route.threadKey === null ? null : parseScopedThreadKey(route.threadKey);
        if (threadRef === null) return;
        void router.navigate({
          to: "/$environmentId/$threadId",
          params: buildThreadRouteParams(threadRef),
        });
        return;
      }
      case "draft":
        if (route.draftId === null) return;
        void router.navigate({
          to: "/draft/$draftId",
          params: { draftId: DraftId.make(route.draftId) },
        });
        return;
      case "newThread":
        newThreadIn(route.projectKey ?? undefined);
        return;
      case "settings":
        void router.navigate({
          to: route.section !== null && isSettingsPath(route.section) ? route.section : "/settings",
        });
        return;
      case "pullRequests":
        void router.navigate({
          to: "/pull-requests",
          search: { involvement: "all", state: "open" },
        });
        return;
      case "usage":
        void router.navigate({ to: "/usage" });
        return;
    }
  };

  useShellActions((action) => {
    switch (action.type) {
      case "route.follow":
        followRoute(action);
        return;
      case "clientSettings.follow": {
        // The shell keeps this device's client settings; the page follows them.
        const patch = decodeClientSettingsPatch(action.settings);
        if (Option.isSome(patch)) void persistClientSettingsPatch(patch.value);
        return;
      }
      case "thread.open": {
        const threadRef = parseScopedThreadKey(action.key);
        if (threadRef === null) return;
        void router.navigate({
          to: "/$environmentId/$threadId",
          params: buildThreadRouteParams(threadRef),
        });
        return;
      }
      case "draft.open":
        void router.navigate({
          to: "/draft/$draftId",
          params: { draftId: DraftId.make(action.draftId) },
        });
        return;
      case "thread.new":
        newThreadIn(action.projectKey);
        return;
      case "sidebar.scope":
        setScopeProjectKey(action.projectKey);
        return;
      case "thread.menu":
        setMenuTarget((prev) => ({
          key: action.key,
          x: action.x,
          y: action.y,
          seq: (prev?.seq ?? 0) + 1,
        }));
        return;
      case "thread.settle":
        rowActions.settle(action.key);
        return;
      case "thread.markUnread":
        rowActions.markUnread(action.key);
        return;
      case "thread.unsettle":
        rowActions.unsettle(action.key);
        return;
      case "thread.unsnooze":
        rowActions.unsnooze(action.key);
        return;
      case "thread.snoozeMenu":
        rowActions.openSnoozeMenu(action.key, { x: action.x, y: action.y });
        return;
      case "thread.wokeDismiss":
        rowActions.dismissWoke(action.key);
        return;
      case "keybinding.press": {
        // Native chrome had focus, so the page never saw the keydown. Replay
        // it on the document: every shortcut handler listens on window, and
        // a body target reads as "not typing" to all of them.
        if (isHalC2ShellEmbed) return;
        document.body.dispatchEvent(
          new KeyboardEvent("keydown", {
            key: action.key,
            ctrlKey: action.ctrlKey,
            metaKey: action.metaKey,
            shiftKey: action.shiftKey,
            altKey: action.altKey,
            bubbles: true,
            cancelable: true,
          }),
        );
        return;
      }
      case "project.add":
        openCommandPalette({ open: "add-project" });
        return;
      case "project.remove": {
        const project = sidebarInput.localProjects.find((entry) => entry.key === action.projectKey);
        if (!project || localEnvironmentId === null) return;
        const cancel = requestShellProjectRemoval(project.key);
        void router
          .navigate({
            to: "/settings/projects",
            search: { project: project.logicalProjectKey, machine: localEnvironmentId },
          })
          .catch(cancel);
        return;
      }
      case "palette.open":
        openCommandPalette({});
        return;
      case "settings.open":
        void router.navigate({ to: "/settings" });
        return;
      case "pullRequests.open":
        void router.navigate({
          to: "/pull-requests",
          search: { involvement: "all", state: "open" },
        });
        return;
      case "usage.open":
        void router.navigate({ to: "/usage" });
        return;
      case "shell.native":
        setNative((prev) =>
          prev?.sidebar === action.sidebar && prev.composer === action.composer
            ? prev
            : { sidebar: action.sidebar, composer: action.composer },
        );
        return;
    }
  });
  // Declared after the action subscription so the answer finds it: a page
  // (re)loaded after the shell took over learns so here.
  useEffect(() => {
    void window.halC2Shell?.dispatch("shell.native.query");
  }, []);

  return null;
}
