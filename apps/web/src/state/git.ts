import { createGitEnvironmentAtoms } from "@hal-c2/client-runtime/state/git";

import { connectionAtomRuntime } from "../connection/runtime";

export const gitEnvironment = createGitEnvironmentAtoms(connectionAtomRuntime);
