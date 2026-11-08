// Loads HAL-C2's Pi extension the way Pi does, hands one event to the handlers it
// registered for it, and prints `{"result", "notices"}` as JSON: the last handler's
// result (`null` when they leave the event alone) and what they told the user
// through `ctx.ui.notify`. Usage:
//   bun pi_extension_harness.ts <extension.ts> <event name> <event json> <ctx json>
// The ctx JSON is the handlers' `ctx`; `trusted` (default true) answers
// `ctx.isProjectTrusted()`. Pi itself is not installed here: `typebox`, the
// extension's only runtime import from Pi, becomes an inert stand-in, and the
// `pi` API records handlers.
const [extension, name, event, ctxJson] = Bun.argv.slice(2);

const inert: any = new Proxy(() => inert, { get: () => inert, apply: () => inert });
Bun.plugin({
  name: "typebox stand-in",
  setup(build) {
    build.module("typebox", () => ({ exports: { Type: inert }, loader: "object" }));
  },
});

type Handler = (event: unknown, ctx: unknown) => unknown;
const handlers = new Map<string, Handler[]>();
const pi = new Proxy({} as Record<string, unknown>, {
  get: (_target, key) =>
    key === "on"
      ? (event: string, handler: Handler) =>
          void handlers.set(event, [...(handlers.get(event) ?? []), handler])
      : () => undefined,
});

const notices: { message: string; type?: string }[] = [];
const { trusted = true, ...fields } = JSON.parse(ctxJson);
const ctx = {
  ...fields,
  hasUI: true,
  isProjectTrusted: () => trusted,
  ui: { notify: (message: string, type?: string) => void notices.push({ message, type }) },
};

const { default: register } = await import(extension);
await register(pi);
const registered = handlers.get(name) ?? [];
if (registered.length === 0) throw new Error(`the extension does not handle ${name}`);
let result: unknown = null;
for (const handler of registered) result = (await handler(JSON.parse(event), ctx)) ?? result;
console.log(JSON.stringify({ result, notices }));
