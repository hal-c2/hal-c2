import type { EnvironmentId, HalC2ProjectFileScript, ThreadId } from "@hal-c2/contracts";
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vite-plus/test";

const testState = vi.hoisted(() => ({
  useHalC2ProjectFileScripts: vi.fn(),
  projectScriptsControl: vi.fn(),
}));

vi.mock("../../hooks/useHalC2ProjectFileScripts", () => ({
  useHalC2ProjectFileScripts: (...args: ReadonlyArray<unknown>) =>
    testState.useHalC2ProjectFileScripts(...args),
}));
vi.mock("../BranchToolbar", () => ({
  BranchToolbar: () => null,
}));
vi.mock("../ProjectScriptsControl", () => ({
  default: (props: unknown) => {
    testState.projectScriptsControl(props);
    return null;
  },
}));
vi.mock("./ThreadAutomationsPanel", () => ({
  ThreadAutomationsPanel: () => null,
}));
vi.mock("./ThreadRelationshipsControl", () => ({
  ThreadRelationshipsPanel: () => null,
}));

import { ThreadDetailsPanel, type ThreadDetailsPanelProps } from "./ThreadDetailsPanel";

describe("ThreadDetailsPanel", () => {
  beforeEach(() => {
    testState.useHalC2ProjectFileScripts.mockReset();
    testState.projectScriptsControl.mockReset();
  });

  it("passes checked-in hal-c2.json scripts to the project scripts control", () => {
    const environmentId = "environment:thread-details" as EnvironmentId;
    const gitCwd = "/tmp/thread-details-project";
    const fileScripts = [
      {
        name: "Check project",
        command: "vp check",
        icon: "test",
      },
    ] satisfies ReadonlyArray<HalC2ProjectFileScript>;
    testState.useHalC2ProjectFileScripts.mockReturnValue(fileScripts);

    const props: ThreadDetailsPanelProps = {
      mode: "popover",
      environmentId,
      threadId: "thread:thread-details" as ThreadId,
      activeProjectName: undefined,
      activeProjectScripts: [],
      preferredScriptId: null,
      keybindings: [],
      availableEditors: [],
      showOpenInPicker: false,
      gitCwd,
      isGitRepo: false,
      envLocked: false,
      availableEnvironments: [],
      onEnvironmentChange: vi.fn(),
      onEnvModeChange: vi.fn(),
      startFromOrigin: false,
      onStartFromOriginChange: vi.fn(),
      onComposerFocusRequest: vi.fn(),
      versionMismatch: null,
      onDismissVersionMismatch: vi.fn(),
      onRunProjectScript: vi.fn(),
      onAddProjectScript: vi.fn() as ThreadDetailsPanelProps["onAddProjectScript"],
      onUpdateProjectScript: vi.fn() as ThreadDetailsPanelProps["onUpdateProjectScript"],
      onDeleteProjectScript: vi.fn() as ThreadDetailsPanelProps["onDeleteProjectScript"],
    };

    renderToStaticMarkup(<ThreadDetailsPanel {...props} />);

    expect(testState.useHalC2ProjectFileScripts).toHaveBeenCalledWith(environmentId, gitCwd);
    expect(testState.projectScriptsControl).toHaveBeenCalledWith(
      expect.objectContaining({
        displayMode: "panel",
        scripts: [],
        fileScripts,
      }),
    );
  });
});
