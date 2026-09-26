import { scopeProjectRef } from "@hal-c2/client-runtime/environment";
import { resolveProjectSettings } from "@hal-c2/shared/projectSettings";
import { useCallback } from "react";

import { type DraftId, useComposerDraftStore } from "~/composerDraftStore";
import { hasExplicitComposerModelSelection } from "~/lib/chatThreadActions";
import { useEnvironments } from "~/state/environments";
import type { Project } from "~/types";

/**
 * Moves an open draft to another project, on this machine or another, in place: the
 * prompt stays in the same composer session, so the sidebar only gets a draft row if
 * the user later navigates away. A draft whose model the user has not picked takes
 * the new project's default.
 */
export function useRetargetDraftProject() {
  const { environments } = useEnvironments();
  const setLogicalProjectDraftThreadId = useComposerDraftStore(
    (store) => store.setLogicalProjectDraftThreadId,
  );
  const getComposerDraft = useComposerDraftStore((store) => store.getComposerDraft);
  const applyStickyState = useComposerDraftStore((store) => store.applyStickyState);
  const setModelSelection = useComposerDraftStore((store) => store.setModelSelection);

  return useCallback(
    (draftId: DraftId, logicalProjectKey: string, project: Project) => {
      const currentDraft = getComposerDraft(draftId);
      setLogicalProjectDraftThreadId(
        logicalProjectKey,
        scopeProjectRef(project.environmentId, project.id),
        draftId,
      );
      if (hasExplicitComposerModelSelection(currentDraft)) return;
      applyStickyState(draftId);
      const environmentSettings = environments.find(
        (environment) => environment.environmentId === project.environmentId,
      )?.serverConfig?.settings;
      const defaultModelSelection = environmentSettings
        ? resolveProjectSettings(environmentSettings, project.id, project).settings
            .defaultModelSelection
        : project.defaultModelSelection;
      if (defaultModelSelection) {
        setModelSelection(draftId, defaultModelSelection, { replaceOptions: true });
      }
    },
    [
      applyStickyState,
      environments,
      getComposerDraft,
      setLogicalProjectDraftThreadId,
      setModelSelection,
    ],
  );
}
