// Step registry for the Gherkin runner. Step files call `step(pattern, fn)`;
// patterns are Cucumber expressions (`{string}`, `{int}`, `{float}`, `{word}`)
// or RegExps. A step receives the scenario context and its arguments, and may
// return a new context (a plain object) or nothing to keep the current one.

export type StepContext = Record<string, unknown>;
export type StepFn<C extends StepContext = any> = (
  ctx: C,
  ...args: any[]
) => C | void | Promise<C | void>;

interface StepDefinition {
  readonly source: string;
  readonly regex: RegExp;
  /** Per parameter: how many regex groups it spans and how to convert the match. */
  readonly params: ReadonlyArray<Parameter>;
  readonly fn: StepFn;
}

const definitions: StepDefinition[] = [];

interface Parameter {
  readonly pattern: string;
  readonly groups: number;
  readonly convert: (raw: string) => unknown;
}

const PARAMETERS: Record<string, Parameter> = {
  string: { pattern: `"([^"]*)"|'([^']*)'`, groups: 2, convert: (raw) => raw },
  int: { pattern: `(-?\\d+)`, groups: 1, convert: (raw) => Number.parseInt(raw, 10) },
  float: { pattern: `(-?\\d*\\.?\\d+)`, groups: 1, convert: (raw) => Number.parseFloat(raw) },
  word: { pattern: `([^\\s]+)`, groups: 1, convert: (raw) => raw },
};

function compile(pattern: string): Pick<StepDefinition, "regex" | "params"> {
  const params: Parameter[] = [];
  let body = "";
  let last = 0;
  for (const match of pattern.matchAll(/\{(\w*)\}/g)) {
    const parameter = PARAMETERS[match[1] ?? ""];
    if (!parameter) throw new Error(`step "${pattern}": unknown parameter type {${match[1]}}`);
    body += escapeRegex(pattern.slice(last, match.index));
    body += `(?:${parameter.pattern})`;
    params.push(parameter);
    last = match.index + match[0].length;
  }
  body += escapeRegex(pattern.slice(last));
  return { regex: new RegExp(`^${body}$`), params };
}

function escapeRegex(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Register a step. Registering the same pattern twice throws at load. */
export function step<C extends StepContext = any>(pattern: string | RegExp, fn: StepFn<C>): void {
  const source = typeof pattern === "string" ? pattern : pattern.source;
  if (definitions.some((definition) => definition.source === source)) {
    throw new Error(`duplicate step definition: ${source}`);
  }
  const compiled = typeof pattern === "string" ? compile(pattern) : { regex: pattern, params: [] };
  definitions.push({ source, fn: fn as StepFn, ...compiled });
}

export interface StepMatch {
  readonly fn: StepFn;
  readonly args: unknown[];
}

/** The one definition matching `text`; null when none does, a throw when several do. */
export function matchStep(text: string): StepMatch | null {
  const matches: Array<StepMatch & { source: string }> = [];
  for (const definition of definitions) {
    const match = definition.regex.exec(text);
    if (!match) continue;
    const groups = match.slice(1);
    let args: unknown[] = groups;
    if (definition.params.length > 0) {
      let group = 0;
      args = definition.params.map((param) => {
        const raw = groups.slice(group, group + param.groups).find((g) => g !== undefined);
        group += param.groups;
        return param.convert(raw ?? "");
      });
    }
    matches.push({ fn: definition.fn, args, source: definition.source });
  }
  if (matches.length > 1) {
    throw new Error(
      `ambiguous step "${text}" matches:\n${matches.map((match) => `  ${match.source}`).join("\n")}`,
    );
  }
  return matches[0] ?? null;
}
