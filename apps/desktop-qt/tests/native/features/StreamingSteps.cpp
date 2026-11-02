// What a turn shows while and after it streams (features/timeline/streaming.feature):
// the working timer before the agent begins, how durations are written, which
// messages of the user's are shortened, a reply with no text, and a reply's
// shell command run from its code block in the thread's terminal. The stream
// is Stream.h's; the rows are read from the Timeline brick drawing it, wired
// as ThreadView wires it.

#include <QJsonObject>
#include <QQuickItem>
#include <QRegularExpression>
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
  const QString q = kQuoted;

  // The working timer counts from the message (deriveActiveWorkStartedAt).
  step(QStringLiteral("the user sent a message and the agent's session is still starting"), [](World& world, const Captures&, const Table&) {
    const QString run = startRun(world, -1, QStringLiteral("starting"));
    set(world, QStringLiteral("run"), run, {{QStringLiteral("requestedAt"), iso(now().addSecs(-12))}});
  });
  step(QStringLiteral("the agent has not yet begun the turn"), [](World& world, const Captures&, const Table&) {
    const QJsonObject run = world.mc.part<FakeStreams>().threads.value(kThread).value(QStringLiteral("run\n") + world.mc.part<FakeStreams>().run);
    expect(!run.contains(QLatin1String("startedAt")), QStringLiteral("the run began at %1").arg(run.value(QLatin1String("startedAt")).toString()));
  });
  step(QStringLiteral("the elapsed time counts from when the message was sent"), [](World& world, const Captures&, const Table&) {
    const QDateTime since = timeline(world).workingSince();
    expect(since == now().addSecs(-12), QStringLiteral("the timer counts from %1").arg(iso(since)));
  });
  step(QStringLiteral("it does not disappear and come back when the agent begins"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const QDateTime since = model.workingSince();
    bool stopped = false;
    const QMetaObject::Connection watch = QObject::connect(&model, &TimelineModel::workingChanged, [&] { stopped = stopped || !model.working(); });
    set(world, QStringLiteral("run"), world.mc.part<FakeStreams>().run, {{QStringLiteral("status"), QStringLiteral("running")}, {QStringLiteral("startedAt"), iso(now().addSecs(-2))}});
    QObject::disconnect(watch);
    expect(!stopped && model.working(), QStringLiteral("the thread stopped saying the agent is working"));
    expect(model.workingSince() == since, QStringLiteral("the timer moved from %1 to %2").arg(iso(since), iso(model.workingSince())));
    expect(model.workingLabel() == QLatin1String("Working for 12s"), QStringLiteral("the thread says \"%1\"").arg(model.workingLabel()));
  });

  // Durations (formatDuration).
  step(QStringLiteral("the thread shows a duration of (.+)"), [](World& world, const Captures& c, const Table&) {
    static const QRegularExpression part(QStringLiteral("([\\d.]+) (millisecond|second|minute|hour)s?"));
    double ms = 0;
    for (auto it = part.globalMatch(c[0]); it.hasNext();) {
      const QRegularExpressionMatch match = it.next();
      const double amount = match.captured(1).toDouble();
      const QString unit = match.captured(2);
      ms += amount * (unit == QLatin1String("millisecond") ? 1 : unit == QLatin1String("second") ? 1000 : unit == QLatin1String("minute") ? 60000 : 3600000);
    }
    world.mc.part<ShownDuration>() = {true, TimelineModel::durationText(qint64(std::llround(ms)))};
  });

  // Which messages of the user's are shortened (shouldCollapseUserMessage).
  step(QStringLiteral("the user sent a message of (.+)"), [](World& world, const Captures& c, const Table&) {
    QString text;
    if (c[0] == QLatin1String("600 characters on one line")) text = QString(600, QLatin1Char('a'));
    else if (c[0] == QLatin1String("601 characters on one line")) text = QString(601, QLatin1Char('a'));
    else if (c[0] == QLatin1String("8 short lines")) text = QStringList(8, QStringLiteral("line")).join(QLatin1Char('\n'));
    else if (c[0] == QLatin1String("9 short lines")) text = QStringList(9, QStringLiteral("line")).join(QLatin1Char('\n'));
    else if (c[0] == QLatin1String("only spaces and blank lines")) text = QStringLiteral("   \n\n  \n\n\n\n\n\n\n\n   ") + QString(600, QLatin1Char(' '));
    else fail(QStringLiteral("no message of %1").arg(c[0]));
    const QString run = startRun(world, 30);
    set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run, {{QStringLiteral("text"), text}});
    settleRun(world, QStringLiteral("completed"), 30);
  });
  step(QStringLiteral("the user looks at it in the conversation"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return visible(world, QStringLiteral("userMessageBody")).size() == 1; },
                  [&] { return QStringLiteral("the message to be drawn; %1").arg(describe(timeline(world))); });
  });
  step(QStringLiteral("it is (shown in full|shortened)"), [](World& world, const Captures& c, const Table&) {
    const bool collapsed = visible(world, QStringLiteral("userMessageBody")).constFirst()->property("collapsed").toBool();
    expect(collapsed == (c[0] == QLatin1String("shortened")), QStringLiteral("the message is %1").arg(collapsed ? QStringLiteral("shortened") : QStringLiteral("shown in full")));
  });

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

  // A reply with no text.
  step(QStringLiteral("the agent's turn ended with a reply that has no text"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QString()}});
    settleRun(world, QStringLiteral("completed"), 30);
  });
  step(QStringLiteral("the reply reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* reply = drawnReply(world);
    expect(reply->property("text").toString() == c[0], QStringLiteral("the reply reads \"%1\"").arg(reply->property("text").toString()));
    world.waitFor([&] { return timelineBrick(world).shows(c[0]) || reply->property("segmentCount").toInt() > 0; },
                  QStringLiteral("the reply to draw \"%1\"").arg(c[0]));
  });
  step(QStringLiteral("the agent has started a reply and written nothing yet"), [](World& world, const Captures&, const Table&) {
    startRun(world, 5);
    addItem(world, QStringLiteral("assistant_message"),
            {{QStringLiteral("text"), QString()}, {QStringLiteral("streaming"), true}, {QStringLiteral("status"), QStringLiteral("running")}});
  });
  step(QStringLiteral("the reply shows no text and no %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* reply = drawnReply(world);
    expect(reply->property("text").toString().isEmpty(), QStringLiteral("the reply reads \"%1\"").arg(reply->property("text").toString()));
    expect(!timelineBrick(world).shows(c[0]), QStringLiteral("the timeline shows \"%1\"").arg(c[0]));
  });
});

}  // namespace
