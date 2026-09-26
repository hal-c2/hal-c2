import { DEFAULT_SIGNAL_EXPORT } from "@hal-c2/shared/observability";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { type ProviderReplayTranscript } from "@hal-c2/contracts";
import * as CodexClient from "effect-codex-app-server/client";
import * as CodexReplay from "effect-codex-app-server/replay";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as PlatformError from "effect/PlatformError";
import * as Schema from "effect/Schema";

import { halC2DirsUnder } from "@hal-c2/shared/xdgDirs";
import { deriveServerPaths, ensureServerDirectories, ServerConfig } from "../../config.ts";
import { layer as idAllocatorLayer } from "../IdAllocator.ts";
import { ProviderAdapterOpenSessionError } from "../ProviderAdapter.ts";
import { ProviderAdapterDriverCreateError } from "../ProviderAdapterDriver.ts";
import { makeDriverLayer as makeProviderAdapterRegistryDriverLayer } from "../ProviderAdapterRegistry.ts";
import type { OrchestratorV2ProviderReplayHarness } from "../testkit/ProviderReplayHarness.ts";
import type { ProviderReplayGate } from "../testkit/ProviderReplayGate.testkit.ts";
import {
  CODEX_DEFAULT_INSTANCE_ID,
  CODEX_DRIVER_KIND,
  CodexAdapterV2Driver,
  CodexAppServerClientFactory,
} from "./CodexAdapterV2.ts";

export class CodexReplayTranscriptDecodeError extends Schema.TaggedError<CodexReplayTranscriptDecodeError>()(
  "CodexReplayTranscriptDecodeError",
  {
    driver: Schema.optional(Schema.String),
    protocol: Schema.optional(Schema.String),
    scenario: Schema.optional(Schema.String),
    cause: Schema.Defect(),
  },
) {
  override get message(): string {
    return `Failed to decode Codex app-server replay transcript for scenario ${this.scenario ?? "<unknown>"}.`;
  }
}

export const CodexOrchestratorReplayHarnessError = Schema.Union([
  CodexReplayTranscriptDecodeError,
  CodexReplay.CodexAppServerReplayError,
  ProviderAdapterDriverCreateError,
]);
export type CodexOrchestratorReplayHarnessError = typeof CodexOrchestratorReplayHarnessError.Type;

function metadataFromTranscript(transcript: ProviderReplayTranscript): {
  readonly provider?: string;
  readonly protocol?: string;
  readonly scenario?: string;
} {
  return {
    provider: transcript.provider,
    protocol: transcript.protocol,
    scenario: transcript.scenario,
  };
}

export function makeReplayServerConfig(
  scenario: string,
): Effect.Effect<
  ServerConfig["Service"],
  PlatformError.PlatformError,
  FileSystem.FileSystem | Path.Path
> {
  return Effect.gen(function* () {
    const fs = yield* FileSystem.FileSystem;
    const baseDir = yield* fs.makeTempDirectory({
      prefix: `hal-c2-orchestration-v2-codex-${scenario}-`,
    });
    const derivedPaths = yield* deriveServerPaths(halC2DirsUnder(baseDir, process.platform));
    yield* ensureServerDirectories(derivedPaths);

    return {
      logLevel: "Error",
      traceMinLevel: "Info",
      traceTimingEnabled: true,
      traceBatchWindowMs: 200,
      traceMaxBytes: 10 * 1024 * 1024,
      traceMaxFiles: 10,
      otlpTracesUrl: undefined,
      otlpMetricsUrl: undefined,
      otlpLogsUrl: undefined,
      otlpTracesExport: DEFAULT_SIGNAL_EXPORT,
      otlpMetricsExport: DEFAULT_SIGNAL_EXPORT,
      otlpLogsExport: DEFAULT_SIGNAL_EXPORT,
      otlpServiceName: "hal-c2-server",
      mode: "web",
      port: 0,
      host: undefined,
      cwd: process.cwd(),
      homeRoot: baseDir,
      staticDir: undefined,
      devUrl: undefined,
      devAllowedOrigins: [],
      noBrowser: false,
      startupPresentation: "browser",
      tailscaleServeEnabled: false,
      tailscaleServePort: 443,
      desktopBootstrapToken: undefined,
      autoBootstrapProjectFromCwd: false,
      logWebSocketEvents: false,
      ...derivedPaths,
    };
  });
}

export function makeCodexProviderAdapterRegistryReplayLayer(input: {
  readonly transcript: CodexReplay.CodexAppServerReplayTranscript;
  readonly driver?: CodexReplay.CodexAppServerReplayDriver;
}) {
  const replayLayer =
    input.driver === undefined
      ? CodexReplay.layerReplay(input.transcript)
      : CodexReplay.layerReplayWithDriver(input.driver);
  const replayClientFactoryLayer = Layer.succeed(CodexAppServerClientFactory, {
    open: (openInput) =>
      Effect.gen(function* () {
        const context = yield* Layer.build(replayLayer).pipe(
          Effect.mapError(
            (cause) =>
              new ProviderAdapterOpenSessionError({
                driver: CODEX_DRIVER_KIND,
                providerSessionId: openInput.providerSessionId,
                cause,
              }),
          ),
        );
        return yield* Effect.service(CodexClient.CodexAppServerClient).pipe(
          Effect.provide(context),
        );
      }),
  });
  const serverConfigLayer = Layer.effect(
    ServerConfig,
    makeReplayServerConfig(input.transcript.scenario).pipe(Effect.orDie),
  ).pipe(Layer.provide(NodeServices.layer));
  const registryLayer = makeProviderAdapterRegistryDriverLayer({
    drivers: [CodexAdapterV2Driver],
    configMap: {
      [CODEX_DEFAULT_INSTANCE_ID]: {
        driver: CODEX_DRIVER_KIND,
      },
    },
  }).pipe(
    Layer.provide(
      Layer.mergeAll(
        replayClientFactoryLayer,
        serverConfigLayer,
        NodeServices.layer,
        idAllocatorLayer,
      ),
    ),
  );

  return registryLayer;
}

const decodeCodexAppServerReplayTranscript = Schema.decodeUnknownEffect(
  CodexReplay.CodexAppServerReplayTranscript,
);

export const CodexOrchestratorReplayHarness: OrchestratorV2ProviderReplayHarness<
  CodexReplay.CodexAppServerReplayTranscript,
  CodexOrchestratorReplayHarnessError
> = {
  driver: CODEX_DRIVER_KIND,
  decodeTranscript: (transcript) =>
    decodeCodexAppServerReplayTranscript(transcript).pipe(
      Effect.mapError(
        (cause) =>
          new CodexReplayTranscriptDecodeError({
            ...metadataFromTranscript(transcript),
            cause,
          }),
      ),
    ),
  makeProviderAdapterRegistryLayer: (
    transcript,
    options: { readonly replayGate?: ProviderReplayGate } = {},
  ) => {
    return Layer.effectContext(
      Effect.gen(function* () {
        const replayGate = options.replayGate;
        if (replayGate !== undefined) {
          yield* Effect.addFinalizer(() => Effect.sync(() => replayGate.releaseAll()));
        }
        const driver = yield* CodexReplay.makeReplayDriver(
          transcript,
          replayGate === undefined
            ? {}
            : {
                beforeEmitInbound: (entry) =>
                  Effect.promise((signal) => replayGate.beforeEmit(entry.label, signal)),
              },
        );
        return yield* Layer.build(
          makeCodexProviderAdapterRegistryReplayLayer({ transcript, driver }),
        );
      }),
    );
  },
};
