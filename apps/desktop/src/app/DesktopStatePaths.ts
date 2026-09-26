import * as Option from "effect/Option";

export type JoinPath = (first: string, ...segments: string[]) => string;

function normalizeConfiguredBaseDir(halC2Home: Option.Option<string>): Option.Option<string> {
  if (Option.isNone(halC2Home)) {
    return Option.none();
  }
  const trimmed = halC2Home.value.trim();
  return trimmed.length > 0 ? Option.some(trimmed) : Option.none();
}

export function resolveDesktopBaseDir(input: {
  readonly homeDirectory: string;
  readonly joinPath: JoinPath;
  readonly halC2Home: Option.Option<string>;
}): string {
  return Option.getOrElse(normalizeConfiguredBaseDir(input.halC2Home), () =>
    input.joinPath(input.homeDirectory, ".hal-c2"),
  );
}

export function resolveDesktopStateDir(input: {
  readonly baseDir: string;
  readonly isDevelopment: boolean;
  readonly joinPath: JoinPath;
  readonly halC2Home: Option.Option<string>;
}): string {
  const useDevSubdir =
    input.isDevelopment && Option.isNone(normalizeConfiguredBaseDir(input.halC2Home));
  return input.joinPath(input.baseDir, useDevSubdir ? "dev" : "userdata");
}
