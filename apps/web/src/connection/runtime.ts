import { Connection } from "@hal-c2/client-runtime/connection";
import { shellSnapshotLoaderLayer } from "@hal-c2/client-runtime/state/shell";
import {
  boundedThreadSnapshotLoaderLayer,
  threadHistoryControllerLayer,
} from "@hal-c2/client-runtime/state/threads";
import { pullRequestDiffLoaderLayer } from "@hal-c2/client-runtime/state/pull-requests";
import * as Layer from "effect/Layer";
import { Atom } from "effect/unstable/reactivity";

import { runtimeContextLayer } from "../lib/runtime";
import {
  backgroundActivityObserverLayer,
  backgroundActivityReporterLayer,
} from "../lib/backgroundActivityReporter";
import { connectionPlatformLayer } from "./platform";

const providedConnectionPlatformLayer = connectionPlatformLayer.pipe(
  Layer.provide(runtimeContextLayer),
);

const snapshotLoaderLayer = Layer.mergeAll(
  boundedThreadSnapshotLoaderLayer,
  shellSnapshotLoaderLayer,
  threadHistoryControllerLayer,
  pullRequestDiffLoaderLayer,
);

type ConnectionLayerSource =
  | typeof Connection.layer
  | typeof snapshotLoaderLayer
  | typeof runtimeContextLayer
  | typeof connectionPlatformLayer
  | typeof backgroundActivityObserverLayer
  | typeof backgroundActivityReporterLayer;

const providedClientConnectionLayer = snapshotLoaderLayer.pipe(
  Layer.provideMerge(
    Connection.layerWithOptions({
      environmentThemes: true,
      usageLimitSources: true,
      usageLimitsCommand: true,
    }),
  ),
  Layer.provideMerge(
    Layer.mergeAll(
      runtimeContextLayer,
      providedConnectionPlatformLayer,
      backgroundActivityObserverLayer,
    ),
  ),
);

const connectionLayer = backgroundActivityReporterLayer.pipe(
  Layer.provideMerge(providedClientConnectionLayer),
);

export const connectionAtomRuntime: Atom.AtomRuntime<
  Layer.Success<ConnectionLayerSource>,
  Layer.Error<ConnectionLayerSource>
> = Atom.runtime(connectionLayer);
