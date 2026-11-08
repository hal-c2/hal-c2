// Loads HAL-C2's Pi extension the way Pi does, hands one event to the handler it
// registered for it, and prints the handler's result as JSON (`null` when it
// leaves the event alone). Usage:
//   bun pi_extension_harness.ts <extension.ts> <event name> <event json> <ctx json>
// Pi itself is not installed here: `typebox`, the extension's only runtime
// import, becomes an inert stand-in, and the `pi` API records handlers.
const [extension, name, event, ctx] = Bun.argv.slice(2);

const inert: any = new Proxy(() => inert, { get: () => inert, apply: () => inert });
Bun.plugin({
  name: "typebox stand-in",
  setup(build) {
    build.module("typebox", () => ({ exports: { Type: inert }, loader: "object" }));
  },
});

const handlers = new Map<string, (event: unknown, ctx: unknown) => unknown>();
const pi = new Proxy({} as Record<string, unknown>, {
  get: (_target, key) =>
    key === "on"
      ? (event: string, handler: (event: unknown, ctx: unknown) => unknown) =>
          void handlers.set(event, handler)
      : () => undefined,
});

const { default: register } = await import(extension);
await register(pi);
const handler = handlers.get(name);
if (handler === undefined) throw new Error(`the extension does not handle ${name}`);
console.log(JSON.stringify((await handler(JSON.parse(event), JSON.parse(ctx))) ?? null));
