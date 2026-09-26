import { createFilesystemEnvironmentAtoms } from "@hal-c2/client-runtime/state/filesystem";

import { connectionAtomRuntime } from "../connection/runtime";

export const filesystemEnvironment = createFilesystemEnvironmentAtoms(connectionAtomRuntime);
