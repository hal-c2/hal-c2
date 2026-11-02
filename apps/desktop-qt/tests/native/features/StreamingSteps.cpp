// What a turn shows while and after it streams (features/timeline/streaming.feature):
// a reply's shell command run from its code block in the thread's terminal. The stream
// is Stream.h's; the rows are read from the Timeline brick drawing it, wired
// as ThreadView wires it.

#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include <memory>

#include "Brick.h"
#include "FakeTerminals.h"
#include "Harness.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

// The open thread's timeline, its replies' commands run as ThreadView runs them.
Brick& timelineBrick(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world,
                                          "import QtQuick\nimport HalC2.Bricks\nimport HalC2.Shell\n"
                                          "Timeline { runnable: true\n"
                                          "  onRunCommand: command => Shell.dispatch(\"workspace.runCommand\", { command: command }) }\n",
                                          QSize(820, 1400));
    world.brick->root()->setProperty("model", QVariant::fromValue(static_cast<QObject*>(&timeline(world))));
  }
  return *world.brick;
}

void collect(QQuickItem* item, const QString& name, QList<QQuickItem*>& out) {
  if (item->objectName() == name) out.append(item);
  for (QQuickItem* child : item->childItems()) collect(child, name, out);
}

QList<QQuickItem*> visible(World& world, const QString& name) {
  QList<QQuickItem*> items, shown;
  collect(timelineBrick(world).window().contentItem(), name, items);
  for (QQuickItem* item : std::as_const(items)) {
    if (item->isVisible()) shown.append(item);
  }
  return shown;
}

// The newest reply as its Markdown brick draws it.
QQuickItem* drawnReply(World& world) {
  QQuickItem* found = nullptr;
  world.waitFor([&] {
    QList<QQuickItem*> all;
    collect(timelineBrick(world).window().contentItem(), QString(), all);
    found = nullptr;
    for (QQuickItem* item : std::as_const(all)) {
      const QMetaObject* meta = item->metaObject();
      if (meta->indexOfProperty("lineBreaks") >= 0 && meta->indexOfProperty("segmentCount") >= 0 && !item->property("lineBreaks").toBool()) found = item;
    }
    return found != nullptr;
  }, [&] { return QStringLiteral("a reply to be drawn; %1").arg(describe(timeline(world))); });
  return found;
}

void click(World& world, QQuickItem* item) {
  Brick& brick = timelineBrick(world);
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item, 0.5, 0.5));
}

const QString kCommand = QStringLiteral("bun test cart");

// A reply of the current thread holding `block`, written or still streaming.
void replyWith(World& world, const QString& block, bool streaming = false) {
  startRun(world, 30);
  QJsonObject fields{{QStringLiteral("text"), QStringLiteral("Run the tests:\n\n") + block}};
  if (streaming) {
    fields.insert(QStringLiteral("streaming"), true);
    fields.insert(QStringLiteral("status"), QStringLiteral("running"));
  }
  addItem(world, QStringLiteral("assistant_message"), fields);
  if (!streaming) settleRun(world, QStringLiteral("completed"), 30);
}

QString preferredScript(World& world) {
  return show(world.state(QStringLiteral("workspace")).toMap().value(QStringLiteral("preferredScriptId")));
}

// The workspace's preferred script before the user ran a reply's command.
struct Before {
  QString preferred;
};

const Steps steps([] {
  // A reply's shell command, run from its code block.
  step(QStringLiteral("the agent's reply has a single-line shell command in a code block"), [](World& world, const Captures&, const Table&) {
    replyWith(world, QStringLiteral("```bash\n") + kCommand + QStringLiteral("\n```"));
  });
  step(QStringLiteral("the user runs the command from its code block"), [](World& world, const Captures&, const Table&) {
    world.mc.part<Before>().preferred = preferredScript(world);
    drawnReply(world);
    world.waitFor([&] { return visible(world, QStringLiteral("runCode")).size() == 1; },
                  [&] { return QStringLiteral("the code block to offer Run; %1 offered").arg(visible(world, QStringLiteral("runCode")).size()); });
    click(world, visible(world, QStringLiteral("runCode")).constFirst());
    world.sync();
  });
  step(QStringLiteral("the command runs in the thread's terminal in the thread's folder"), [](World& world, const Captures&, const Table&) {
    const QVariantMap workspace = world.state(QStringLiteral("workspace")).toMap();
    const QString folder = workspace.value(QStringLiteral("worktreePath")).toString().isEmpty() ? workspace.value(QStringLiteral("projectRoot")).toString()
                                                                                                 : workspace.value(QStringLiteral("worktreePath")).toString();
    world.waitFor([&] {
      const auto open = terminalfake::terminalCall(world, QStringLiteral("terminal.open"), kThread, QStringLiteral("term-1"));
      return open && !folder.isEmpty() && open->value(QLatin1String("cwd")) == folder &&
             terminalfake::terminalWrites(world, QStringLiteral("term-1")) == QStringList{kCommand + QLatin1Char('\r')};
    }, [&] { return QStringLiteral("%1 in %2; the MC got %3").arg(kCommand, folder, terminalfake::describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the project's selected script is not changed"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(preferredScript(world) == world.mc.part<Before>().preferred,
           QStringLiteral("the project's script went from %1 to %2").arg(world.mc.part<Before>().preferred, preferredScript(world)));
  });
  step(QStringLiteral("the agent's reply has (a shell command still streaming|a shell command that spans several lines|an empty shell block|"
                      "a shell command ending in a backslash|a Python snippet) in a code block"),
       [](World& world, const Captures& c, const Table&) {
         if (c[0] == QLatin1String("a shell command still streaming")) replyWith(world, QStringLiteral("```bash\n") + kCommand + QStringLiteral("\n```"), true);
         else if (c[0] == QLatin1String("a shell command that spans several lines")) replyWith(world, QStringLiteral("```bash\nbun install\nbun test cart\n```"));
         else if (c[0] == QLatin1String("an empty shell block")) replyWith(world, QStringLiteral("```bash\n\n```"));
         else if (c[0] == QLatin1String("a shell command ending in a backslash")) replyWith(world, QStringLiteral("```bash\nbun test cart \\\n```"));
         else replyWith(world, QStringLiteral("```python\nprint(\"cart\")\n```"));
       });
  step(QStringLiteral("the code block offers no run action"), [](World& world, const Captures&, const Table&) {
    drawnReply(world);
    world.waitFor([&] { return !visible(world, QStringLiteral("copyCode")).isEmpty(); }, QStringLiteral("the code block to be drawn"));
    const qsizetype offered = visible(world, QStringLiteral("runCode")).size();
    expect(offered == 0, QStringLiteral("the code block offers Run %1 times").arg(offered));
  });

});

}  // namespace
