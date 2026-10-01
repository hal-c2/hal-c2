// Where a scenario starts: the time, and what the window shows (a thread of
// another environment, or a new thread's draft).

#include <QJsonArray>
#include <QJsonObject>

#include "Harness.h"
#include "World.h"

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  // A thread of another environment: a cluster member's rows carry it, or
  // the rows of a link to it.
  step(QStringLiteral("the user is viewing %1 with its project at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const qsizetype colon = c[0].indexOf(QLatin1Char(':'));
    const QString environment = c[0].left(colon);
    const QString peer = world.mc.peers.value(environment);
    const QString thread = c[0].mid(colon + 1);
    const QString project = QStringLiteral("project-") + thread;
    const QJsonObject projectRow{{QStringLiteral("id"), project}, {QStringLiteral("workspaceRoot"), c[1]}, {QStringLiteral("scripts"), QJsonArray()}};
    const QJsonObject threadRow{{QStringLiteral("id"), thread}, {QStringLiteral("projectId"), project}, {QStringLiteral("title"), thread}};
    if (!peer.isEmpty()) {
      QJsonArray rows;
      rows.append(QJsonArray{project, QStringLiteral("project"), projectRow});
      rows.append(QJsonArray{thread, QStringLiteral("thread"), threadRow});
      world.mc.sendRows(peer, rows);
      world.sync();
    } else if (world.mc.linked.contains(environment)) {
      world.mc.sendLinkRow(environment, project, projectRow, QStringLiteral("project"));
      world.mc.sendLinkRow(environment, thread, threadRow);
      world.sync();
    }
    world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), c[0]}});
  });
  step(QStringLiteral("the user is viewing a new thread in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.openDraft(c[0]);
  });
  step(QStringLiteral("the time is %1").arg(q), [](World& world, const Captures& c, const Table&) { world.setTime(c[0]); });
});

}  // namespace
