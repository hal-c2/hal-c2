// The native terminal drawer, and the node's terminals behind it
// (features/desktop/native-terminal.feature).

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMap>

#include <optional>

#include "TerminalController.h"
#include "Harness.h"
#include "World.h"

namespace {

// The node's terminal manager: terminals attach with the `terminal` shape and
// are listed by `terminals`; `terminal.*` calls are recorded and act on them
// the way the node's does.
struct FakeTerminals {
  struct Terminal {
    QJsonObject summary;
    QString history;
  };
  // By "threadId/terminalId".
  QMap<QString, Terminal> terminals;
  // Every terminal.* call, as {method, payload}.
  QList<QJsonObject> calls;
};

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

void sendTerminal(FakeNode& node, const QString& key, const QJsonObject& event) {
  for (const int id : node.subscribers(QStringLiteral("terminal"))) {
    if (terminalKey(node.shapeOf(id).value(QLatin1String("input")).toObject()) != key) continue;
    node.send({{QStringLiteral("t"), QStringLiteral("terminal")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), event}});
  }
}

// To the latest `terminals` subscription.
void sendTerminals(FakeNode& node, const QJsonObject& event) {
  const QList<int> ids = node.subscribers(QStringLiteral("terminals"));
  if (ids.isEmpty()) return;
  node.send({{QStringLiteral("t"), QStringLiteral("terminals")}, {QStringLiteral("id"), ids.last()}, {QStringLiteral("event"), event}});
}

// A terminal the node already runs, as another client left it.
void addTerminal(FakeNode& node, const QString& threadId, const QString& terminalId, const QString& label, bool busy) {
  QJsonObject summary = terminalSummary(threadId, terminalId, QStringLiteral("/work"));
  summary.insert(QStringLiteral("label"), label);
  summary.insert(QStringLiteral("hasRunningSubprocess"), busy);
  node.part<FakeTerminals>().terminals.insert(threadId + QLatin1Char('/') + terminalId, {summary, QString()});
  sendTerminals(node, {{QStringLiteral("type"), QStringLiteral("upsert")}, {QStringLiteral("terminal"), summary}});
}

void print(FakeNode& node, const QString& threadId, const QString& terminalId, const QString& data) {
  const QString key = threadId + QLatin1Char('/') + terminalId;
  node.part<FakeTerminals>().terminals[key].history += data;
  sendTerminal(node, key, {{QStringLiteral("type"), QStringLiteral("output")}, {QStringLiteral("data"), data}});
}

void closeTerminal(FakeNode& node, const QString& threadId, const QString& terminalId) {
  const QString key = threadId + QLatin1Char('/') + terminalId;
  if (!node.part<FakeTerminals>().terminals.remove(key)) return;
  sendTerminal(node, key, {{QStringLiteral("type"), QStringLiteral("closed")}});
  sendTerminals(node, {{QStringLiteral("type"), QStringLiteral("remove")},
                       {QStringLiteral("threadId"), threadId},
                       {QStringLiteral("terminalId"), terminalId}});
}

// The `terminal` subscriptions still attached, by terminal key.
QStringList attached(FakeNode& node) {
  QStringList keys;
  for (const int id : node.subscribers(QStringLiteral("terminal"))) {
    keys.append(terminalKey(node.shapeOf(id).value(QLatin1String("input")).toObject()));
  }
  return keys;
}

// Opens the terminal when the input says where (as terminal.open does);
// returns false when it does not exist and cannot be opened.
bool ensureTerminal(FakeNode& node, const QJsonObject& input) {
  FakeTerminals& fake = node.part<FakeTerminals>();
  const QString key = terminalKey(input);
  if (fake.terminals.contains(key)) return true;
  if (!input.contains(QLatin1String("cwd"))) return false;
  const QJsonObject summary = terminalSummary(input.value(QLatin1String("threadId")).toString(),
                                              input.value(QLatin1String("terminalId")).toString(),
                                              input.value(QLatin1String("cwd")).toString());
  fake.terminals.insert(key, {summary, QString()});
  sendTerminals(node, {{QStringLiteral("type"), QStringLiteral("upsert")}, {QStringLiteral("terminal"), summary}});
  return true;
}

const FakeNode::Extension extension([](FakeNode& node) {
  node.onShape(QStringLiteral("terminals"), [&node](int id, const QJsonObject& shape) {
    // Only its own environment's list; another environment's goes to the node serving it.
    if (shape.value(QLatin1String("environment")) != node.environmentId) {
      node.forget(id);
      return;
    }
    QJsonArray list;
    for (const FakeTerminals::Terminal& terminal : std::as_const(node.part<FakeTerminals>().terminals)) {
      list.append(terminal.summary);
    }
    sendTerminals(node, {{QStringLiteral("type"), QStringLiteral("snapshot")}, {QStringLiteral("terminals"), list}});
  });
  node.onShape(QStringLiteral("terminal"), [&node](int id, const QJsonObject& shape) {
    const QJsonObject input = shape.value(QLatin1String("input")).toObject();
    if (!ensureTerminal(node, input)) {
      node.forget(id);
      node.send({{QStringLiteral("t"), QStringLiteral("error")}, {QStringLiteral("id"), id}, {QStringLiteral("reason"), QStringLiteral("Unknown terminal")}});
      return;
    }
    const FakeTerminals::Terminal& terminal = node.part<FakeTerminals>().terminals[terminalKey(input)];
    QJsonObject snapshot = terminal.summary;
    snapshot.insert(QStringLiteral("history"), terminal.history);
    node.send({{QStringLiteral("t"), QStringLiteral("terminal")},
               {QStringLiteral("id"), id},
               {QStringLiteral("event"), QJsonObject{{QStringLiteral("type"), QStringLiteral("snapshot")}, {QStringLiteral("snapshot"), snapshot}}}});
  });
  node.onRpc(QStringLiteral("terminal."), [&node](const FakeNode::Rpc& rpc) {
    node.part<FakeTerminals>().calls.append({{QStringLiteral("method"), rpc.method}, {QStringLiteral("payload"), rpc.payload}});
    if (rpc.method == QLatin1String("terminal.open")) ensureTerminal(node, rpc.payload);
    auto answer = [&node, rpc] {
      if (!node.current(rpc)) return;
      if (rpc.method == QLatin1String("terminal.close")) {
        closeTerminal(node, rpc.payload.value(QLatin1String("threadId")).toString(),
                      rpc.payload.value(QLatin1String("terminalId")).toString());
      }
      node.reply(rpc, QJsonValue::Null);
    };
    if (node.holding(QStringLiteral("answers"))) {
      node.defer(answer);
    } else {
      answer();
    }
  });
});

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
  for (qsizetype index = world.node.subscriptions.size() - 1; index >= 0; --index) {
    const QJsonObject shape = world.node.subscriptions.at(index).value(QLatin1String("shape")).toObject();
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
  for (const QJsonObject& call : world.node.part<FakeTerminals>().calls) {
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
  for (const QJsonObject& call : world.node.part<FakeTerminals>().calls) {
    lines.append(QString::fromUtf8(QJsonDocument(call).toJson(QJsonDocument::Compact)));
  }
  return lines.isEmpty() ? QStringLiteral("(none)") : lines.join(QStringLiteral("; "));
}

QStringList terminalWrites(World& world, const QString& terminalId) {
  QStringList writes;
  for (const QJsonObject& call : world.node.part<FakeTerminals>().calls) {
    const QJsonObject payload = call.value(QLatin1String("payload")).toObject();
    if (call.value(QLatin1String("method")) == QLatin1String("terminal.write") &&
        payload.value(QLatin1String("terminalId")) == terminalId) {
      writes.append(payload.value(QLatin1String("data")).toString());
    }
  }
  return writes;
}

const Steps steps([] {
  const QString q = kQuoted;

  // The terminal drawer.
  const auto terminals = [](World& world) { return world.native().controller<TerminalController>(); };
  step(QStringLiteral("the node runs these terminals for %1:").arg(q), [](World& world, const Captures& c, const Table& table) {
    const QStringList& header = table.first();
    for (qsizetype row = 1; row < table.size(); ++row) {
      const QStringList& cells = table.at(row);
      addTerminal(world.node, c[0], cells.value(header.indexOf(QStringLiteral("terminal"))),
                             header.contains(QStringLiteral("label")) ? cells.value(header.indexOf(QStringLiteral("label"))) : QString(),
                             header.contains(QStringLiteral("busy")) && cells.value(header.indexOf(QStringLiteral("busy"))) == QLatin1String("yes"));
    }
    world.sync();
  });
  step(QStringLiteral("the node prints %1 in %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    print(world.node, c[2], c[1], unescaped(c[0]));
    world.sync();
  });
  step(QStringLiteral("the node closes %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    closeTerminal(world.node, c[1], c[0]);
    world.sync();
  });
  step(QStringLiteral("the user toggles the terminal drawer"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.toggle"));
    world.sync();  // what it asked of the node has been answered
  });
  step(QStringLiteral("the user opens a new terminal"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.new"));
    world.sync();  // what it asked of the node has been answered
  });
  step(QStringLiteral("the user selects %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.select"), QVariantMap{{QStringLiteral("terminalId"), c[0]}});
    world.sync();  // what it asked of the node has been answered
  });
  step(QStringLiteral("the user closes the active terminal"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.close"));
    world.sync();  // what it asked of the node has been answered
  });
  step(QStringLiteral("the user runs the script %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("workspace.runScript"), QVariantMap{{QStringLiteral("scriptId"), c[0]}});
    world.sync();  // what it asked of the node has been answered
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
  step(QStringLiteral("the node attaches %1 of %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const auto input = terminalAttach(world, c[1], c[0]);
      return input && input->value(QLatin1String("cwd")) == c[2];
    }, QStringLiteral("%1 of %2 to attach in %3").arg(c[0], c[1], c[2]));
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
    expect(attached(world.node).contains(c[1] + QLatin1Char('/') + c[0]), QStringLiteral("%1 of %2 was let go").arg(c[0], c[1]));
  });
  step(QStringLiteral("the node is asked to open %1 of %1 in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const auto payload = terminalCall(world, QStringLiteral("terminal.open"), c[1], c[0]);
      return payload && payload->value(QLatin1String("cwd")) == c[2];
    }, [&] { return QStringLiteral("terminal.open; the node got %1").arg(describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the node is not asked to open a terminal"), [](World& world, const Captures&, const Table&) {
    world.sync();
    for (const QJsonObject& call : world.node.part<FakeTerminals>().calls) {
      expect(call.value(QLatin1String("method")) != QLatin1String("terminal.open"), QStringLiteral("the node got %1").arg(describeTerminalCalls(world)));
    }
  });
  step(QStringLiteral("the node is asked to close %1 of %1 and delete its history").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const auto payload = terminalCall(world, QStringLiteral("terminal.close"), c[1], c[0]);
      return payload && payload->value(QLatin1String("deleteHistory")).toBool();
    }, [&] { return QStringLiteral("terminal.close; the node got %1").arg(describeTerminalCalls(world)); });
  });
  step(QStringLiteral("the node receives these writes to %1:").arg(q), [](World& world, const Captures& c, const Table& table) {
    QStringList wanted;
    for (qsizetype row = 1; row < table.size(); ++row) wanted.append(unescaped(table.at(row).value(0)));
    world.waitFor([&] { return terminalWrites(world, c[0]).size() >= wanted.size(); },
                  [&] { return QStringLiteral("%1 writes; the node got %2").arg(wanted.size()).arg(describeTerminalCalls(world)); });
    world.sync();
    expect(terminalWrites(world, c[0]) == wanted, QStringLiteral("the node got %1").arg(describeTerminalCalls(world)));
  });
  step(QStringLiteral("%1 shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString transcript = terminalSession(world, c[0])->transcript();
    expect(transcript.contains(unescaped(c[1])), QStringLiteral("%1 shows \"%2\"").arg(c[0], transcript));
  });
});

}  // namespace
