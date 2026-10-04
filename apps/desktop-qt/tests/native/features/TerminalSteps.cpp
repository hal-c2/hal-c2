// The native terminal drawer, and the MC's terminals behind it
// (features/terminal/drawer.feature).

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMap>

#include <optional>

#include "ComposerBrick.h"
#include "DraftController.h"
#include "NavigationController.h"
#include "TerminalController.h"
#include "FakeTerminals.h"
#include "Harness.h"
#include "World.h"

namespace terminalfake {

QString terminalKey(const QJsonObject& input) {
  return input.value(QLatin1String("threadId")).toString() + QLatin1Char('/') +
         input.value(QLatin1String("terminalId")).toString();
}

QJsonObject terminalSummary(const QString& threadId, const QString& terminalId, const QString& cwd) {
  return {
      {QStringLiteral("threadId"), threadId},
      {QStringLiteral("terminalId"), terminalId},
      {QStringLiteral("cwd"), cwd},
      {QStringLiteral("worktreePath"), QJsonValue::Null},
      {QStringLiteral("status"), QStringLiteral("running")},
      {QStringLiteral("pid"), 100},
      {QStringLiteral("exitCode"), QJsonValue::Null},
      {QStringLiteral("exitSignal"), QJsonValue::Null},
      {QStringLiteral("hasRunningSubprocess"), false},
      {QStringLiteral("label"), QString()},
      {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T10:00:00Z")},
  };
}

void sendTerminal(FakeMc& mc, const QString& key, const QJsonObject& event) {
  for (const int id : mc.subscribers(QStringLiteral("terminal"))) {
    if (terminalKey(mc.shapeOf(id).value(QLatin1String("input")).toObject()) != key) continue;
    mc.send({{QStringLiteral("t"), QStringLiteral("terminal")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), event}});
  }
}

// To the latest `terminals` subscription.
void sendTerminals(FakeMc& mc, const QJsonObject& event) {
  const QList<int> ids = mc.subscribers(QStringLiteral("terminals"));
  if (ids.isEmpty()) return;
  mc.send({{QStringLiteral("t"), QStringLiteral("terminals")}, {QStringLiteral("id"), ids.last()}, {QStringLiteral("event"), event}});
}

// A terminal the MC already runs, as another client left it.
void addTerminal(FakeMc& mc, const QString& threadId, const QString& terminalId, const QString& label, bool busy) {
  QJsonObject summary = terminalSummary(threadId, terminalId, QStringLiteral("/work"));
  summary.insert(QStringLiteral("label"), label);
  summary.insert(QStringLiteral("hasRunningSubprocess"), busy);
  mc.part<FakeTerminals>().terminals.insert(threadId + QLatin1Char('/') + terminalId, {summary, QString()});
  sendTerminals(mc, {{QStringLiteral("type"), QStringLiteral("upsert")}, {QStringLiteral("terminal"), summary}});
}

void print(FakeMc& mc, const QString& threadId, const QString& terminalId, const QString& data) {
  const QString key = threadId + QLatin1Char('/') + terminalId;
  mc.part<FakeTerminals>().terminals[key].history += data;
  sendTerminal(mc, key, {{QStringLiteral("type"), QStringLiteral("output")}, {QStringLiteral("data"), data}});
}

void closeTerminal(FakeMc& mc, const QString& threadId, const QString& terminalId) {
  const QString key = threadId + QLatin1Char('/') + terminalId;
  if (!mc.part<FakeTerminals>().terminals.remove(key)) return;
  sendTerminal(mc, key, {{QStringLiteral("type"), QStringLiteral("closed")}});
  sendTerminals(mc, {{QStringLiteral("type"), QStringLiteral("remove")},
                       {QStringLiteral("threadId"), threadId},
                       {QStringLiteral("terminalId"), terminalId}});
}

// The `terminal` subscriptions still attached, by terminal key.
QStringList attached(FakeMc& mc) {
  QStringList keys;
  for (const int id : mc.subscribers(QStringLiteral("terminal"))) {
    keys.append(terminalKey(mc.shapeOf(id).value(QLatin1String("input")).toObject()));
  }
  return keys;
}

// Opens the terminal when the input says where (as terminal.open does);
// returns false when it does not exist and cannot be opened.
bool ensureTerminal(FakeMc& mc, const QJsonObject& input) {
  FakeTerminals& fake = mc.part<FakeTerminals>();
  const QString key = terminalKey(input);
  if (fake.terminals.contains(key)) return true;
  if (!input.contains(QLatin1String("cwd")) || !fake.refuseOpen.isEmpty()) return false;
  const QJsonObject summary = terminalSummary(input.value(QLatin1String("threadId")).toString(),
                                              input.value(QLatin1String("terminalId")).toString(),
                                              input.value(QLatin1String("cwd")).toString());
  fake.terminals.insert(key, {summary, QString()});
  sendTerminals(mc, {{QStringLiteral("type"), QStringLiteral("upsert")}, {QStringLiteral("terminal"), summary}});
  return true;
}

}  // namespace terminalfake

namespace {

using namespace terminalfake;

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onShape(QStringLiteral("terminals"), [&mc](int id, const QJsonObject& shape) {
    // Only its own environment's list; another environment's goes to the MC serving it.
    if (shape.value(QLatin1String("environment")) != mc.environmentId) {
      mc.forget(id);
      return;
    }
    QJsonArray list;
    for (const FakeTerminals::Terminal& terminal : std::as_const(mc.part<FakeTerminals>().terminals)) {
      list.append(terminal.summary);
    }
    sendTerminals(mc, {{QStringLiteral("type"), QStringLiteral("snapshot")}, {QStringLiteral("terminals"), list}});
  });
  mc.onShape(QStringLiteral("terminal"), [&mc](int id, const QJsonObject& shape) {
    const QJsonObject input = shape.value(QLatin1String("input")).toObject();
    if (!ensureTerminal(mc, input)) {
      mc.forget(id);
      mc.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("Unknown terminal")}});
      return;
    }
    const FakeTerminals::Terminal& terminal = mc.part<FakeTerminals>().terminals[terminalKey(input)];
    QJsonObject snapshot = terminal.summary;
    snapshot.insert(QStringLiteral("history"), terminal.history);
    mc.send({{QStringLiteral("t"), QStringLiteral("terminal")},
               {QStringLiteral("id"), id},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("snapshot")}, {QStringLiteral("snapshot"), snapshot}}}});
  });
  mc.onRpc(QStringLiteral("terminal."), [&mc](const FakeMc::Rpc& rpc) {
    mc.part<FakeTerminals>().calls.append({{QStringLiteral("method"), rpc.method}, {QStringLiteral("payload"), rpc.payload}});
    if (rpc.method == QLatin1String("terminal.open")) {
      if (const QString refusal = mc.part<FakeTerminals>().refuseOpen; !refusal.isEmpty()) {
        mc.refuse(rpc, refusal);
        return;
      }
      ensureTerminal(mc, rpc.payload);
    }
    auto answer = [&mc, rpc] {
      if (!mc.current(rpc)) return;
      if (const QString refusal = mc.part<FakeTerminals>().refuseClose; rpc.method == QLatin1String("terminal.close") && !refusal.isEmpty()) {
        mc.refuse(rpc, refusal);
        return;
      }
      if (rpc.method == QLatin1String("terminal.close")) {
        closeTerminal(mc, rpc.payload.value(QLatin1String("threadId")).toString(),
                      rpc.payload.value(QLatin1String("terminalId")).toString());
      }
      mc.reply(rpc, QJsonValue::Null);
    };
    if (mc.holding(QStringLiteral("answers"))) {
      mc.defer(answer);
    } else {
      answer();
    }
  });
});

}  // namespace

namespace terminalfake {

// Gherkin cells and strings spell control characters as `\r` and `\n`.
QString unescaped(QString text) {
  return text.replace(QStringLiteral("\\r"), QStringLiteral("\r")).replace(QStringLiteral("\\n"), QStringLiteral("\n"));
}

QString tabLabels(World& world) {
  QStringList labels;
  for (const TerminalTabs::Row& row : world.native().controller<TerminalController>()->tabs()->rows()) labels.append(row.label);
  return labels.join(QStringLiteral(", "));
}

TerminalSession* terminalSession(World& world, const QString& terminalId) {
  for (const TerminalTabs::Row& row : world.native().controller<TerminalController>()->tabs()->rows()) {
    if (row.terminalId == terminalId) return row.session;
  }
  fail(QStringLiteral("no tab for %1; the tabs are %2").arg(terminalId, tabLabels(world)));
}

// The latest `terminal` subscription for the terminal: {type, environment, input}.
std::optional<QJsonObject> terminalShape(World& world, const QString& threadId, const QString& terminalId) {
  for (qsizetype index = world.mc.subscriptions.size() - 1; index >= 0; --index) {
    const QJsonObject shape = world.mc.subscriptions.at(index).value(QLatin1String("shape")).toObject();
    const QJsonObject input = shape.value(QLatin1String("input")).toObject();
    if (shape.value(QLatin1String("type")) == QLatin1String("terminal") &&
        input.value(QLatin1String("threadId")) == threadId && input.value(QLatin1String("terminalId")) == terminalId) {
      return shape;
    }
  }
  return std::nullopt;
}

std::optional<QJsonObject> terminalAttach(World& world, const QString& threadId, const QString& terminalId) {
  const auto shape = terminalShape(world, threadId, terminalId);
  if (!shape) return std::nullopt;
  return shape->value(QLatin1String("input")).toObject();
}

std::optional<QJsonObject> terminalCall(World& world, const QString& method, const QString& threadId,
                                        const QString& terminalId) {
  for (const QJsonObject& call : world.mc.part<FakeTerminals>().calls) {
    const QJsonObject payload = call.value(QLatin1String("payload")).toObject();
    if (call.value(QLatin1String("method")) == method && payload.value(QLatin1String("threadId")) == threadId &&
        payload.value(QLatin1String("terminalId")) == terminalId) {
      return payload;
    }
  }
  return std::nullopt;
}

QString describeTerminalCalls(World& world) {
  QStringList lines;
  for (const QJsonObject& call : world.mc.part<FakeTerminals>().calls) {
    lines.append(QString::fromUtf8(QJsonDocument(call).toJson(QJsonDocument::Compact)));
  }
  return lines.isEmpty() ? QStringLiteral("(none)") : lines.join(QStringLiteral("; "));
}

QStringList terminalWrites(World& world, const QString& terminalId) {
  QStringList writes;
  for (const QJsonObject& call : world.mc.part<FakeTerminals>().calls) {
    const QJsonObject payload = call.value(QLatin1String("payload")).toObject();
    if (call.value(QLatin1String("method")) == QLatin1String("terminal.write") &&
        payload.value(QLatin1String("terminalId")) == terminalId) {
      writes.append(payload.value(QLatin1String("data")).toString());
    }
  }
  return writes;
}

// A project action's id, as the settings' action editor makes it.
QString actionId(const QString& name) {
  return name.toLower();
}

void addAction(World& world, const QString& project, const QString& name, const QString& command) {
  QJsonObject row = world.mc.projects.value(project);
  QJsonArray scripts = row.value(QLatin1String("scripts")).toArray();
  scripts.append(QJsonObject{{QStringLiteral("id"), actionId(name)},
                             {QStringLiteral("name"), name},
                             {QStringLiteral("command"), command},
                             {QStringLiteral("icon"), QStringLiteral("play")},
                             {QStringLiteral("runOnWorktreeCreate"), false}});
  row.insert(QStringLiteral("scripts"), scripts);
  world.mc.projects.insert(project, row);
  QJsonArray rows;
  rows.append(QJsonArray{project, QStringLiteral("project"), row});
  world.mc.sendRows(world.mc.name, rows);
  world.sync();
}

// Shows a thread of the project, on a worktree when given one.
void showThread(World& world, const QString& project, const QString& worktree) {
  const QString threadId = QStringLiteral("thread-in-") + project;
  QJsonObject row{{QStringLiteral("id"), threadId}, {QStringLiteral("title"), QStringLiteral("Cart")}, {QStringLiteral("projectId"), project},
                  {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
  if (!worktree.isEmpty()) row.insert(QStringLiteral("worktreePath"), worktree);
  world.mc.threads.insert(threadId, row);
  world.mc.sendRow(threadId, row);
  const QString key = world.mc.environmentId + QLatin1Char(':') + threadId;
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return at(world.state(QStringLiteral("workspace")), QStringLiteral("threadKey")) == key; },
                [&] { return QStringLiteral("the header to show %1; it shows %2").arg(key, show(world.state(QStringLiteral("workspace")))); });
}

// The id of the thread the header shows.
QString shownThread(World& world) {
  const QString key = at(world.state(QStringLiteral("workspace")), QStringLiteral("threadKey")).toString();
  return key.mid(key.indexOf(QLatin1Char(':')) + 1);
}

// The thread the header shows, or one of the MC's first project shown now.
QString ensureThread(World& world) {
  // A draft the window landed on is not a thread yet.
  if (shownThread(world).isEmpty() || at(world.state(QStringLiteral("route")), QStringLiteral("kind")) != QLatin1String("thread")) {
    showThread(world, world.mc.projects.firstKey());
  }
  return shownThread(world);
}

// The drawer's (or the right panel's) terminals, in order.
QList<TerminalTabs::Row> rowsIn(World& world, bool panel) {
  QList<TerminalTabs::Row> rows;
  for (const TerminalTabs::Row& row : world.native().controller<TerminalController>()->tabs()->rows()) {
    if (row.panel == panel) rows.append(row);
  }
  return rows;
}

QString describeRows(World& world) {
  QStringList lines;
  for (const TerminalTabs::Row& row : world.native().controller<TerminalController>()->tabs()->rows()) {
    lines.append(QStringLiteral("%1 in %2%3 at %4/%5%6%7")
                     .arg(row.terminalId, row.panel ? QStringLiteral("panel ") : QString(), row.group)
                     .arg(row.slot)
                     .arg(row.span)
                     .arg(row.vertical ? QStringLiteral(" stacked") : QString(), row.current ? QStringLiteral(" current") : QString()));
  }
  return QStringLiteral("the terminals are ") + (lines.isEmpty() ? QStringLiteral("none") : lines.join(QStringLiteral("; ")));
}

// Whether `rows` are one group of `count` laid out side by side or stacked, in order.
bool oneGroup(const QList<TerminalTabs::Row>& rows, int count, bool vertical) {
  if (rows.size() != count) return false;
  for (int slot = 0; slot < count; ++slot) {
    const TerminalTabs::Row& row = rows.at(slot);
    if (row.group != rows.first().group || row.slot != slot || row.span != count || row.vertical != vertical) return false;
  }
  return true;
}

bool toastShown(World& world, const QString& title) {
  for (const QVariant& item : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
    if (item.toMap().value(QStringLiteral("title")) == title) return true;
  }
  return false;
}

// The MC's project "p1" at /work/p1, connected, unless a Background set one up.
void ensureProject(World& world) {
  if (world.mc.projects.isEmpty()) {
    world.mc.projects.insert(QStringLiteral("p1"), {{QStringLiteral("id"), QStringLiteral("p1")}, {QStringLiteral("title"), QStringLiteral("p1")},
                                                      {QStringLiteral("workspaceRoot"), QStringLiteral("/work/p1")}, {QStringLiteral("scripts"), QJsonArray()}});
  }
  if (world.shellSubscriptions() == 0) world.connect();
  world.sync();
}

}  // namespace terminalfake

namespace {

using namespace terminalfake;

const Steps steps([] {
  const QString q = kQuoted;

  // The terminal drawer.
  const auto terminals = [](World& world) { return world.native().controller<TerminalController>(); };
  step(QStringLiteral("the MC runs these terminals for %1:").arg(q), [](World& world, const Captures& c, const Table& table) {
    const QStringList& header = table.first();
    for (qsizetype row = 1; row < table.size(); ++row) {
      const QStringList& cells = table.at(row);
      addTerminal(world.mc, c[0], cells.value(header.indexOf(QStringLiteral("terminal"))),
                             header.contains(QStringLiteral("label")) ? cells.value(header.indexOf(QStringLiteral("label"))) : QString(),
                             header.contains(QStringLiteral("busy")) && cells.value(header.indexOf(QStringLiteral("busy"))) == QLatin1String("yes"));
    }
    world.sync();
  });
  step(QStringLiteral("the MC prints %1 in %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    print(world.mc, c[2], c[1], unescaped(c[0]));
    world.sync();
  });
  step(QStringLiteral("the MC closes %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    closeTerminal(world.mc, c[1], c[0]);
    world.sync();
  });
  step(QStringLiteral("the user toggles the terminal drawer"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.sync();  // what it asked of the MC has been answered
  });
  step(QStringLiteral("the user opens a new terminal"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.new"));
    world.sync();  // what it asked of the MC has been answered
  });
  step(QStringLiteral("the user selects %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.select"), QVariantMap{{QStringLiteral("terminalId"), c[0]}});
    world.sync();  // what it asked of the MC has been answered
  });
  step(QStringLiteral("the user closes the active terminal"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.close"));
    world.sync();  // what it asked of the MC has been answered
  });
  step(QStringLiteral("the user runs the script %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("workspace.runScript"), QVariantMap{{QStringLiteral("scriptId"), c[0]}});
    world.sync();  // what it asked of the MC has been answered
  });

  // Project actions (files/project-scripts-and-actions.feature): the header's
  // action menu runs them in the drawer.
  step(QStringLiteral("%1 has the action %1 running %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addAction(world, c[0], c[1], c[2]);
  });
  step(QStringLiteral("%1 also has the action %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addAction(world, c[0], c[1], QStringLiteral("bun ") + c[1].toLower());
  });
  step(QStringLiteral("the user is looking at a thread in %1 on a worktree").arg(q), [](World& world, const Captures& c, const Table&) {
    showThread(world, c[0], QStringLiteral("/work/") + c[0] + QStringLiteral("-wt"));
  });
  step(QStringLiteral("the thread's terminal is running a command"), [](World& world, const Captures&, const Table&) {
    const QString threadId = ensureThread(world);
    addTerminal(world.mc, threadId, QStringLiteral("term-1"), QString(), true);
    world.sync();
  });
  step(QStringLiteral("terminals cannot be opened for the thread"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeTerminals>().refuseOpen = QStringLiteral("Terminal limit reached on this machine");
  });
  step(QStringLiteral("the user runs the action %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureThread(world);
    world.bridge().dispatch(QStringLiteral("workspace.runScript"), QVariantMap{{QStringLiteral("scriptId"), actionId(c[0])}});
    world.sync();  // what it asked of the MC has been answered
  });
  step(QStringLiteral("a terminal in the worktree runs %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString worktree = at(world.state(QStringLiteral("workspace")), QStringLiteral("worktreePath")).toString();
    const QString threadId = shownThread(world);
    world.waitFor([&] {
      const auto open = terminalCall(world, QStringLiteral("terminal.open"), threadId, QStringLiteral("term-1"));
      return open && open->value(QLatin1String("cwd")) == worktree && terminalWrites(world, QStringLiteral("term-1")) == QStringList{c[0] + QLatin1Char('\r')};
    }, [&] { return QStringLiteral("%1 in %2; the MC got %3").arg(c[0], worktree, describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the command knows the project folder and the worktree folder"), [](World& world, const Captures&, const Table&) {
    const QVariant workspace = world.state(QStringLiteral("workspace"));
    const auto open = terminalCall(world, QStringLiteral("terminal.open"), shownThread(world), QStringLiteral("term-1"));
    expect(open.has_value(), QStringLiteral("the MC got %1").arg(describeTerminalCalls(world)));
    const QJsonObject env = open->value(QLatin1String("env")).toObject();
    expect(env.value(QLatin1String("HAL_C2_PROJECT_ROOT")).toString() == at(workspace, QStringLiteral("projectRoot")).toString() &&
               env.value(QLatin1String("HAL_C2_WORKTREE_PATH")).toString() == at(workspace, QStringLiteral("worktreePath")).toString(),
           QStringLiteral("the command starts with %1").arg(QString::fromUtf8(QJsonDocument(env).toJson(QJsonDocument::Compact))));
  });
  step(QStringLiteral("%1 runs in a new terminal").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      return terminalCall(world, QStringLiteral("terminal.open"), shownThread(world), QStringLiteral("term-2")) &&
             terminalWrites(world, QStringLiteral("term-2")) == QStringList{c[0] + QLatin1Char('\r')};
    }, [&] { return QStringLiteral("%1 in term-2; the MC got %2").arg(c[0], describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the busy terminal keeps running"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QString threadId = shownThread(world);
    expect(!terminalCall(world, QStringLiteral("terminal.close"), threadId, QStringLiteral("term-1")) && terminalWrites(world, QStringLiteral("term-1")).isEmpty() &&
               world.mc.part<FakeTerminals>().terminals.contains(threadId + QStringLiteral("/term-1")),
           QStringLiteral("the MC got %1").arg(describeTerminalCalls(world)));
  });
  step(QStringLiteral("%1 is offered first the next time the user runs an action in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QVariant workspace = world.state(QStringLiteral("workspace"));
    expect(at(workspace, QStringLiteral("projectTitle")) == c[1] && at(workspace, QStringLiteral("preferredScriptId")) == actionId(c[0]),
           QStringLiteral("the header shows %1").arg(show(workspace)));
  });
  step(QStringLiteral("the user is told the action %1 failed to run").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString title = QStringLiteral("Failed to run script \"%1\".").arg(c[0]);
    const auto shown = [&] {
      for (const QVariant& item : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
        if (item.toMap().value(QStringLiteral("title")) == title) return true;
      }
      return false;
    };
    world.waitFor(shown, [&] { return QStringLiteral("the toast %1; the shell shows %2").arg(title, show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("the user types %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    terminalSession(world, c[1])->write(unescaped(c[0]));
  });
  step(QStringLiteral("the terminal drawer is unavailable"), [terminals](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!terminals(world)->available(), QStringLiteral("the terminal drawer is available"));
  });
  step(QStringLiteral("the terminal drawer is closed"), [terminals](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !terminals(world)->isOpen(); }, QStringLiteral("the terminal drawer to close"));
  });
  step(QStringLiteral("the terminal drawer shows the tabs %1").arg(q), [terminals](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return terminals(world)->isOpen() && tabLabels(world) == c[0]; },
                  [&] { return QStringLiteral("the tabs %1; the drawer is %2 with %3").arg(c[0], terminals(world)->isOpen() ? QStringLiteral("open") : QStringLiteral("closed"), tabLabels(world)); });
  });
  step(QStringLiteral("the active terminal is %1").arg(q), [terminals](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return terminals(world)->activeTerminalId() == c[0]; },
                  [&] { return QStringLiteral("%1 to be active; it is %2").arg(c[0], terminals(world)->activeTerminalId()); });
  });
  step(QStringLiteral("the MC attaches %1 of %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const auto input = terminalAttach(world, c[1], c[0]);
      return input && input->value(QLatin1String("cwd")) == c[2];
    }, QStringLiteral("%1 of %2 to attach in %3").arg(c[0], c[1], c[2]));
  });
  step(QStringLiteral("the MC attaches %1 of the new thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto draft = world.native().controller<DraftController>()->draft(world.draftId);
    expect(draft.has_value(), QStringLiteral("the window shows no new thread"));
    world.waitFor([&] {
      const auto input = terminalAttach(world, draft->threadId, c[0]);
      return input && input->value(QLatin1String("cwd")) == c[1];
    }, QStringLiteral("%1 of the new thread to attach in %2").arg(c[0], c[1]));
  });
  step(QStringLiteral("%1 attaches %1 of %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const auto shape = terminalShape(world, c[2], c[1]);
      return shape && shape->value(QLatin1String("environment")) == c[0] &&
             shape->value(QLatin1String("input")).toObject().value(QLatin1String("cwd")) == c[3];
    }, [&] {
      const auto shape = terminalShape(world, c[2], c[1]);
      return QStringLiteral("%1 to attach %2 of %3 in %4; got %5").arg(c[0], c[1], c[2], c[3], shape ? QString::fromUtf8(QJsonDocument(*shape).toJson(QJsonDocument::Compact)) : QStringLiteral("nothing"));
    });
  });
  step(QStringLiteral("%1 of %1 starts with %1 set to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto input = terminalAttach(world, c[1], c[0]);
    expect(input.has_value(), QStringLiteral("%1 of %2 never attached").arg(c[0], c[1]));
    const QString value = input->value(QLatin1String("env")).toObject().value(c[2]).toString();
    expect(value == c[3], QStringLiteral("%1 is \"%2\"").arg(c[2], value));
  });
  step(QStringLiteral("%1 of %1 is still attached").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(attached(world.mc).contains(c[1] + QLatin1Char('/') + c[0]), QStringLiteral("%1 of %2 was let go").arg(c[0], c[1]));
  });
  step(QStringLiteral("the MC is asked to open %1 of %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const auto payload = terminalCall(world, QStringLiteral("terminal.open"), c[1], c[0]);
      return payload && payload->value(QLatin1String("cwd")) == c[2];
    }, [&] { return QStringLiteral("terminal.open; the MC got %1").arg(describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the MC is not asked to open a terminal"), [](World& world, const Captures&, const Table&) {
    world.sync();
    for (const QJsonObject& call : world.mc.part<FakeTerminals>().calls) {
      expect(call.value(QLatin1String("method")) != QLatin1String("terminal.open"), QStringLiteral("the MC got %1").arg(describeTerminalCalls(world)));
    }
  });
  step(QStringLiteral("the MC is asked to close %1 of %1 and delete its history").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const auto payload = terminalCall(world, QStringLiteral("terminal.close"), c[1], c[0]);
      return payload && payload->value(QLatin1String("deleteHistory")).toBool();
    }, [&] { return QStringLiteral("terminal.close; the MC got %1").arg(describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the MC receives these writes to %1:").arg(q), [](World& world, const Captures& c, const Table& table) {
    QStringList wanted;
    for (qsizetype row = 1; row < table.size(); ++row) wanted.append(unescaped(table.at(row).value(0)));
    world.waitFor([&] { return terminalWrites(world, c[0]).size() >= wanted.size(); },
                  [&] { return QStringLiteral("%1 writes; the MC got %2").arg(wanted.size()).arg(describeTerminalCalls(world)); });
    world.sync();
    expect(terminalWrites(world, c[0]) == wanted, QStringLiteral("the MC got %1").arg(describeTerminalCalls(world)));
  });
  step(QStringLiteral("%1 shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (modelPickerShows(world, c[0], c[1])) return;
    const QString transcript = terminalSession(world, c[0])->transcript();
    expect(transcript.contains(unescaped(c[1])), QStringLiteral("%1 shows \"%2\"").arg(c[0], transcript));
  });
  // Split groups (terminal/tabs.feature).
  step(QStringLiteral("the thread's terminal is open with one terminal"), [terminals](World& world, const Captures&, const Table&) {
    ensureProject(world);
    ensureThread(world);
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([&] { return terminals(world)->isOpen() && rowsIn(world, false).size() == 1; }, [&] { return describeRows(world); });
  });
  step(QStringLiteral("the user splits the terminal (horizontally|vertically)"), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(c[0] == QLatin1String("vertically") ? QStringLiteral("terminal.splitVertical") : QStringLiteral("terminal.split"));
    world.sync();
  });
  step(QStringLiteral("a second terminal runs next to the first (side by side|stacked)"), [terminals](World& world, const Captures& c, const Table&) {
    const bool stacked = c[0] == QLatin1String("stacked");
    const QString threadId = shownThread(world);
    world.waitFor([&] {
      const QList<TerminalTabs::Row> rows = rowsIn(world, false);
      return oneGroup(rows, 2, stacked) && rows.at(1).current && terminals(world)->activeTerminalId() == rows.at(1).terminalId &&
             terminalAttach(world, threadId, rows.at(1).terminalId).has_value();
    }, [&] { return describeRows(world); });
  });
  step(QStringLiteral("a split group with four terminals"), [terminals](World& world, const Captures&, const Table&) {
    ensureProject(world);
    ensureThread(world);
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([&] { return rowsIn(world, false).size() == 1; }, [&] { return describeRows(world); });
    for (int count = 2; count <= 4; ++count) {
      world.bridge().dispatch(QStringLiteral("terminal.split"));
      world.waitFor([&] { return rowsIn(world, false).size() == count; }, [&] { return describeRows(world); });
    }
    expect(oneGroup(rowsIn(world, false), 4, false) && terminals(world)->groupSizes().value(terminals(world)->activeGroup()) == 4, describeRows(world));
  });
  step(QStringLiteral("the user cannot split that group again"), [terminals](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.split"));
    world.bridge().dispatch(QStringLiteral("terminal.splitVertical"));
    world.sync();
    expect(oneGroup(rowsIn(world, false), 4, false) && terminals(world)->groupSizes().value(terminals(world)->activeGroup()) == 4, describeRows(world));
  });
  step(QStringLiteral("the user is told the limit is 4 per group"), [](World& world, const Captures&, const Table&) {
    const QString title = QStringLiteral("At most 4 terminals per group.");
    world.waitFor([&] { return toastShown(world, title); },
                  [&] { return QStringLiteral("the toast %1; the shell shows %2").arg(title, show(world.state(QStringLiteral("toasts")))); });
  });

  // The header's terminal button (navigation/layout.feature), Workspace.qml's terminal.toggle.
  step(QStringLiteral("the terminal is (hidden|shown)"), [terminals](World& world, const Captures& c, const Table&) {
    ensureThread(world);
    if (c[0] == QLatin1String("shown")) world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([&] { return terminals(world)->available() && terminals(world)->isOpen() == (c[0] == QLatin1String("shown")) &&
                               (c[0] == QLatin1String("hidden") || rowsIn(world, false).size() == 1); },
                  [&] { return describeRows(world); });
  });
  step(QStringLiteral("the user (?:shows|hides) the terminal"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.sync();
  });
  step(QStringLiteral("the terminal drawer opens under the thread"), [terminals](World& world, const Captures&, const Table&) {
    const QString threadId = shownThread(world);
    world.waitFor([&] { return terminals(world)->isOpen() && terminals(world)->threadKey().endsWith(QLatin1Char(':') + threadId) &&
                               terminalAttach(world, threadId, QStringLiteral("term-1")).has_value(); },
                  [&] { return describeRows(world); });
  });
  step(QStringLiteral("the terminal drawer closes"), [terminals](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !terminals(world)->isOpen(); }, QStringLiteral("the terminal drawer to close"));
  });
  step(QStringLiteral("its terminals keep running"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QString threadId = shownThread(world);
    expect(!terminalCall(world, QStringLiteral("terminal.close"), threadId, QStringLiteral("term-1")) &&
               attached(world.mc).contains(threadId + QStringLiteral("/term-1")) && rowsIn(world, false).size() == 1,
           describeRows(world) + QStringLiteral("; the MC got ") + describeTerminalCalls(world));
  });

  // Right panel terminal tabs (terminal/tabs.feature, navigation/layout.feature).
  const auto addPanelTab = [](World& world) {
    world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("terminal")}});
    world.waitFor([&] { return rowsIn(world, true).size() == 1; }, [&] { return describeRows(world); });
    world.mc.part<FakeTerminals>().panelTerminal = rowsIn(world, true).first().terminalId;
  };
  step(QStringLiteral("the terminal tab runs a terminal of its own"), [](World& world, const Captures&, const Table&) {
    const QString threadId = shownThread(world);
    world.waitFor([&] {
      const QList<TerminalTabs::Row> rows = rowsIn(world, true);
      return rows.size() == 1 && at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")) == QStringLiteral("terminal:") + rows.first().group &&
             terminalAttach(world, threadId, rows.first().terminalId).has_value();
    }, [&] { return describeRows(world) + QStringLiteral("; the panel shows ") + show(world.state(QStringLiteral("panel"))); });
    world.mc.part<FakeTerminals>().panelTerminal = rowsIn(world, true).first().terminalId;
  });
  step(QStringLiteral("the terminal drawer still shows only its first terminal"), [terminals](World& world, const Captures&, const Table&) {
    world.sync();
    const QList<TerminalTabs::Row> rows = rowsIn(world, false);
    expect(terminals(world)->isOpen() && rows.size() == 1 && rows.first().terminalId == QStringLiteral("term-1") &&
               terminals(world)->activeTerminalId() == QStringLiteral("term-1"),
           describeRows(world));
  });
  step(QStringLiteral("the thread has a terminal tab in the right panel"), [addPanelTab](World& world, const Captures&, const Table&) {
    ensureProject(world);
    ensureThread(world);
    addPanelTab(world);
  });
  step(QStringLiteral("the user closes the terminal tab"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("rightPanel.close"), QVariantMap{{QStringLiteral("id"), at(world.state(QStringLiteral("panel")), QStringLiteral("activeId"))}});
    world.sync();
  });
  step(QStringLiteral("the tab's terminal stops and its history is deleted"), [](World& world, const Captures&, const Table&) {
    const QString terminalId = world.mc.part<FakeTerminals>().panelTerminal;
    world.waitFor([&] {
      const auto payload = terminalCall(world, QStringLiteral("terminal.close"), shownThread(world), terminalId);
      return payload && payload->value(QLatin1String("deleteHistory")).toBool() && rowsIn(world, true).isEmpty();
    }, [&] { return describeRows(world) + QStringLiteral("; the MC got ") + describeTerminalCalls(world); });
    for (const QVariant& tab : at(world.state(QStringLiteral("panel")), QStringLiteral("tabs")).toList()) {
      expect(at(tab, QStringLiteral("kind")) != QStringLiteral("terminal"), show(world.state(QStringLiteral("panel"))));
    }
  });
  step(QStringLiteral("the user splits the terminal tab (horizontally|vertically)"), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(c[0] == QLatin1String("vertically") ? QStringLiteral("terminal.splitVertical") : QStringLiteral("terminal.split"),
                            QVariantMap{{QStringLiteral("terminalId"), world.mc.part<FakeTerminals>().panelTerminal}});
    world.sync();
  });
  step(QStringLiteral("the terminal tab shows two terminals (side by side|stacked)"), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return oneGroup(rowsIn(world, true), 2, c[0] == QLatin1String("stacked")); }, [&] { return describeRows(world); });
    expect(at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")) == QStringLiteral("terminal:") + rowsIn(world, true).first().group,
           show(world.state(QStringLiteral("panel"))));
  });
  step(QStringLiteral("the terminal drawer shows none of the tab's terminals"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QList<TerminalTabs::Row> panel = rowsIn(world, true);
    for (const TerminalTabs::Row& row : rowsIn(world, false)) {
      for (const TerminalTabs::Row& other : panel) expect(row.terminalId != other.terminalId && row.group != other.group, describeRows(world));
    }
  });
  step(QStringLiteral("a terminal tab in the right panel has output"), [addPanelTab](World& world, const Captures&, const Table&) {
    addPanelTab(world);
    const QString threadId = shownThread(world);
    const QString terminalId = world.mc.part<FakeTerminals>().panelTerminal;
    world.waitFor([&] { return attached(world.mc).contains(threadId + QLatin1Char('/') + terminalId); }, [&] { return describeRows(world); });
    print(world.mc, threadId, terminalId, QStringLiteral("built in 3s\r\n"));
    world.waitFor([&] { return terminalSession(world, terminalId)->transcript().contains(QStringLiteral("built in 3s")); },
                  [&] { return QStringLiteral("%1 shows \"%2\"").arg(terminalId, terminalSession(world, terminalId)->transcript()); });
  });
  step(QStringLiteral("the user closes the right panel and opens it again"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("rightPanel.toggle"));
    world.sync();
    expect(!at(world.state(QStringLiteral("panel")), QStringLiteral("isOpen")).toBool(), show(world.state(QStringLiteral("panel"))));
    world.bridge().dispatch(QStringLiteral("rightPanel.toggle"));
    world.sync();
  });
  step(QStringLiteral("the terminal tab still has its output"), [](World& world, const Captures&, const Table&) {
    const QString threadId = shownThread(world);
    const QString terminalId = world.mc.part<FakeTerminals>().panelTerminal;
    const QList<TerminalTabs::Row> rows = rowsIn(world, true);
    expect(rows.size() == 1 && rows.first().terminalId == terminalId && at(world.state(QStringLiteral("panel")), QStringLiteral("isOpen")).toBool() &&
               at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")) == QStringLiteral("terminal:") + rows.first().group,
           describeRows(world) + QStringLiteral("; the panel shows ") + show(world.state(QStringLiteral("panel"))));
    expect(!terminalCall(world, QStringLiteral("terminal.close"), threadId, terminalId) && attached(world.mc).contains(threadId + QLatin1Char('/') + terminalId) &&
               terminalSession(world, terminalId)->transcript().contains(QStringLiteral("built in 3s")),
           QStringLiteral("the MC got %1").arg(describeTerminalCalls(world)));
  });

  // navigation/layout.feature's header: the run button runs the action the
  // user ran last in the project (or its first), its menu any of them.
  const auto shownProject = [](World& world) {
    return world.mc.threads.value(ensureThread(world)).value(QLatin1String("projectId")).toString();
  };
  step(QStringLiteral("the thread's project has the actions %1 and %1").arg(q), [shownProject](World& world, const Captures& c, const Table&) {
    const QString project = shownProject(world);
    for (const QString& name : c) addAction(world, project, name, QStringLiteral("bun ") + name.toLower());
  });
  step(QStringLiteral("the thread's project has no actions"), [shownProject](World& world, const Captures&, const Table&) {
    expect(world.mc.projects.value(shownProject(world)).value(QLatin1String("scripts")).toArray().isEmpty(), QStringLiteral("the project has actions"));
  });
  step(QStringLiteral("the user last ran %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("workspace.runScript"), QVariantMap{{QStringLiteral("scriptId"), actionId(c[0])}});
    world.sync();
    world.mc.part<FakeTerminals>().calls.clear();
  });
  step(QStringLiteral("the user runs the action offered in the header"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariantMap workspace = world.state(QStringLiteral("workspace")).toMap();
    const QVariantList scripts = workspace.value(QStringLiteral("scripts")).toList();
    expect(!scripts.isEmpty(), QStringLiteral("the header offers no action: %1").arg(show(workspace)));
    // Workspace.preferredScript: the one last run, else the first.
    const QVariant preferred = workspace.value(QStringLiteral("preferredScriptId"));
    const QString scriptId = preferred.isNull() ? scripts.first().toMap().value(QStringLiteral("id")).toString() : preferred.toString();
    world.bridge().dispatch(QStringLiteral("workspace.runScript"), QVariantMap{{QStringLiteral("scriptId"), scriptId}});
    world.sync();
  });
  step(QStringLiteral("the user picks %1 from the header's actions").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("workspace.runScript"), QVariantMap{{QStringLiteral("scriptId"), actionId(c[0])}});
    world.sync();
  });
  step(QStringLiteral("%1 runs for the thread's workspace").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString command = QStringLiteral("bun ") + c[0].toLower() + QLatin1Char('\r');
    const QVariantMap workspace = world.state(QStringLiteral("workspace")).toMap();
    const QString folder = workspace.value(QStringLiteral("worktreePath")).toString().isEmpty() ? workspace.value(QStringLiteral("projectRoot")).toString()
                                                                                                 : workspace.value(QStringLiteral("worktreePath")).toString();
    const QString threadId = shownThread(world);
    world.waitFor([&] {
      QStringList written;
      for (const QJsonObject& call : world.mc.part<FakeTerminals>().calls) {
        const QJsonObject payload = call.value(QLatin1String("payload")).toObject();
        if (call.value(QLatin1String("method")) != QLatin1String("terminal.write")) continue;
        const QString cwd = world.mc.part<FakeTerminals>().terminals.value(terminalKey(payload)).summary.value(QLatin1String("cwd")).toString();
        if (payload.value(QLatin1String("threadId")) == threadId && cwd == folder) written.append(payload.value(QLatin1String("data")).toString());
      }
      return written == QStringList{command};
    }, [&] { return QStringLiteral("only %1 in %2; the MC got %3").arg(command.trimmed(), folder, describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the header offers no action to run"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariantMap workspace = world.state(QStringLiteral("workspace")).toMap();
    expect(!workspace.isEmpty() && workspace.value(QStringLiteral("scripts")).toList().isEmpty(), QStringLiteral("the header shows %1").arg(show(workspace)));
  });
});

// Who gets the keyboard when a terminal appears (navigation/focus.feature):
// TerminalDrawer focuses a terminal only when the controller asks
// (focusRequested), which it does for what the user opens.
struct TerminalFocus {
  QStringList requested;
  QString thread;
};

const Steps focusSteps([] {
  step(QStringLiteral("the user is typing in the composer"), [](World& world, const Captures&, const Table&) {
    ensureProject(world);
    TerminalFocus& focus = world.mc.part<TerminalFocus>();
    focus.thread = ensureThread(world);
    auto* terminals = world.native().controller<TerminalController>();
    world.waitFor([terminals] { return terminals->available(); }, QStringLiteral("the thread's terminal drawer"));
    QObject::connect(terminals, &TerminalController::focusRequested, terminals, [&focus](const QString& id) { focus.requested.append(id); });
    world.bridge().dispatch(QStringLiteral("composer.text.set"),
                            QVariantMap{{QStringLiteral("target"), world.mc.environmentId + QLatin1Char(':') + focus.thread},
                                        {QStringLiteral("text"), QStringLiteral("Add tax to")}, {QStringLiteral("cursor"), 10}});
  });
  step(QStringLiteral("a terminal starts on its own"), [](World& world, const Captures&, const Table&) {
    // One the agent or a setup script started: the MC lists it.
    addTerminal(world.mc, world.mc.part<TerminalFocus>().thread, QStringLiteral("term-agent"), QStringLiteral("bun dev"), true);
    world.sync();
  });
  step(QStringLiteral("the composer keeps keyboard focus"), [](World& world, const Captures&, const Table&) {
    const TerminalFocus& focus = world.mc.part<TerminalFocus>();
    auto* terminals = world.native().controller<TerminalController>();
    // The drawer stays as it was and nothing asks for the keyboard.
    expect(focus.requested.isEmpty() && !terminals->isOpen(),
           QStringLiteral("the terminal asked for the keyboard: %1 (drawer open: %2)").arg(focus.requested.join(QStringLiteral(", "))).arg(terminals->isOpen()));
    // Unlike when the user opens the drawer, which shows that terminal and focuses it.
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.waitFor([terminals] { return terminals->isOpen() && terminals->tabs()->rowCount() == 1; },
                  [&] { return QStringLiteral("the terminal to be listed; %1").arg(describeRows(world)); });
    expect(focus.requested == QStringList{QStringLiteral("term-agent")}, QStringLiteral("opening it focused %1").arg(focus.requested.join(QStringLiteral(", "))));
  });
});

}  // namespace
