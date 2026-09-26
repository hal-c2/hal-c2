import { createReviewEnvironmentAtoms } from "@hal-c2/client-runtime/state/review";

import { connectionAtomRuntime } from "../connection/runtime";

export const reviewEnvironment = createReviewEnvironmentAtoms(connectionAtomRuntime);
