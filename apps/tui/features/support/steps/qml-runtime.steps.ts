// tui/qml-runtime.feature: the opentui-qml runtime the terminal client renders with.
// In-process scenarios run inline QML in the headless test renderer (`ctx.app`, so the
// shared key steps drive it); command-line scenarios spawn opentui-qml's CLI without a TTY.
import { expect } from "bun:test";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodeModule from "node:module";
import * as NodePath from "node:path";
import {
  createPropertyMap,
  listPlugins,
  unregisterPlugin,
  type PropertyMap,
  type QmlObject,
} from "opentui-qml";
import { testQml, type QmlTestApp, type TestQmlOptions } from "opentui-qml/testing";

import { step } from "../../steps.ts";
import { advance, pressKey, snapshot, typeText, type World } from "../world.ts";

const OPENTUI_QML = NodePath.resolve(import.meta.dir, "../../../node_modules/opentui-qml");
const CLI = NodePath.join(OPENTUI_QML, "src/cli.ts");
const CLI_TIMEOUT_MS = 10_000;

interface CliResult {
  readonly code: number | null;
  readonly stdout: string;
  readonly stderr: string;
}

interface RuntimeWorld extends World {
  dir?: string;
  qmlFile?: string;
  cli?: CliResult;
  qmlSource?: string;
  loadError?: unknown;
  keymapOverride?: Record<string, unknown>;
  keymapName?: string;
  visual?: VisualCase;
  hostRun?: CliResult;
  prefs?: PropertyMap;
}

// --- helpers ---------------------------------------------------------------------------------

function tempDir(ctx: RuntimeWorld): string {
  if (!ctx.dir) {
    const dir = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "t3-tui-qml-"));
    ctx.cleanups.push(() => NodeFS.rmSync(dir, { recursive: true, force: true }));
    ctx.dir = dir;
  }
  return ctx.dir;
}

function writeFile(ctx: RuntimeWorld, name: string, content: string): string {
  const file = NodePath.join(tempDir(ctx), name);
  NodeFS.mkdirSync(NodePath.dirname(file), { recursive: true });
  NodeFS.writeFileSync(file, content);
  return file;
}

/** A document that quits itself so a CLI run ends once it has drawn a frame. */
const QUIT_SOON = `Timer { interval: 50; running: true; onTriggered: Qt.quit() }`;

async function runCli(ctx: RuntimeWorld, args: string[]): Promise<CliResult> {
  const proc = Bun.spawn(["bun", CLI, ...args], {
    cwd: tempDir(ctx),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => proc.kill(), CLI_TIMEOUT_MS);
  const [code, stdout, stderr] = await Promise.all([
    proc.exited,
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  clearTimeout(timer);
  ctx.cli = { code, stdout, stderr };
  return ctx.cli;
}

/** The text a CLI run drew, without escape sequences. */
const { Terminal } = NodeModule.createRequire(import.meta.url)(
  "@xterm/headless",
) as typeof import("@xterm/headless");

/**
 * What the CLI left on screen: its stdout replayed into a headless terminal up to the point
 * it leaves the alternate screen (later frames are diffs, so stripping escapes is not enough).
 */
function drawnText(stdout: string): Promise<string> {
  const leave = stdout.lastIndexOf("\x1b[?1049l");
  const drawn = leave === -1 ? stdout : stdout.slice(0, leave);
  const term = new Terminal({ cols: 200, rows: 60, allowProposedApi: true });
  return new Promise((resolve) => {
    term.write(drawn, () => {
      const buffer = term.buffer.active;
      const rows: string[] = [];
      for (let y = 0; y < buffer.length; y++) {
        rows.push(buffer.getLine(y)?.translateToString(true) ?? "");
      }
      term.dispose();
      resolve(rows.join("\n"));
    });
  });
}

async function load(
  ctx: RuntimeWorld,
  source: string,
  options: TestQmlOptions = {},
): Promise<QmlTestApp> {
  const app = await testQml(`import OpenTUI\n${source}`, { width: 40, height: 10, ...options });
  ctx.cleanups.push(() => app.destroy());
  ctx.app = app;
  return app;
}

function app(ctx: RuntimeWorld): QmlTestApp {
  if (!ctx.app) throw new Error("no QML document is running");
  return ctx.app;
}

function byId(ctx: RuntimeWorld, id: string): QmlObject {
  const object = app(ctx).root.component.ids.get(id);
  if (!object) throw new Error(`no object with id "${id}"`);
  return object;
}

function prop(ctx: RuntimeWorld, name: string): unknown {
  return app(ctx).root.peek(name);
}

function errorText(ctx: RuntimeWorld): string[] {
  return app(ctx).errors.map((error) => (error instanceof Error ? error.message : String(error)));
}

function lines(frame: string): string[] {
  return frame.split("\n").map((line) => line.trimEnd());
}

/** Render until `ready(frame)` or give up (tree-sitter highlighting lands a few frames late). */
async function frameWhen(ctx: RuntimeWorld, ready: (frame: string) => boolean): Promise<string> {
  let frame = await snapshot(ctx);
  for (let attempt = 0; attempt < 50 && !ready(frame); attempt++) {
    await Bun.sleep(20);
    frame = await snapshot(ctx);
  }
  return frame;
}

// --- running files -----------------------------------------------------------------------------

step(
  "a QML file whose root is a Rectangle with a titled border and a Text child",
  (ctx: RuntimeWorld) => {
    ctx.qmlFile = writeFile(
      ctx,
      "box.qml",
      `import OpenTUI
Rectangle {
  border.width: 1
  title: "Greeting"
  Text { text: "hello from qml" }
  ${QUIT_SOON}
}
`,
    );
  },
);

step('the user runs "opentui-qml" on it', async (ctx: RuntimeWorld) => {
  await runCli(ctx, [ctx.qmlFile!]);
});

step(
  "the terminal shows the bordered box with its title and the text",
  async (ctx: RuntimeWorld) => {
    const { code, stdout, stderr } = ctx.cli!;
    expect(stderr).toBe("");
    expect(code).toBe(0);
    const drawn = await drawnText(stdout);
    expect(drawn).toContain("┌─Greeting");
    expect(drawn).toContain("hello from qml");
    expect(drawn).toContain("┘");
  },
);

step('the user runs "opentui-qml" with {string}', async (ctx: RuntimeWorld, flag: string) => {
  await runCli(ctx, [flag]);
});

step('the user runs "opentui-qml" with no arguments', async (ctx: RuntimeWorld) => {
  await runCli(ctx, []);
});

step('the user runs "opentui-qml" with an unknown option', async (ctx: RuntimeWorld) => {
  await runCli(ctx, ["--frobnicate"]);
});

step('the user runs "opentui-qml" with a missing file', async (ctx: RuntimeWorld) => {
  await runCli(ctx, ["missing.qml"]);
});

step('the user runs "opentui-qml" with a file that fails to load', async (ctx: RuntimeWorld) => {
  writeFile(ctx, "broken.qml", `import OpenTUI\nItem { NoSuchType {} }\n`);
  await runCli(ctx, ["broken.qml"]);
});

step("it exits with status {int}", (ctx: RuntimeWorld, status: number) => {
  const { code, stdout, stderr } = ctx.cli!;
  expect(code).toBe(status);
  if (status === 0) expect(stdout).toContain("Usage: opentui-qml");
  else expect(stderr).toContain(status === 2 ? "Usage: opentui-qml" : "opentui-qml: ");
});

/**
 * `opentui-qml app.qml ...`: the command as the feature spells it, run in a temp directory.
 * `app.qml` (and `./plugins`) are written for the scenario unless an earlier step did.
 */
step(/^the user runs "(opentui-qml(?: [^"]*)?)"$/, async (ctx: RuntimeWorld, command: string) => {
  const [, ...args] = command.split(/\s+/);
  if (args.includes("--plugins")) writePluginsFixture(ctx);
  if (!ctx.qmlFile) {
    const contextKeys = args
      .flatMap((arg, index) => (args[index - 1] === "--context" ? [arg.split("=")[0]!] : []))
      .map((key) => `"${key}=" + typeof ${key} + ":" + ${key}`);
    ctx.qmlFile = writeFile(
      ctx,
      "app.qml",
      `import OpenTUI
Item {
  Text { text: "seen " + [${contextKeys.join(", ")}].join(" ") }
  ${QUIT_SOON}
}
`,
    );
  }
  await runCli(ctx, args);
});

step(
  'QML sees "count" as the number 3 and "name" as the string "demo"',
  async (ctx: RuntimeWorld) => {
    expect(ctx.cli!.stderr).toBe("");
    expect(await drawnText(ctx.cli!.stdout)).toContain("seen count=number:3 name=string:demo");
  },
);

// --- syntax errors and rejected roots ------------------------------------------------------------

step("a QML file with an unterminated string on line 4", (ctx: RuntimeWorld) => {
  ctx.qmlFile = writeFile(
    ctx,
    "typo.qml",
    `import OpenTUI
Item {
  Text {
    text: "never closed
  }
}
`,
  );
});

step("the error names the file, line and column", (ctx: RuntimeWorld) => {
  expect(ctx.cli!.code).toBe(1);
  expect(ctx.cli!.stderr).toContain(`syntax error: ${ctx.qmlFile}:4:11:`);
});

step("the terminal is left as it was", async (ctx: RuntimeWorld) => {
  const { stdout } = ctx.cli!;
  expect((await drawnText(stdout)).trim()).toBe("");
  // Whatever modes the renderer switched on are switched off again.
  const enter = stdout.lastIndexOf("\x1b[?1049h");
  if (enter >= 0) expect(stdout.lastIndexOf("\x1b[?1049l")).toBeGreaterThan(enter);
});

step("a QML file whose root is a QtObject", (ctx: RuntimeWorld) => {
  ctx.qmlSource = `QtObject {
  property var child: QtObject { Component.onDestruction: torn.push("child") }
  Component.onCompleted: torn.push("completed")
  Component.onDestruction: torn.push("root")
}`;
});

step("it is loaded", async (ctx: RuntimeWorld) => {
  const torn: string[] = [];
  ctx.logs = torn;
  try {
    await load(ctx, ctx.qmlSource!, { context: { torn } });
  } catch (error) {
    ctx.loadError = error;
  }
});

step("loading fails and everything created so far is torn down", (ctx: RuntimeWorld) => {
  expect(ctx.app).toBeUndefined();
  expect(String(ctx.loadError)).toContain("root object must be a visual type");
  expect(ctx.logs).toEqual(["completed", "root", "child"]);
});

// --- quitting ------------------------------------------------------------------------------------

step("a running QML document", (ctx: RuntimeWorld) => {
  ctx.qmlFile = writeFile(
    ctx,
    "quits.qml",
    `import OpenTUI
Item {
  Text { text: "about to quit" }
  Timer { interval: 50; running: true; onTriggered: Qt.quit() }
}
`,
  );
  // A host process: runs the document on a real renderer and decides when to exit.
  writeFile(
    ctx,
    "host.ts",
    `import { runQml } from ${JSON.stringify(NodePath.join(OPENTUI_QML, "src/index.ts"))}
const app = await runQml(${JSON.stringify(ctx.qmlFile)})
app.renderer.once("destroy", () => {
  setTimeout(() => {
    process.stderr.write("host still running; engine destroyed=" + app.engine.isDestroyed + "\\n")
    process.exit(7)
  }, 20)
})
`,
  );
});

step("it calls Qt.quit()", async (ctx: RuntimeWorld) => {
  const proc = Bun.spawn(["bun", "host.ts"], {
    cwd: tempDir(ctx),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => proc.kill(), CLI_TIMEOUT_MS);
  const [code, stdout, stderr] = await Promise.all([
    proc.exited,
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  clearTimeout(timer);
  ctx.hostRun = { code, stdout, stderr };
});

step("the renderer is destroyed and the terminal is restored", async (ctx: RuntimeWorld) => {
  const { stdout, stderr } = ctx.hostRun!;
  expect(await drawnText(stdout)).toContain("about to quit");
  expect(stderr).toContain("engine destroyed=true");
  expect(stdout.lastIndexOf("\x1b[?1049l")).toBeGreaterThan(stdout.lastIndexOf("\x1b[?1049h"));
  expect(stdout.endsWith("\x1b[?25h")).toBe(true);
});

step("the host process decides when to exit", (ctx: RuntimeWorld) => {
  expect(ctx.hostRun!.stderr).toContain("host still running");
  expect(ctx.hostRun!.code).toBe(7);
});

// --- visual elements -----------------------------------------------------------------------------

interface VisualCase {
  readonly source: string;
  readonly height?: number;
}

const VISUALS: Record<string, VisualCase> = {
  "a Text with bold and a wrap mode": {
    source: `Item { Text { width: 12; wrapMode: Text.WordWrap; font.bold: true; text: "alpha beta gamma delta" } }`,
  },
  "a Rectangle with a radius": {
    source: `Item { Rectangle { width: 10; height: 3; border.width: 1; radius: 1 } }`,
  },
  "a Column and a Row of children": {
    source: `Item {
      Column { Text { text: "A" } Text { text: "B" } }
      Row { spacing: 1; Text { text: "C" } Text { text: "D" } }
    }`,
  },
  "a Grid of children": {
    // The runtime's Grid is a wrapping row (it ignores `columns`): its width decides the wrap.
    source: `Item { Grid { width: 5; columnGap: 1
      Text { text: "G1" } Text { text: "G2" } Text { text: "G3" } } }`,
  },
  "a RowLayout child with Layout.fillWidth": {
    source: `Item {
      RowLayout { Item { id: grow; Layout.fillWidth: true; height: 1 } Text { text: "end" } }
      Text { text: "grow=" + grow.layoutWidth }
    }`,
  },
  "an item with visible set to false": {
    source: `Item { Text { text: "shown" } Text { visible: false; text: "hidden" } }`,
  },
  "a TabBar with three tabs": {
    source: `Item { TabBar { height: 2; showDescription: false; tabWidth: 10; model: ["Home", "Settings", "Help"] } }`,
  },
  "an AsciiText": { source: `Item { AsciiText { text: "HI"; font: "tiny" } }` },
  "a Markdown block": {
    source: `Item { Markdown { height: 4; text: "# Heading\\n\\nsome **strong** words" } }`,
  },
  "a Code block with a file type": {
    source: `Item { Code { height: 1; text: "const answer = 42"; filetype: "javascript" } }`,
  },
};

step(/^a QML document with (.+)$/, async (ctx: RuntimeWorld, element: string) => {
  const visual = VISUALS[element];
  if (!visual) throw new Error(`no visual case for "${element}"`);
  ctx.visual = visual;
  await load(ctx, visual.source, { width: 40, height: visual.height ?? 8 });
});

const VISUAL_RESULTS: Record<string, (ctx: RuntimeWorld) => Promise<void>> = {
  "wrapped bold text": async (ctx) => {
    const rows = lines(await snapshot(ctx));
    expect(rows.slice(0, 2)).toEqual(["alpha beta", "gamma delta"]);
    const span = app(ctx)
      .setup.captureSpans()
      .lines[0]!.spans.find((candidate) => candidate.text.includes("alpha"));
    expect(span!.attributes & 1).toBe(1);
  },
  "a box with rounded borders": async (ctx) => {
    const rows = lines(await snapshot(ctx));
    expect(rows[0]).toBe("╭────────╮");
    expect(rows[2]).toBe("╰────────╯");
  },
  "children stacked and lined up": async (ctx) => {
    expect(lines(await snapshot(ctx)).slice(0, 3)).toEqual(["A", "B", "C D"]);
  },
  "children wrapping into rows": async (ctx) => {
    expect(lines(await snapshot(ctx)).slice(0, 2)).toEqual(["G1 G2", "G3"]);
  },
  "that child growing to fill the row": async (ctx) => {
    const frame = await snapshot(ctx);
    expect(frame).toContain("grow=37");
    expect(lines(frame)[0]).toBe(`${" ".repeat(37)}end`);
  },
  "nothing for that item": async (ctx) => {
    const frame = await snapshot(ctx);
    expect(frame).toContain("shown");
    expect(frame).not.toContain("hidden");
  },
  "the three tab labels": async (ctx) => {
    const tabs = lines(await snapshot(ctx))[0]!;
    expect(tabs.indexOf("Home")).toBeGreaterThanOrEqual(0);
    expect(tabs.indexOf("Settings")).toBeGreaterThan(tabs.indexOf("Home"));
    expect(tabs.indexOf("Help")).toBeGreaterThan(tabs.indexOf("Settings"));
  },
  "large ASCII lettering": async (ctx) => {
    const drawn = lines(await snapshot(ctx)).filter((row) => row.trim() !== "");
    expect(drawn.length).toBeGreaterThan(1);
    expect(drawn.join("\n")).not.toContain("HI");
  },
  "styled Markdown": async (ctx) => {
    const frame = await frameWhen(ctx, (text) => text.includes("some strong words"));
    expect(frame).toContain("Heading");
    expect(frame).toContain("some strong words");
    expect(frame).not.toContain("**");
    const row = app(ctx)
      .setup.captureSpans()
      .lines.find((line) => line.spans.some((span) => span.text.includes("strong")));
    expect(row!.spans.find((span) => span.text.includes("strong"))!.attributes & 1).toBe(1);
  },
  "highlighted code": async (ctx) => {
    const differentColours = () => {
      const spans = app(ctx)
        .setup.captureSpans()
        .lines[0]!.spans.filter((span) => span.text.trim() !== "");
      return new Set(spans.map((span) => span.fg.toString())).size > 1;
    };
    const frame = await frameWhen(ctx, (text) => text.includes("const") && differentColours());
    expect(frame).toContain("const answer = 42");
    expect(differentColours()).toBe(true);
  },
};

step(
  new RegExp(`^the terminal shows (${Object.keys(VISUAL_RESULTS).join("|")})$`),
  async (ctx: RuntimeWorld, result: string) => {
    await VISUAL_RESULTS[result]!(ctx);
  },
);

// --- layout and bindings ---------------------------------------------------------------------------

step("an item anchored to fill its parent", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Item {
      Rectangle { id: frame; x: 2; y: 1; width: 20; height: 6; border.width: 1
        Item { id: filler; anchors.fill: parent }
      }
      Text { y: 8; text: [filler.x, filler.y, filler.layoutWidth, filler.layoutHeight].join(",") }
    }`,
  );
});

step(
  "its x, y, layout width and layout height match the parent's content area",
  async (ctx: RuntimeWorld) => {
    const frame = await snapshot(ctx);
    // The border takes one cell on every side of the 20x6 frame.
    const filler = byId(ctx, "filler");
    expect([filler.peek("x"), filler.peek("y")]).toEqual([1, 1]);
    expect([filler.peek("layoutWidth"), filler.peek("layoutHeight")]).toEqual([18, 4]);
    expect(frame).toContain("1,1,18,4");
  },
);

step("a Text whose text is bound to a counter property", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Item {
      property int counter: 1
      property int textChanges: 0
      Text { text: "counter is " + counter; onTextChanged: textChanges++ }
    }`,
  );
  expect(await snapshot(ctx)).toContain("counter is 1");
});

step("the counter changes", (ctx: RuntimeWorld) => {
  app(ctx).root.set("counter", 2);
});

step("the next frame shows the new value", async (ctx: RuntimeWorld) => {
  const frame = await snapshot(ctx);
  expect(frame).toContain("counter is 2");
  expect(frame).not.toContain("counter is 1");
});

step("the Text's onTextChanged handler runs", (ctx: RuntimeWorld) => {
  expect(prop(ctx, "textChanges")).toBe(1);
});

step("a property bound to another property", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Item {
      property int source: 1
      property int follower: source
      signal pin
      signal rebind
      onPin: follower = 99
      onRebind: follower = Qt.binding(function() { return source * 10 })
    }`,
  );
  app(ctx).root.set("source", 2);
  expect(prop(ctx, "follower")).toBe(2);
});

step("a handler assigns it a plain value", (ctx: RuntimeWorld) => {
  app(ctx).root.emit("pin");
});

step("it stops following the other property", (ctx: RuntimeWorld) => {
  app(ctx).root.set("source", 3);
  expect(prop(ctx, "follower")).toBe(99);
});

step("assigning Qt.binding makes it follow again", (ctx: RuntimeWorld) => {
  app(ctx).root.emit("rebind");
  expect(prop(ctx, "follower")).toBe(30);
  app(ctx).root.set("source", 4);
  expect(prop(ctx, "follower")).toBe(40);
});

step("a binding that throws after its first evaluation", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Item {
      property var source: ({ value: 1 })
      property int tick: 0
      property int out: { tick; return source.value }
    }`,
    { filename: NodePath.join(tempDir(ctx), "binding.qml") },
  );
  expect(prop(ctx, "out")).toBe(1);
  app(ctx).root.set("source", null);
  app(ctx).root.set("tick", 1);
  app(ctx).root.set("tick", 2);
});

step("the property keeps its last good value", (ctx: RuntimeWorld) => {
  expect(prop(ctx, "out")).toBe(1);
});

step("the error is logged once with the file and line", (ctx: RuntimeWorld) => {
  const errors = errorText(ctx);
  expect(errors).toHaveLength(1);
  expect(errors[0]).toMatch(/binding\.qml:5:/);
});

step("two properties bound to each other", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Item {
      property int a: b + 1
      property int b: a + 1
      Text { text: "still running" }
    }`,
  );
});

step("the loop is logged and the document keeps running", async (ctx: RuntimeWorld) => {
  expect(errorText(ctx).some((error) => error.includes("binding loop detected"))).toBe(true);
  expect(await snapshot(ctx)).toContain("still running");
});

// --- scope, signals, completion, types ---------------------------------------------------------------

step(
  "a delegate that reads a name defined on itself, its parent, a document id and a context value",
  async (ctx: RuntimeWorld) => {
    await load(
      ctx,
      `Item {
        id: doc
        property string label: "document"
        property string shared: "document"
        Item {
          id: holder
          property string label: "parent"
          property string shared: "parent"
          Repeater {
            model: 1
            Item {
              objectName: "delegate"
              property string label: "self"
              property string own: label
              property string fromParent: parent.shared
              property string fromId: doc.shared
              property string fromContext: region
            }
          }
        }
      }`,
      { context: { label: "context", region: "context" } },
    );
  },
);

step("each name resolves to the nearest definition in that order", (ctx: RuntimeWorld) => {
  const holder = byId(ctx, "holder");
  const delegate = holder.children.find((child) => child.get("objectName") === "delegate")!;
  expect([
    delegate.peek("own"),
    delegate.peek("fromParent"),
    delegate.peek("fromId"),
    delegate.peek("fromContext"),
  ]).toEqual(["self", "parent", "document", "context"]);
});

step("a signal {string}", async (ctx: RuntimeWorld, signature: string) => {
  await load(
    ctx,
    `Item { signal ${signature}; property string got: ""; onMoved: { got = x + "," + y } }`,
  );
});

step("it is emitted with {int} and {int}", (ctx: RuntimeWorld, x: number, y: number) => {
  app(ctx).root.emit("moved", x, y);
});

step(
  "a block handler sees {string} as {int} and {string} as {int}",
  (ctx: RuntimeWorld, _x: string, x: number, _y: string, y: number) => {
    expect(prop(ctx, "got")).toBe(`${x},${y}`);
  },
);

step(
  "two handlers connected to the same signal and the first throws",
  async (ctx: RuntimeWorld) => {
    await load(
      ctx,
      `Item {
        id: root
        signal ping
        property int secondRuns: 0
        onPing: { throw new Error("first handler failed") }
        Connections { target: root; function onPing() { root.secondRuns++ } }
      }`,
    );
  },
);

step("the signal is emitted", (ctx: RuntimeWorld) => {
  app(ctx).root.emit("ping");
});

step("the second handler still runs", (ctx: RuntimeWorld) => {
  expect(prop(ctx, "secondRuns")).toBe(1);
  expect(errorText(ctx).some((error) => error.includes("first handler failed"))).toBe(true);
});

step("a parent and a child that both handle Component.onCompleted", async (ctx: RuntimeWorld) => {
  const order: string[] = [];
  ctx.logs = order;
  await load(
    ctx,
    `Item {
        property int width2: child.width * 2
        Component.onCompleted: order.push("parent saw " + width2)
        Item { id: child; width: 7; property int doubled: width * 2
          Component.onCompleted: order.push("child saw " + doubled) }
      }`,
    { context: { order } },
  );
});

step("the child's handler runs before the parent's", (ctx: RuntimeWorld) => {
  expect(ctx.logs!.map((entry) => entry.split(" ")[0])).toEqual(["child", "parent"]);
});

step("both see their bound values", (ctx: RuntimeWorld) => {
  expect(ctx.logs).toEqual(["child saw 14", "parent saw 14"]);
});

step("{string} next to {string}", (ctx: RuntimeWorld, type: string, main: string) => {
  expect(type).toBe("Card.qml");
  writeFile(
    ctx,
    type,
    `import OpenTUI
Column {
  property string heading: "Default heading"
  property string body: "Default body"
  Text { id: title; text: heading }
  Text { id: content; text: body }
}
`,
  );
  ctx.qmlFile = NodePath.join(tempDir(ctx), main);
});

step(
  "{string} uses {string} with its own bindings",
  async (ctx: RuntimeWorld, main: string, type: string) => {
    writeFile(
      ctx,
      main,
      `import OpenTUI
Item {
  property string mine: "Mine"
  property bool titleVisible: typeof title !== "undefined"
  ${type} { id: card; heading: parent.mine }
}
`,
    );
    const running = await testQml({ file: ctx.qmlFile! }, { width: 40, height: 6 });
    ctx.cleanups.push(() => running.destroy());
    ctx.app = running;
  },
);

step("the user's bindings win over Card's defaults", async (ctx: RuntimeWorld) => {
  const frame = await snapshot(ctx);
  expect(lines(frame).slice(0, 2)).toEqual(["Mine", "Default body"]);
  app(ctx).root.set("mine", "Changed");
  expect(lines(await snapshot(ctx))[0]).toBe("Changed");
});

step("Card's internal ids stay private", (ctx: RuntimeWorld) => {
  expect(prop(ctx, "titleVisible")).toBe(false);
  expect(app(ctx).root.component.ids.has("title")).toBe(false);
  expect(errorText(ctx)).toEqual([]);
});

// --- builtins ------------------------------------------------------------------------------------

step(
  "a Column with a Text, a Repeater of three delegates, and another Text",
  async (ctx: RuntimeWorld) => {
    await load(
      ctx,
      `Column {
        Text { text: "before" }
        Repeater { model: ["one", "two", "three"]; Text { text: modelData } }
        Text { text: "after" }
      }`,
    );
  },
);

step("the three delegates render between the two Texts", async (ctx: RuntimeWorld) => {
  expect(lines(await snapshot(ctx)).slice(0, 5)).toEqual([
    "before",
    "one",
    "two",
    "three",
    "after",
  ]);
});

step("a Repeater over a ListModel with two rows", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Column {
      ListModel { id: rows; ListElement { label: "first" } ListElement { label: "second" } }
      Repeater { model: rows; Text { text: index + ":" + label } }
      function change() { rows.append({ label: "third" }); rows.move(2, 0, 1) }
    }`,
  );
  expect(lines(await snapshot(ctx)).slice(0, 2)).toEqual(["0:first", "1:second"]);
});

step("a row is appended and another moved", (ctx: RuntimeWorld) => {
  app(ctx).proxy.change();
});

step("the rendered delegates match the model's rows and order", async (ctx: RuntimeWorld) => {
  expect(lines(await snapshot(ctx)).slice(0, 4)).toEqual(["0:third", "1:first", "2:second", ""]);
});

step("a Repeater with delegates on screen", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Column {
      Repeater { id: rep; model: 2; Text { text: "delegate " + index } }
      Text { text: "sibling" }
    }`,
  );
  expect(await snapshot(ctx)).toContain("delegate 1");
});

step("the Repeater is destroyed", (ctx: RuntimeWorld) => {
  byId(ctx, "rep").destroy();
});

step("its delegates disappear from the terminal", async (ctx: RuntimeWorld) => {
  const frame = await snapshot(ctx);
  expect(frame).not.toContain("delegate");
  expect(lines(frame)[0]).toBe("sibling");
});

step("a focused ListView over three items", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Item {
      property var picked: null
      ListView { id: list; focus: true; height: 6; showDescription: false
        model: ["alpha", "beta", "gamma"]
        onActivated: (index, option) => picked = [index, option] }
    }`,
  );
});

step(
  "the user presses {string} and then {string}",
  async (ctx: RuntimeWorld, first: string, second: string) => {
    await pressKey(ctx, first);
    await pressKey(ctx, second);
  },
);

step(
  "currentIndex is {int} and the activated signal fires for it",
  (ctx: RuntimeWorld, index: number) => {
    expect(byId(ctx, "list").peek("currentIndex")).toBe(index);
    expect(prop(ctx, "picked")).toEqual([index, "beta"]);
  },
);

step("a Loader with a sourceComponent", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Item {
      property bool show: true
      property int destroyed: 0
      Component { id: panel; Text { text: "loaded item"; Component.onDestruction: destroyed++ } }
      Loader { id: loader; sourceComponent: panel; active: show }
    }`,
  );
});

step("its item exists immediately", async (ctx: RuntimeWorld) => {
  expect(byId(ctx, "loader").peek("item")).not.toBeNull();
  expect(await snapshot(ctx)).toContain("loaded item");
});

step("setting active to false destroys the item", async (ctx: RuntimeWorld) => {
  app(ctx).root.set("show", false);
  expect(byId(ctx, "loader").peek("item")).toBeNull();
  expect(prop(ctx, "destroyed")).toBe(1);
  expect(await snapshot(ctx)).not.toContain("loaded item");
});

step(
  "a repeating Timer with an interval of {int} ms",
  async (ctx: RuntimeWorld, interval: number) => {
    await load(
      ctx,
      `Item {
      property int fired: 0
      Timer { id: timer; interval: ${interval}; repeat: true; running: true; onTriggered: fired++ }
    }`,
    );
  },
);

step("{int} ms pass", async (ctx: RuntimeWorld, ms: number) => {
  await advance(ctx, ms);
});

const COUNT_WORDS: Record<string, number> = { once: 1, twice: 2, three: 3, four: 4, five: 5 };

step(
  /^it has fired (\d+|once|twice|three|four|five)(?: times)?$/,
  (ctx: RuntimeWorld, times: string) => {
    expect(prop(ctx, "fired")).toBe(COUNT_WORDS[times] ?? Number(times));
  },
);

step("stopping it prevents further triggers", async (ctx: RuntimeWorld) => {
  const before = prop(ctx, "fired");
  byId(ctx, "timer").proxy.stop();
  await advance(ctx, 1000);
  expect(prop(ctx, "fired")).toBe(before);
});

step("Connections attached to one object", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Item {
      id: root
      property var log: []
      property var target: first
      Item { id: first; objectName: "first"; signal ping }
      Item { id: second; objectName: "second"; signal ping }
      Connections { target: root.target; function onPing() { root.log = root.log.concat([target.objectName]) } }
    }`,
  );
  byId(ctx, "first").emit("ping");
  expect(prop(ctx, "log")).toEqual(["first"]);
});

step("its target changes to another object", (ctx: RuntimeWorld) => {
  app(ctx).root.set("target", byId(ctx, "second").proxy);
});

step("handlers run for the new target's signals only", (ctx: RuntimeWorld) => {
  byId(ctx, "first").emit("ping");
  byId(ctx, "second").emit("ping");
  expect(prop(ctx, "log")).toEqual(["first", "second"]);
});

// --- keys ------------------------------------------------------------------------------------------

step(
  "a root Keys.onPressed handler and a focused child with its own handler",
  async (ctx: RuntimeWorld) => {
    await load(
      ctx,
      `Item {
        property var log: []
        Keys.onPressed: (event) => log = log.concat(["root:" + event.key])
        Item { id: child; focus: true; width: 4; height: 1
          Keys.onPressed: (event) => { log = log.concat(["child:" + event.key]); event.accepted = event.key === "x" } }
      }`,
    );
  },
);

step("the child's handler runs first", (ctx: RuntimeWorld) => {
  expect(prop(ctx, "log")).toEqual(["child:a", "root:a"]);
});

step("the root handler does not run if the child accepted the key", async (ctx: RuntimeWorld) => {
  app(ctx).root.set("log", []);
  await pressKey(ctx, "x");
  expect(prop(ctx, "log")).toEqual(["child:x"]);
});

step("a focused TextField", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Item {
      property var edits: []
      property int accepts: 0
      TextField { id: field; focus: true; width: 20; onTextEdited: edits = edits.concat([text]); onAccepted: accepts++ }
    }`,
  );
});

step(
  "the user types {string} and presses {string}",
  async (ctx: RuntimeWorld, text: string, key: string) => {
    await typeText(ctx, text);
    await pressKey(ctx, key);
  },
);

step("the text is {string}", (ctx: RuntimeWorld, text: string) => {
  expect(byId(ctx, "field").peek("text")).toBe(text);
});

step("the textEdited and accepted signals fire", (ctx: RuntimeWorld) => {
  expect((prop(ctx, "edits") as string[]).at(-1)).toBe("hello");
  expect(prop(ctx, "accepts")).toBe(1);
});

step("a TextField", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Item {
      property int edits: 0
      TextField { id: field; width: 20; onTextEdited: edits++ }
      function assign() { field.text = "from qml" }
    }`,
  );
});

step("QML assigns its text", (ctx: RuntimeWorld) => {
  app(ctx).proxy.assign();
});

step("textEdited does not fire", async (ctx: RuntimeWorld) => {
  expect(await snapshot(ctx)).toContain("from qml");
  expect(prop(ctx, "edits")).toBe(0);
});

step(
  "two keymaps bound to {string} with different priorities",
  async (ctx: RuntimeWorld, key: string) => {
    const sequence = key.toLowerCase();
    await load(
      ctx,
      `Item {
        property var log: []
        Keymap { bindings: ({ "${sequence}": "low" }); onActivated: log = log.concat([action]) }
        Keymap { priority: 5; bindings: ({ "${sequence}": "high" }); onActivated: log = log.concat([action]) }
      }`,
    );
  },
);

step("only the higher-priority binding runs", (ctx: RuntimeWorld) => {
  expect(prop(ctx, "log")).toEqual(["high"]);
});

step(
  "a keymap binding for {string} whose handler sets accepted to false",
  async (ctx: RuntimeWorld, key: string) => {
    const sequence = key.toLowerCase();
    await load(
      ctx,
      `Item {
        property var log: []
        Keymap { bindings: ({ "${sequence}": "next" }); onActivated: log = log.concat([action]) }
        Keymap { priority: 5; bindings: ({ "${sequence}": "first" })
          onActivated: (action, event) => { log = log.concat([action]); event.accepted = false } }
      }`,
    );
  },
);

step("the next binding for {string} also runs", (ctx: RuntimeWorld, _key: string) => {
  expect(prop(ctx, "log")).toEqual(["first", "next"]);
});

step(
  "a shortcut bound to {string} and a focused TextField",
  async (ctx: RuntimeWorld, key: string) => {
    await load(
      ctx,
      `Item {
        property int hits: 0
        Shortcut { sequence: "${key}"; onActivated: hits++ }
        TextField { id: field; width: 10; focus: true }
      }`,
    );
  },
);

step(
  "{string} is typed into the field and the shortcut does not fire",
  (ctx: RuntimeWorld, text: string) => {
    expect(byId(ctx, "field").peek("text")).toBe(text);
    expect(prop(ctx, "hits")).toBe(0);
  },
);

step("a Shortcut for {string} that is disabled", async (ctx: RuntimeWorld, key: string) => {
  await load(
    ctx,
    `Item {
      property int hits: 0
      property var unhandled: []
      Keys.onPressed: (event) => unhandled = unhandled.concat([event.key])
      Shortcut { sequence: "${key.toLowerCase()}"; enabled: false; onActivated: hits++ }
    }`,
  );
});

step("nothing happens", (ctx: RuntimeWorld) => {
  expect(prop(ctx, "hits")).toBe(0);
  // The disabled shortcut does not consume the key either: it reaches the root untouched.
  expect(prop(ctx, "unhandled")).toEqual(["q"]);
  expect(errorText(ctx)).toEqual([]);
});

// Keymap JSON overrides: the CLI proves the file is read and merged; the same override then
// runs in the test renderer, where a key can be pressed.
const KEYMAP_DOCUMENT = (name: string | undefined) => `import OpenTUI
Item {
  id: root
  property var log: []
  Keymap { id: keys; ${name ? `name: "${name}"; ` : ""}bindings: ({ "ctrl+s": "save" })
    onActivated: root.log = root.log.concat([action + (keys.name ? " in " + keys.name : "")]) }
  property var saveKeys: []
  Timer { interval: 30; running: true; onTriggered: root.saveKeys = keys.keysFor("save") }
  Text { text: "save keys: " + JSON.stringify(saveKeys) }
  Timer { interval: 80; running: quits; onTriggered: Qt.quit() }
}
`;

step("the document has an unnamed keymap", (ctx: RuntimeWorld) => {
  delete ctx.keymapName;
  ctx.qmlFile = writeFile(ctx, "app.qml", KEYMAP_DOCUMENT(undefined));
});

step("the document has a keymap named {string}", (ctx: RuntimeWorld, name: string) => {
  ctx.keymapName = name;
  ctx.qmlFile = writeFile(ctx, "app.qml", KEYMAP_DOCUMENT(name));
});

async function runWithKeymap(
  ctx: RuntimeWorld,
  command: string,
  override: Record<string, unknown>,
) {
  ctx.keymapOverride = override;
  writeFile(ctx, "keys.json", JSON.stringify(override));
  const [, ...args] = command.split(/\s+/);
  await runCli(ctx, [...args, "--context", "quits=true"]);
  expect(ctx.cli!.stderr).toBe("");
  expect(ctx.cli!.code).toBe(0);
  const running = await testQml(
    { file: ctx.qmlFile! },
    { width: 40, height: 4, keymap: override, context: { quits: false } },
  );
  ctx.cleanups.push(() => running.destroy());
  ctx.app = running;
  await running.advance(40);
}

step(
  "the user runs {string} with {string} bound to {string}",
  async (ctx: RuntimeWorld, command: string, action: string, key: string) => {
    await runWithKeymap(ctx, command, { [key.toLowerCase()]: action });
  },
);

step(
  "the user runs {string} with {string} with {string} bound to {string}",
  async (ctx: RuntimeWorld, command: string, name: string, action: string, key: string) => {
    await runWithKeymap(ctx, command, { [name]: { [key.toLowerCase()]: action } });
  },
);

step(
  "the user runs {string} with {string} set to null",
  async (ctx: RuntimeWorld, command: string, _action: string) => {
    // Overrides map keys to actions: unbinding "save" nulls the key it had.
    await runWithKeymap(ctx, command, { "ctrl+s": null });
  },
);

async function expectCliKeys(ctx: RuntimeWorld, keys: string[]) {
  expect(await drawnText(ctx.cli!.stdout)).toContain(`save keys: ${JSON.stringify(keys)}`);
}

step("{string} runs save", async (ctx: RuntimeWorld, key: string) => {
  await expectCliKeys(ctx, ["ctrl+s", key.toLowerCase()]);
  await pressKey(ctx, key);
  expect(prop(ctx, "log")).toEqual(["save"]);
});

step("{string} runs save in {string}", async (ctx: RuntimeWorld, key: string, name: string) => {
  await expectCliKeys(ctx, ["ctrl+s", key.toLowerCase()]);
  await pressKey(ctx, key);
  expect(prop(ctx, "log")).toEqual([`save in ${name}`]);
});

step("save has no key", async (ctx: RuntimeWorld) => {
  await expectCliKeys(ctx, []);
  await pressKey(ctx, "Ctrl+S");
  expect(prop(ctx, "log")).toEqual([]);
});

step("a keymap with bindings", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Item {
      Keymap { id: keys
        bindings: ({ "ctrl+s": { action: "save", description: "Save the file" }, "q": "quit" })
        KeyBinding { keys: ["j", "down"]; action: "next"; description: "Next item" }
      }
    }`,
  );
});

step("describe() lists each action with its keys", (ctx: RuntimeWorld) => {
  expect(byId(ctx, "keys").proxy.describe()).toEqual([
    { keys: "ctrl+s", action: "save", description: "Save the file" },
    { keys: "q", action: "quit", description: "" },
    { keys: "j", action: "next", description: "Next item" },
    { keys: "down", action: "next", description: "Next item" },
  ]);
});

step("a Shortcut with the sequence {string}", async (ctx: RuntimeWorld, sequence: string) => {
  await load(ctx, `Item { Shortcut { sequence: "${sequence}" } Text { text: "document alive" } }`);
});

step("a warning is logged and the document still runs", async (ctx: RuntimeWorld) => {
  expect(app(ctx).warnings.length).toBeGreaterThan(0);
  expect(app(ctx).warnings.join("\n")).toMatch(/Invalid .*key sequence/);
  expect(errorText(ctx)).toEqual([]);
  expect(await snapshot(ctx)).toContain("document alive");
});

// --- slots and plugins -----------------------------------------------------------------------------

function slotPlugin(id: string, text: string, order: string | number) {
  return `Plugin { pluginId: "${id}"; order: ${order}
  Contribution { slot: "side"; Text { text: "${text}" } } }
`;
}

step(
  /^a Slot in (replace|append|single_winner) mode with fallback children and (no|two) contributions$/,
  async (ctx: RuntimeWorld, mode: string, count: string) => {
    const plugins =
      count === "two"
        ? [
            writeFile(ctx, "plugins/late.qml", slotPlugin("late", "LATE", 20)),
            writeFile(ctx, "plugins/early.qml", slotPlugin("early", "EARLY", 10)),
          ]
        : [];
    await load(
      ctx,
      `Item { Slot { name: "side"; mode: "${mode}"; flexDirection: "row"; gap: 1; Text { text: "FALLBACK" } } }`,
      { plugins },
    );
  },
);

const squash = (text: string | undefined) => (text ?? "").replace(/\s+/g, "");

const SLOT_SHOWS: Record<string, string> = {
  "its fallback children": "FALLBACK",
  "both contributions without the fallback": "EARLY LATE",
  "the fallback followed by both": "FALLBACK EARLY LATE",
  "only the first contribution by order": "EARLY",
};

step(
  new RegExp(`^it shows (${Object.keys(SLOT_SHOWS).join("|")})$`),
  async (ctx: RuntimeWorld, shown: string) => {
    // Contributions sit next to each other: the runtime does not apply a gap between them.
    expect(squash(lines(await snapshot(ctx))[0])).toBe(squash(SLOT_SHOWS[shown]));
  },
);

step("a Slot showing a plugin's contribution", async (ctx: RuntimeWorld) => {
  await load(ctx, `Item { Slot { name: "side"; Text { text: "FALLBACK" } } }`, {
    plugins: [writeFile(ctx, "plugins/only.qml", slotPlugin("only", "CONTRIBUTED", 1))],
  });
  expect(lines(await snapshot(ctx))[0]).toBe("CONTRIBUTED");
});

step("that plugin is unregistered", (ctx: RuntimeWorld) => {
  expect(unregisterPlugin(app(ctx).engine, "only")).toBe(true);
});

step("the Slot shows its fallback children again", async (ctx: RuntimeWorld) => {
  expect(lines(await snapshot(ctx))[0]).toBe("FALLBACK");
  expect(listPlugins(app(ctx).engine)).toEqual([]);
});

step("two plugins contributing to the same Slot", async (ctx: RuntimeWorld) => {
  // The second plugin reads its order from a shared store, so changing it re-sorts live.
  const prefs = createPropertyMap({ second: 20 });
  ctx.prefs = prefs;
  await load(ctx, `Item { Slot { name: "side"; flexDirection: "row"; gap: 1 } }`, {
    singletons: { Prefs: prefs },
    plugins: [
      writeFile(ctx, "plugins/first.qml", slotPlugin("first", "FIRST", 10)),
      writeFile(ctx, "plugins/second.qml", slotPlugin("second", "SECOND", "Prefs.second")),
    ],
  });
  expect(squash(lines(await snapshot(ctx))[0])).toBe("FIRSTSECOND");
});

step("the second plugin's order is lowered below the first", (ctx: RuntimeWorld) => {
  ctx.prefs!.set("second", 5);
});

step("the Slot shows the second plugin's contribution first", async (ctx: RuntimeWorld) => {
  expect(squash(lines(await snapshot(ctx))[0])).toBe("SECONDFIRST");
});

step("a managed contribution in a Slot", async (ctx: RuntimeWorld) => {
  writeFile(
    ctx,
    "plugins/managed.qml",
    `Plugin { pluginId: "managed"
  Contribution { slot: "side"; mode: "managed"
    Text { property int serial: Math.floor(Math.random() * 1e9); text: "value " + data.n + " #" + serial } } }
`,
  );
  await load(ctx, `Item { property int n: 1; Slot { id: side; name: "side"; data: ({ n: n }) } }`, {
    plugins: [NodePath.join(tempDir(ctx), "plugins/managed.qml")],
  });
  ctx.logs = [lines(await snapshot(ctx))[0]!];
  expect(ctx.logs[0]).toStartWith("value 1 #");
});

step("the Slot's data changes", (ctx: RuntimeWorld) => {
  app(ctx).root.set("n", 2);
});

step("the same delegate instance shows the new data", async (ctx: RuntimeWorld) => {
  const before = ctx.logs![0]!;
  const after = lines(await snapshot(ctx))[0]!;
  expect(after).toStartWith("value 2 #");
  expect(after.split("#")[1]).toBe(before.split("#")[1]);
});

/** `./plugins` for the CLI: two plugins, one using a helper type that sits beside them. */
function writePluginsFixture(ctx: RuntimeWorld) {
  writeFile(
    ctx,
    "plugins/Badge.qml",
    `import OpenTUI
Text { property string label; text: "[" + label + "]" }
`,
  );
  writeFile(
    ctx,
    "plugins/clock.qml",
    `Plugin { pluginId: "clock"; order: 1; types: ["./Badge.qml"]
  Contribution { slot: "status"; Badge { label: "clock" } } }
`,
  );
  writeFile(
    ctx,
    "plugins/words.qml",
    `Plugin { pluginId: "words"; order: 2
  Contribution { slot: "status"; Text { text: "words" } } }
`,
  );
  ctx.qmlFile = writeFile(
    ctx,
    "app.qml",
    `import OpenTUI
Item {
  property int atStart: -1
  Slot { id: status; name: "status"; flexDirection: "row"; gap: 1 }
  Text { y: 2; text: "contributions when app.qml completed: " + atStart }
  Component.onCompleted: atStart = status.count
  ${QUIT_SOON}
}
`,
  );
}

step(
  'every file there whose root is Plugin is loaded before "app.qml"',
  async (ctx: RuntimeWorld) => {
    const { code, stdout, stderr } = ctx.cli!;
    expect(stderr).toBe("");
    expect(code).toBe(0);
    const drawn = await drawnText(stdout);
    expect(drawn).toMatch(/\[clock\]\s*words/);
    expect(drawn).toContain("contributions when app.qml completed: 2");
  },
);

step("helper types in that directory are not treated as plugins", async (ctx: RuntimeWorld) => {
  // Badge.qml is a Text, used by clock.qml: no third contribution and no error for it.
  expect(await drawnText(ctx.cli!.stdout)).not.toContain("root object is not a Plugin");
  expect(ctx.cli!.stderr).not.toContain("Badge");
});

const PLUGIN_FAILURES: Record<string, { file: string; source: string; pluginId: string }> = {
  "a plugin file with a syntax error": {
    file: "broken.qml",
    source: `Plugin {\n  pluginId: "broken"\n  Contribution { slot: "status"; Text { text: "oops\n}\n`,
    pluginId: "broken",
  },
  "a plugin whose delegate fails to render": {
    file: "renderfail.qml",
    source: `Plugin { pluginId: "renderfail"; Contribution { slot: "status"; NoSuchType { } } }\n`,
    pluginId: "renderfail",
  },
  "a second plugin with the same pluginId": {
    file: "zduplicate.qml",
    source: `Plugin { pluginId: "good"; Contribution { slot: "status"; Text { text: "duplicate" } } }\n`,
    pluginId: "good",
  },
  "a plugin whose contribution is not visual": {
    file: "notvisual.qml",
    source: `Plugin { pluginId: "notvisual"; Contribution { slot: "status"; QtObject { } } }\n`,
    pluginId: "notvisual",
  },
};

step(
  new RegExp(
    `^a plugins directory with a good plugin and (${Object.keys(PLUGIN_FAILURES).join("|")})$`,
  ),
  (ctx: RuntimeWorld, failure: string) => {
    const { file, source, pluginId } = PLUGIN_FAILURES[failure]!;
    writeFile(
      ctx,
      "plugins/good.qml",
      `Plugin { pluginId: "good"; order: 1; Contribution { slot: "status"; Text { text: "good plugin" } } }\n`,
    );
    writeFile(ctx, `plugins/${file}`, source);
    ctx.logs = [pluginId];
  },
);

step("the document loads", async (ctx: RuntimeWorld) => {
  await load(
    ctx,
    `Item {
      property var failures: []
      signal pluginError(var error)
      onPluginError: (error) => failures = failures.concat([error])
      Slot { name: "status"; flexDirection: "column" }
    }`,
    { pluginDirs: [NodePath.join(tempDir(ctx), "plugins")] },
  );
});

step("the good plugin's contribution renders", async (ctx: RuntimeWorld) => {
  const frame = await snapshot(ctx);
  expect(lines(frame)[0]).toBe("good plugin");
  expect(frame).not.toContain("duplicate");
});

step("the document's pluginError signal receives the failure", (ctx: RuntimeWorld) => {
  const failures = prop(ctx, "failures") as Array<{ pluginId: string; message: string }>;
  expect(failures.map((failure) => failure.pluginId)).toEqual(ctx.logs!.slice(0, 1));
  expect(failures[0]!.message).not.toBe("");
});
