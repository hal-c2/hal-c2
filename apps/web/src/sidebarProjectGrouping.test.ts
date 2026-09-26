import { EnvironmentId, ProjectId } from "@hal-c2/contracts";
import { describe, expect, it } from "vite-plus/test";

import {
  buildSidebarProjectPickerRows,
  type SidebarProjectGroupMember,
  type SidebarProjectPickerEntry,
} from "./sidebarProjectGrouping";

const member = (environmentId: string, id: string, title: string) =>
  ({
    environmentId: EnvironmentId.make(environmentId),
    id: ProjectId.make(id),
    title,
    workspaceRoot: `/code/${title}`,
    physicalProjectKey: `${environmentId}:/code/${title}`,
    environmentLabel: environmentId,
  }) as SidebarProjectGroupMember;

const entry = (
  projectKey: string,
  displayName: string,
  members: SidebarProjectGroupMember[],
): SidebarProjectPickerEntry =>
  ({
    group: { projectKey, displayName, memberProjects: members },
    targetProject: members[0]!,
    isPreferred: false,
  }) as unknown as SidebarProjectPickerEntry;

describe("buildSidebarProjectPickerRows", () => {
  it("lists each checkout of a grouped project under its own name", () => {
    const mac = member("mac", "p1", "hal-c2");
    const beast = member("beast", "p2", "t3code-union");
    const scratch = member("beast", "p3", "scratch");
    const rows = buildSidebarProjectPickerRows([
      entry("github.com/hal-c2/hal-c2", "hal-c2/hal-c2", [mac, beast]),
      entry("beast:/code/scratch", "scratch", [scratch]),
    ]);

    expect(rows.map((row) => [row.value, row.label, row.projectKey])).toEqual([
      ["mac:p1", "hal-c2", "github.com/hal-c2/hal-c2"],
      ["beast:p2", "t3code-union", "github.com/hal-c2/hal-c2"],
      ["beast:p3", "scratch", "beast:/code/scratch"],
    ]);
    expect(rows[1]!.project).toBe(beast);
  });
});
