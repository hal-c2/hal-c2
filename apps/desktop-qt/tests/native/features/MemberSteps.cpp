// Threads on other machines of the cluster, in the shell: listed beside this
// MC's own and offline while their MC is down (the cluster members' scenarios
// of navigation/header.feature, navigation/keybindings.feature and
// source-control/, and threads/sidebar-list.feature).

#include <QJsonObject>
#include <QVariantList>

#include "Harness.h"
#include "World.h"

namespace {

// The thread on another machine the scenario is about.
struct MemberThread {
  QString environment;
  QString id;
};

const QString kMemberThread = QStringLiteral("t-member");

QJsonObject threadRow(const QString& id, const QString& title, const QString& project) {
  return {{QStringLiteral("id"), id},
          {QStringLiteral("title"), title},
          {QStringLiteral("projectId"), project},
          {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
          {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
}

void putProject(World& world, const QString& environment, const QString& project) {
  world.mc.sendPeerRow(environment, project,
                       {{QStringLiteral("id"), project},
                        {QStringLiteral("title"), project},
                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + project},
                        {QStringLiteral("scripts"), QJsonArray()}},
                       QStringLiteral("project"));
}

// Every thread row of the sidebar, whatever its section.
QVariantList sidebarRows(World& world) {
  QVariantList rows;
  const QVariant sidebar = world.state(QStringLiteral("sidebar"));
  for (const char* section : {"pinned", "active", "snoozed", "settled"}) {
    rows.append(at(sidebar, QString::fromLatin1(section)).toList());
  }
  return rows;
}

QVariantMap sidebarRow(World& world, const QString& key) {
  for (const QVariant& row : sidebarRows(world)) {
    if (row.toMap().value(QStringLiteral("key")) == key) return row.toMap();
  }
  return {};
}

// The member's thread's row, once it satisfies `holds`.
void waitForRow(World& world, const std::function<bool(const QVariantMap&)>& holds, const QString& what) {
  const MemberThread& thread = world.mc.part<MemberThread>();
  const QString key = thread.environment + QLatin1Char(':') + thread.id;
  world.waitFor([&] { return holds(sidebarRow(world, key)); },
                [&] { return QStringLiteral("%1; the sidebar is %2").arg(what, show(world.state(QStringLiteral("sidebar")))); });
}

QVariantMap workspace(World& world) {
  return world.state(QStringLiteral("workspace")).toMap();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("%1 becomes unreachable").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.setOnline(c[0], false);
  });
  step(QStringLiteral("%1 is reachable again").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.setOnline(c[0], true);
  });

  // navigation/header.feature and the git scenarios of source-control/ on another machine.
  step(QStringLiteral("%1 has the thread %1 titled %1 in %1 on the branch %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<MemberThread>() = {c[0], c[1]};
    putProject(world, c[0], c[3]);
    QJsonObject row = threadRow(c[1], c[2], c[3]);
    row.insert(QStringLiteral("branch"), c[4]);
    world.mc.sendPeerRow(c[0], c[1], row);
    world.sync();
  });
  step(QStringLiteral("the header says the thread is offline"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return workspace(world).value(QStringLiteral("offline")).toBool(); },
                  [&] { return QStringLiteral("the header to say offline; it shows %1").arg(show(workspace(world))); });
  });
  step(QStringLiteral("the header no longer says the thread is offline"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return workspace(world).value(QStringLiteral("offline")) == false; },
                  [&] { return QStringLiteral("the header to say online; it shows %1").arg(show(workspace(world))); });
  });

  // threads/sidebar-list.feature: a member of the cluster whose MC is down.
  step(QStringLiteral("the environment %1 is offline").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<MemberThread>() = {c[0], kMemberThread};
    world.mc.sendPeerRow(c[0], kMemberThread, threadRow(kMemberThread, QStringLiteral("Deploy"), QStringLiteral("shop")));
    world.mc.offline.insert(c[0]);
    world.mc.join(c[0]);
  });
  step(QStringLiteral("the threads from %1 are listed as unavailable").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForRow(world, [&](const QVariantMap& row) {
      return row.value(QStringLiteral("environmentId")) == c[0] && row.value(QStringLiteral("offline")).toBool();
    }, QStringLiteral("the thread from %1 to be listed offline").arg(c[0]));
  });
  step(QStringLiteral("actions that need %1 are unavailable").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QVariant& value : sidebarRows(world)) {
      const QVariantMap row = value.toMap();
      if (row.value(QStringLiteral("environmentId")) != c[0]) continue;
      expect(!row.value(QStringLiteral("canSettle")).toBool() && !row.value(QStringLiteral("canSnooze")).toBool(),
             QStringLiteral("the row offers actions: %1").arg(show(row)));
    }
  });
});

}  // namespace
