// What the node holds (threads, projects) and does (updates, refusals, held
// answers), and the orchestration commands it receives.

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

#include <optional>

#include "Harness.h"
#include "World.h"

namespace {

QJsonObject threadRow(const QStringList& header, const QStringList& cells) {
  QJsonObject row;
  for (qsizetype column = 0; column < header.size(); ++column) {
    const QString& value = cells.value(column);
    if (value.isEmpty()) continue;
    QString name = header.at(column);
    if (name == QLatin1String("project")) name = QStringLiteral("projectId");
    row.insert(name, value);
  }
  if (!row.contains(QLatin1String("createdAt"))) row.insert(QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z"));
  if (!row.contains(QLatin1String("updatedAt"))) row.insert(QStringLiteral("updatedAt"), row.value(QLatin1String("createdAt")));
  return row;
}

void setField(QJsonObject& row, const QString& name, const QString& value) {
  // The node sends the background tasks themselves; only their count matters here.
  if (name == QLatin1String("pendingBackgroundTasks")) {
    QJsonArray tasks;
    for (int task = 0; task < value.toInt(); ++task) tasks.append(QJsonObject{{QStringLiteral("id"), task}});
    row.insert(name, tasks);
  } else {
    row.insert(name, value);
  }
}

// Finds the first unchecked command of `type` (for `threadId`, when given).
std::optional<qsizetype> findCommand(World& world, const QString& type, const QString& threadId = {}) {
  for (qsizetype index = 0; index < world.node.commands.size(); ++index) {
    const QJsonObject& command = world.node.commands.at(index);
    if (world.checkedCommands.contains(index)) continue;
    if (command.value(QLatin1String("type")).toString() != type) continue;
    if (!threadId.isEmpty() && command.value(QLatin1String("threadId")).toString() != threadId) continue;
    return index;
  }
  return std::nullopt;
}

void expectField(const QJsonObject& command, const QString& path, const QString& expected) {
  const QVariant actual = at(command.toVariantMap(), path);
  expect(actual.toString() == expected, QStringLiteral("expected %1 to be \"%2\" in %3")
                                            .arg(path, expected, QString::fromUtf8(QJsonDocument(command).toJson(QJsonDocument::Compact))));
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the node's environment does not track visits"), [](World& world, const Captures&, const Table&) {
    world.node.capabilities.remove(QStringLiteral("threadVisitedTracking"));
  });
  step(QStringLiteral("the node has these threads:"), [](World& world, const Captures&, const Table& table) {
    for (qsizetype row = 1; row < table.size(); ++row) {
      const QJsonObject thread = threadRow(table.first(), table.at(row));
      world.node.threads.insert(thread.value(QLatin1String("id")).toString(), thread);
    }
  });

  // Node updates.
  step(QStringLiteral("the node updates the thread %1 with the title %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject& row = world.node.threads[c[0]];
    row.insert(QStringLiteral("title"), c[1]);
    world.node.sendRow(c[0], row);
    world.sync();
  });
  step(QStringLiteral("the node updates the thread %1 with:").arg(q), [](World& world, const Captures& c, const Table& table) {
    QJsonObject& row = world.node.threads[c[0]];
    for (const QStringList& cells : table) setField(row, cells.value(0), cells.value(1));
    world.node.sendRow(c[0], row);
    world.sync();
  });
  step(QStringLiteral("the node deletes the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject row = world.node.threads.take(c[0]);
    row.insert(QStringLiteral("deletedAt"), QStringLiteral("2026-09-23T10:00:00Z"));
    world.node.sendRow(c[0], row);
    world.sync();
  });
  step(QStringLiteral("the node refuses %1 with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.refusals.insert(c[0], c[1]);
  });
  step(QStringLiteral("the node holds its answers"), [](World& world, const Captures&, const Table&) {
    world.node.hold(QStringLiteral("answers"));
  });
  step(QStringLiteral("the node answers"), [](World& world, const Captures&, const Table&) {
    world.sync();  // every held command has reached the node
    world.node.answerHeld();
    world.sync();
  });

  // What the node received.
  step(QStringLiteral("the node receives an? %1 command for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return findCommand(world, c[0], c[1]).has_value(); },
                  [&] { return QStringLiteral("a %1 command for %2; the node has %3").arg(c[0], c[1], world.describeCommands()); });
    world.command = findCommand(world, c[0], c[1]);
    world.checkedCommands.insert(*world.command);
  });
  step(QStringLiteral("the command's %1 is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.command.has_value(), QStringLiteral("no command was found before"));
    expectField(world.node.commands.at(*world.command), c[0], c[1]);
  });
  step(QStringLiteral("the command %1 has %1 %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QJsonObject& command : world.node.commands) {
      if (command.value(QLatin1String("type")).toString() == c[0]) return expectField(command, c[1], c[2]);
    }
    fail(QStringLiteral("no %1 command; the node has %2").arg(c[0], world.describeCommands()));
  });
  step(QStringLiteral("the node receives these commands in order:"), [](World& world, const Captures&, const Table& table) {
    const qsizetype wanted = table.size() - 1;
    world.waitFor([&] { return world.node.commands.size() >= wanted; }, QStringLiteral("%1 commands").arg(wanted));
    world.sync();
    expect(world.node.commands.size() == wanted, QStringLiteral("the node has %1").arg(world.describeCommands()));
    for (qsizetype row = 1; row < table.size(); ++row) {
      const QString type = world.node.commands.at(row - 1).value(QLatin1String("type")).toString();
      expect(type == table.at(row).value(0), QStringLiteral("command %1 is %2, not %3").arg(row).arg(type, table.at(row).value(0)));
      world.checkedCommands.insert(row - 1);
    }
  });
  step(QStringLiteral("the node receives these messages in order:"), [](World& world, const Captures&, const Table& table) {
    const auto texts = [&] {
      QStringList texts;
      for (const QJsonObject& command : world.node.commands) {
        if (command.value(QLatin1String("type")).toString() == QLatin1String("message.dispatch")) {
          texts.append(command.value(QLatin1String("text")).toString());
        }
      }
      return texts;
    };
    QStringList wanted;
    for (qsizetype row = 1; row < table.size(); ++row) wanted.append(table.at(row).value(0));
    world.waitFor([&] { return texts().size() >= wanted.size(); }, QStringLiteral("%1 messages").arg(wanted.size()));
    world.sync();
    expect(texts() == wanted, QStringLiteral("the node has the messages %1").arg(texts().join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the node receives no commands"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.node.commands.isEmpty(), QStringLiteral("the node has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("the node receives no other commands"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.node.commands.size() == world.checkedCommands.size(),
           QStringLiteral("the node has %1").arg(world.describeCommands()));
  });

  // The node's projects.
  step(QStringLiteral("the node has the project %1 at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.projects.insert(c[0], {{QStringLiteral("id"), c[0]}, {QStringLiteral("title"), c[0]}, {QStringLiteral("workspaceRoot"), c[1]}, {QStringLiteral("scripts"), QJsonArray()}});
  });
  step(QStringLiteral("the project %1 has these scripts:").arg(q), [](World& world, const Captures& c, const Table& table) {
    QJsonArray scripts;
    for (qsizetype row = 1; row < table.size(); ++row) {
      QJsonObject script;
      for (qsizetype column = 0; column < table.first().size(); ++column) script.insert(table.first().at(column), table.at(row).value(column));
      scripts.append(script);
    }
    world.node.projects[c[0]].insert(QStringLiteral("scripts"), scripts);
  });
});

}  // namespace
