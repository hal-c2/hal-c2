import { createSourceControlEnvironmentAtoms } from "@hal-c2/client-runtime/state/source-control";

import { connectionAtomRuntime } from "../connection/runtime";

export const sourceControlEnvironment = createSourceControlEnvironmentAtoms(connectionAtomRuntime);
