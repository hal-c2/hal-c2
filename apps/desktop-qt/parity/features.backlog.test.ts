// @effect-diagnostics nodeBuiltinImport:off - Plain evidence checks against files in the repository.
import * as NodeFSP from "node:fs/promises";

import { describe, expect, it } from "vite-plus/test";

type BddScenario = `Given ${string}, when ${string}, then ${string}.`;
type ServerSource = `apps/server/src/${string}` | `apps/server-ex/lib/${string}`;
/** The Electron app's host code: where the Node desktop host ports from. */
type HostSource = `apps/desktop/src/${string}`;
type ClientSource =
  | { readonly client: "web"; readonly path: `apps/web/src/${string}` }
  | { readonly client: "mobile"; readonly path: `apps/mobile/src/${string}` };

interface ShellFeatureGap {
  /** Stable identifier used when a gap moves or is split into smaller scenarios. */
  readonly id: string;
  readonly area: string;
  /** Public server operations, streams or commands that make the feature possible. */
  readonly serverCapabilities: ReadonlyArray<string>;
  /** Server implementations (Node or Elixir) proving that the capability is shipped. */
  readonly serverSources: ReadonlyArray<ServerSource>;
  /** Electron host implementations the Qt shell's Node host would port. */
  readonly hostSources: ReadonlyArray<HostSource>;
  /** Web/mobile surfaces proving that the capability is user-facing. */
  readonly clientSources: ReadonlyArray<ClientSource>;
  readonly scenarios: ReadonlyArray<BddScenario>;
}

/**
 * User-facing capabilities that ship in web or mobile but that the Qt shell
 * (`apps/desktop-qt`) does not surface yet.
 *
 * The shell renders the web app, so most of the product comes along for free.
 * What is listed here is what does not: features gated on
 * `window.desktopBridge` (Electron only), host services the Node desktop host
 * has not ported, and native bricks that stop short of the HTML they replace.
 *
 * Each scenario is skipped until its feature ships. The active catalog test
 * below still fails when evidence disappears, identifiers or scenarios collide,
 * or a scenario stops following Given/When/Then. Keymap gaps live in
 * web-parity.test.ts.
 */
const SHELL_UI_GAPS = [
  {
    id: "in-app-preview",
    area: "In-app browser preview",
    serverCapabilities: [
      "preview.list",
      "preview.open",
      "preview.refresh",
      "preview.close",
      "subscribePreviewEvents",
      "subscribeDiscoveredLocalServers",
    ],
    serverSources: ["apps/server/src/preview/Manager.ts", "apps/server-ex/lib/t3/preview.ex"],
    hostSources: ["apps/desktop/src/preview/Manager.ts"],
    clientSources: [
      { client: "web", path: "apps/web/src/components/preview/PreviewPanelShell.tsx" },
      { client: "web", path: "apps/web/src/previewStateStore.ts" },
    ],
    scenarios: [
      "Given a thread whose dev server is listening locally, when the user presses the preview toggle, then the shell opens the page in a browser tab beside the thread instead of the desktop-only toast.",
      "Given an open preview tab, when the agent restarts the dev server, then the preview reloads without the user leaving the thread.",
      "Given a preview tab in the right panel, when the user closes it, then the server-side preview session closes with it.",
    ],
  },
  {
    id: "right-panel-surfaces",
    area: "Right panel pull request list and device tabs",
    serverCapabilities: ["pullRequests.list", "device.list", "device.open", "subscribeDeviceState"],
    serverSources: [
      "apps/server/src/device/DeviceHost.ts",
      "apps/server/src/device/DeviceActions.ts",
      "apps/server-ex/lib/t3/devices.ex",
      "apps/server-ex/lib/t3/pull_requests.ex",
    ],
    hostSources: [],
    clientSources: [
      { client: "web", path: "apps/web/src/components/RightPanelTabs.tsx" },
      { client: "web", path: "apps/web/src/components/device/DevicePanel.tsx" },
      { client: "mobile", path: "apps/mobile/src/features/devices/DevicePreviewRouteScreen.tsx" },
    ],
    scenarios: [
      "Given an open right panel, when the user opens its add menu, then it offers the pull request list and connected devices next to diff, files, terminal and pull request.",
      "Given a booted simulator or a connected phone, when the user adds a device tab, then the panel streams that device's screen for the thread.",
      "Given a project with open pull requests, when the user adds a pull requests tab, then the panel lists them and opening one shows its review.",
    ],
  },
  {
    id: "app-updates",
    area: "App updates",
    serverCapabilities: ["server.commitDesktopUpdate", "server.updateServer"],
    serverSources: [
      "apps/server/src/desktopUpdate/DesktopAppUpdate.ts",
      "apps/server/src/cloud/selfUpdate.ts",
    ],
    hostSources: [
      "apps/desktop/src/updates/DesktopUpdates.ts",
      "apps/desktop/src/updates/updateChannels.ts",
    ],
    clientSources: [
      { client: "web", path: "apps/web/src/components/sidebar/SidebarUpdatePill.tsx" },
      { client: "web", path: "apps/web/src/state/desktopUpdate.ts" },
      { client: "mobile", path: "apps/mobile/src/features/updates/app-updates.ts" },
    ],
    scenarios: [
      "Given a newer shell release on the user's channel, when the shell checks for updates, then the sidebar shows the update pill with that version.",
      "Given a downloaded update, when the user chooses to restart, then the shell installs it and relaunches into the same windows.",
      "Given the user picks another update channel in settings, when the next check runs, then it follows the chosen channel.",
    ],
  },
  {
    id: "ssh-environments",
    area: "SSH environments",
    serverCapabilities: ["/oauth/token", "server.getConfig"],
    serverSources: ["apps/server/src/auth/http.ts", "apps/server/src/cli/pair.ts"],
    hostSources: [
      "apps/desktop/src/ssh/DesktopSshEnvironment.ts",
      "apps/desktop/src/ssh/DesktopSshPasswordPrompts.ts",
    ],
    clientSources: [
      { client: "web", path: "apps/web/src/components/settings/ConnectionsSettings.tsx" },
      { client: "web", path: "apps/web/src/state/desktopSshHosts.ts" },
      { client: "web", path: "apps/web/src/components/desktop/SshPasswordPromptDialog.tsx" },
    ],
    scenarios: [
      "Given a host in the user's SSH config, when the user adds it from Connections settings, then the shell starts T3 Code on that host and adds it as an environment.",
      "Given an SSH host that asks for a password, when the shell connects, then it prompts for the password and does not keep it in page state.",
      "Given a saved SSH environment, when the shell restarts, then it reconnects that environment without pairing again.",
    ],
  },
  {
    id: "network-access",
    area: "Network access and Tailscale",
    serverCapabilities: ["server.getConfig", "subscribeAuthAccess"],
    serverSources: [
      "apps/server/src/cli/pair.ts",
      "apps/server/src/environment/RemoteOpenTargets.ts",
    ],
    hostSources: [
      "apps/desktop/src/backend/DesktopServerExposure.ts",
      "apps/desktop/src/backend/tailscaleEndpointProvider.ts",
    ],
    clientSources: [
      { client: "web", path: "apps/web/src/state/desktopNetworkAccess.ts" },
      { client: "mobile", path: "apps/mobile/src/features/connection/ConnectionsRouteScreen.tsx" },
    ],
    scenarios: [
      "Given the shell's local server, when the user turns on network access in Connections settings, then the server listens on the LAN and the page shows a pairing link for other devices.",
      "Given Tailscale is running, when the user enables Tailscale serve, then the page advertises the tailnet HTTPS address for mobile pairing.",
      "Given network access is on, when the user turns it off, then the server stops listening beyond loopback.",
    ],
  },
  {
    id: "open-workspace-activation",
    area: "Open a folder from outside the app",
    serverCapabilities: ["orchestration.dispatchCommand"],
    serverSources: ["apps/server/src/orchestration/decider.ts"],
    hostSources: [
      "apps/desktop/src/app/DesktopAppActivation.ts",
      "apps/desktop/src/app/DesktopLinuxUrlHandler.ts",
    ],
    clientSources: [
      {
        client: "web",
        path: "apps/web/src/components/desktop/DesktopAppActivationCoordinator.tsx",
      },
    ],
    scenarios: [
      "Given the shell is running, when the user launches it again with a folder path, then the running window adds that folder as a project and opens a new thread in it instead of starting a second server.",
      "Given a folder that is already a project, when it is opened from outside the app, then the shell reuses that project and opens a new thread there.",
    ],
  },
  {
    id: "thread-notifications",
    area: "Thread notifications and badge",
    serverCapabilities: ["orchestration.subscribeShell"],
    serverSources: ["apps/server/src/ws.ts"],
    hostSources: [],
    clientSources: [
      { client: "web", path: "apps/web/src/components/ThreadNotificationCoordinator.tsx" },
      { client: "web", path: "apps/web/src/threadNotifications.ts" },
      { client: "mobile", path: "apps/mobile/src/features/agent-awareness/notificationPayload.ts" },
    ],
    scenarios: [
      "Given a turn finishes while the shell window is in the background, when no QML extension is installed, then the user still gets an OS notification.",
      "Given the shell runs on macOS, when a thread needs approval, then a native notification is delivered there too and not only over Linux D-Bus.",
      "Given threads with unseen completions, when the shell is in the background, then the dock or taskbar badge shows their count and clears when the user returns.",
    ],
  },
  {
    id: "screen-snap-shot",
    area: "Screen SnapShot into the composer",
    serverCapabilities: ["thread.turn.start"],
    serverSources: ["apps/server/src/attachmentStore.ts", "apps/server-ex/lib/t3/attachments.ex"],
    hostSources: [
      "apps/desktop/src/snapShot/DesktopSnapShot.ts",
      "apps/desktop/src/snapShot/CaptureShortcutConfig.ts",
    ],
    clientSources: [
      { client: "web", path: "apps/web/src/lib/desktopSnapShot.ts" },
      { client: "web", path: "apps/web/src/components/settings/SnapShotSettings.tsx" },
    ],
    scenarios: [
      "Given a SnapShot shortcut is configured, when the user presses it anywhere on the desktop, then the shell captures a region and attaches the image to the focused composer.",
      "Given the shell is running, when the user opens SnapShot settings, then they can record the global shortcut and see whether their compositor supports it.",
    ],
  },
  {
    id: "composer-keyboard-parity",
    area: "Native composer keyboard parity",
    serverCapabilities: ["thread.interaction-mode.set", "thread.turn.start"],
    serverSources: ["apps/server/src/orchestration/decider.ts"],
    hostSources: [],
    clientSources: [
      { client: "web", path: "apps/web/src/components/chat/ChatComposer.tsx" },
      { client: "web", path: "apps/web/src/composer-logic.ts" },
      { client: "web", path: "apps/web/src/components/ChatView.tsx" },
    ],
    scenarios: [
      "Given plan mode is available, when the user presses Shift+Tab in the native composer, then the interaction mode toggles between plan and build.",
      "Given an empty native composer in a thread with earlier prompts, when the user presses Up, then the previous prompt is recalled for editing.",
      "Given the native composer has focus on a draft, when the user presses Mod+Alt+Enter, then the draft is sent in the background instead of the window shortcut taking the key.",
      "Given a turn is running, when the user presses Mod+Enter in the native composer, then the message uses the opposite of the follow-up setting as it does on the web.",
      "Given the native composer toolbar, when the user presses Mod+Shift+E, then the native effort picker opens.",
    ],
  },
  {
    id: "sidebar-multi-select-and-reorder",
    area: "Sidebar multi-select and drag reorder",
    serverCapabilities: [
      "thread.active.reorder",
      "thread.pin.reorder",
      "thread.archive",
      "thread.delete",
    ],
    serverSources: [
      "apps/server/src/orchestration/decider.ts",
      "apps/server-ex/lib/t3/orchestration.ex",
    ],
    hostSources: [],
    clientSources: [
      { client: "web", path: "apps/web/src/components/Sidebar.tsx" },
      { client: "web", path: "apps/web/src/threadSelectionStore.ts" },
      { client: "web", path: "apps/web/src/hooks/useThreadActions.ts" },
    ],
    scenarios: [
      "Given several threads in the native sidebar, when the user Ctrl-clicks or Shift-clicks rows, then they are selected together and Escape clears the selection.",
      "Given a multi-selection, when the user opens the context menu, then settle, snooze and delete apply to every selected thread.",
      "Given pinned or active threads, when the user drags a row to a new position, then the new order is saved on the server.",
    ],
  },
  {
    id: "terminal-drawer-launch-context",
    area: "Terminal drawer launch context",
    serverCapabilities: ["terminal.open", "terminal.new"],
    serverSources: ["apps/server/src/terminal/Manager.ts", "apps/server-ex/lib/t3/terminal.ex"],
    hostSources: [],
    clientSources: [{ client: "web", path: "apps/web/src/components/ThreadTerminalDrawer.tsx" }],
    scenarios: [
      "Given a thread on a worktree, when the user opens a new terminal from the drawer, then it starts in the cwd and worktree the primary page would use.",
      "Given a project script launched from the header, when the drawer opens another terminal, then it keeps the same launch context as the script's terminal.",
    ],
  },
] as const satisfies ReadonlyArray<ShellFeatureGap>;

const REPOSITORY_ROOT = new URL("../../../", import.meta.url);

async function exists(path: string): Promise<boolean> {
  try {
    await NodeFSP.access(new URL(path, REPOSITORY_ROOT));
    return true;
  } catch {
    return false;
  }
}

describe("Qt shell parity backlog", () => {
  it("Given the parity catalog, when it is validated, then every gap is unique, source-backed, and written as BDD", async () => {
    const gaps: ReadonlyArray<ShellFeatureGap> = SHELL_UI_GAPS;
    const ids = gaps.map((gap) => gap.id);
    expect(new Set(ids).size).toBe(ids.length);

    const scenarios = gaps.flatMap((gap) => gap.scenarios);
    expect(new Set(scenarios).size).toBe(scenarios.length);

    const sourceChecks = await Promise.all(
      gaps.flatMap((gap) =>
        [
          ...gap.serverSources.map((path) => ({ kind: "server", path })),
          ...gap.hostSources.map((path) => ({ kind: "host", path })),
          ...gap.clientSources.map(({ client, path }) => ({ kind: client, path })),
        ].map(async ({ kind, path }) => ({ gap, kind, path, exists: await exists(path) })),
      ),
    );

    for (const gap of gaps) {
      expect(gap.id, "gap id").toMatch(/^[a-z0-9]+(-[a-z0-9]+)*$/);
      expect(gap.area.trim().length, `${gap.id} area`).toBeGreaterThan(0);
      expect(gap.serverCapabilities.length, `${gap.id} server capabilities`).toBeGreaterThan(0);
      expect(gap.serverSources.length, `${gap.id} server sources`).toBeGreaterThan(0);
      expect(gap.clientSources.length, `${gap.id} client sources`).toBeGreaterThan(0);
      expect(gap.scenarios.length, `${gap.id} scenarios`).toBeGreaterThan(0);

      expect(new Set(gap.serverCapabilities).size, `${gap.id} duplicate server capabilities`).toBe(
        gap.serverCapabilities.length,
      );
      for (const capability of gap.serverCapabilities) {
        expect(capability.trim(), `${gap.id} server capability`).toBe(capability);
        expect(capability.length, `${gap.id} server capability`).toBeGreaterThan(0);
      }

      const evidencePaths = [
        ...gap.serverSources,
        ...gap.hostSources,
        ...gap.clientSources.map(({ path }) => path),
      ];
      expect(new Set(evidencePaths).size, `${gap.id} duplicate evidence paths`).toBe(
        evidencePaths.length,
      );
      for (const path of gap.serverSources) {
        expect(
          path.startsWith("apps/server/src/") || path.startsWith("apps/server-ex/lib/"),
          `${gap.id} server source: ${path}`,
        ).toBe(true);
      }
      for (const path of gap.hostSources) {
        expect(path.startsWith("apps/desktop/src/"), `${gap.id} host source: ${path}`).toBe(true);
      }
      for (const source of gap.clientSources) {
        expect(
          source.path.startsWith(`apps/${source.client}/src/`),
          `${gap.id} client source: ${source.path}`,
        ).toBe(true);
      }
      for (const scenario of gap.scenarios) {
        expect(scenario, `${gap.id} scenario`).toMatch(/^Given .+, when .+, then .+\.$/);
      }
    }

    for (const { gap, kind, path, exists } of sourceChecks) {
      expect(exists, `${gap.id} ${kind} source: ${path}`).toBe(true);
    }
  });

  for (const gap of SHELL_UI_GAPS) {
    describe(gap.area, () => {
      for (const scenario of gap.scenarios) {
        it.skip(scenario, () => {});
      }
    });
  }
});
