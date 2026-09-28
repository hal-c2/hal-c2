import { useAtomValue } from "@effect/atom-react";
import * as Option from "effect/Option";
import { Atom } from "effect/unstable/reactivity";
import { useMemo } from "react";

import { useEnvironments, usePrimaryEnvironmentId } from "../state/environments";
import { environmentSession } from "../state/session";
import { useShellPublish } from "./useShellPublish";

/**
 * Publishes `environmentAccess` to the Qt shell: every saved environment besides
 * the primary one, with its origin and bearer token while the page is connected.
 * The shell lends them to its node, which then reaches those environments for the
 * native terminal drawer with what this page already paired; an environment
 * listed without access keeps what was lent, one no longer listed is taken back.
 * Relay environments hold proof-bound tokens the node cannot use, so they never
 * carry access.
 */
export function useShellEnvironmentAccess() {
  const primaryEnvironmentId = usePrimaryEnvironmentId();
  const { isReady, environments } = useEnvironments();
  const ids = useMemo(
    () =>
      environments
        .map((environment) => environment.environmentId)
        .filter((id) => id !== primaryEnvironmentId),
    [environments, primaryEnvironmentId],
  );
  const preparedAtom = useMemo(
    () =>
      Atom.make((get) =>
        ids.map((id) => ({
          id,
          prepared: Option.getOrNull(get(environmentSession.preparedConnectionValueAtom(id))),
        })),
      ),
    [ids],
  );
  const prepared = useAtomValue(preparedAtom);
  const access = useMemo(
    () =>
      prepared.map(({ id, prepared: connection }) =>
        connection?.httpAuthorization?._tag === "Bearer"
          ? {
              environmentId: id,
              origin: connection.httpBaseUrl,
              token: connection.httpAuthorization.token,
            }
          : { environmentId: id },
      ),
    [prepared],
  );

  useShellPublish("environmentAccess", isReady ? access : undefined);
}
