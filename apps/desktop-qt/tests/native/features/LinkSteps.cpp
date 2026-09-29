// Threads on environments the node is linked to, in the shell: listed beside
// the cluster's, changed row by row, offline while the link is down, and gone
// with the link (the desktop scenarios of connections/links.feature, the
// linked ones of desktop/native-workspace.feature and
// threads/sidebar-list.feature).

#include <QJsonObject>
#include <QVariantList>

#include "Harness.h"
#include "World.h"

namespace {

// The linked thread the scenario is about.
struct LinkedThread {
  QString environment;
  QString id;
  QString title;  // what it was last renamed to
  int shellSubscriptions = 0;
};

const QString kLinkedThread = QStringLiteral("t-linked");

QJsonObject threadRow(const QString& id, const QString& title, const QString& project) {
  return {{QStringLiteral("id"), id},
          {QStringLiteral("title"), title},
          {QStringLiteral("projectId"), project},
          {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
          {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
}

void putProject(World& world, const QString& environment, const QString& project) {
  world.node.sendLinkRow(environment, project,
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

QString linkedKey(World& world) {
  const LinkedThread& linked = world.node.part<LinkedThread>();
  return linked.environment + QLatin1Char(':') + linked.id;
}

void expectShellWithLinks(World& world) {
  world.sync();
  expect(world.node.shellLinks, QStringLiteral("the shell was not asked for with its links' rows"));
}

// The linked thread's row, once it satisfies `holds`.
void waitForRow(World& world, const std::function<bool(const QVariantMap&)>& holds, const QString& what) {
  const QString key = linkedKey(world);
  world.waitFor([&] { return holds(sidebarRow(world, key)); },
                [&] { return QStringLiteral("%1; the sidebar is %2").arg(what, show(world.state(QStringLiteral("sidebar")))); });
}

QVariantMap workspace(World& world) {
  return world.state(QStringLiteral("workspace")).toMap();
}

const Steps steps([] {
  const QString q = kQuoted;

  // connections/links.feature.
  step(QStringLiteral("a thread that lives on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    LinkedThread& linked = world.node.part<LinkedThread>();
    linked.environment = c[0];
    linked.id = kLinkedThread;
    putProject(world, c[0], QStringLiteral("ops"));
    world.node.sendLinkRow(c[0], kLinkedThread, threadRow(kLinkedThread, QStringLiteral("Deploy"), QStringLiteral("ops")));
    world.sync();
  });
  step(QStringLiteral("a client of the node asks for the shell with its links' rows"), [](World& world, const Captures&, const Table&) {
    expectShellWithLinks(world);
  });
  step(QStringLiteral("a client of the node follows the shell with its links' rows"), [](World& world, const Captures&, const Table&) {
    expectShellWithLinks(world);
    waitForRow(world, [](const QVariantMap& row) { return !row.isEmpty(); }, QStringLiteral("the linked thread to be listed"));
    world.node.part<LinkedThread>().shellSubscriptions = world.shellSubscriptions();
  });
  step(QStringLiteral("the thread is listed under the link to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForRow(world, [&](const QVariantMap& row) { return row.value(QStringLiteral("environmentId")) == c[0]; },
               QStringLiteral("the thread to be listed on %1").arg(c[0]));
  });
  step(QStringLiteral("the node of %1 is listed online under its link").arg(q), [](World& world, const Captures&, const Table&) {
    waitForRow(world, [](const QVariantMap& row) { return !row.isEmpty() && !row.value(QStringLiteral("offline")).toBool(); },
               QStringLiteral("the linked thread to be online"));
  });
  // The linked node is named as the cluster's own node is; its rows stay its
  // environment's, and the cluster's own are untouched.
  step(QStringLiteral("none of the rows of %1 are among the cluster's own").arg(q), [](World& world, const Captures&, const Table&) {
    const QString own = world.node.environmentId + QLatin1Char(':') + kLinkedThread;
    expect(sidebarRow(world, own).isEmpty(), QStringLiteral("the sidebar lists %1: %2").arg(own, show(world.state(QStringLiteral("sidebar")))));
  });
  step(QStringLiteral("the thread on %1 is renamed to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.part<LinkedThread>().title = c[1];
    world.node.sendLinkRow(c[0], kLinkedThread, threadRow(kLinkedThread, c[1], QStringLiteral("ops")));
  });
  step(QStringLiteral("the client receives only that thread's new row under the link to %1").arg(q), [](World& world, const Captures&, const Table&) {
    const QString title = world.node.part<LinkedThread>().title;
    waitForRow(world, [&](const QVariantMap& row) { return row.value(QStringLiteral("title")) == title; },
               QStringLiteral("the linked thread to be renamed"));
    expect(world.shellSubscriptions() == world.node.part<LinkedThread>().shellSubscriptions,
           QStringLiteral("the shell subscribed again for a rename"));
  });
  step(QStringLiteral("%1 becomes unreachable").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.setLinkProblem(c[0], QStringLiteral("unreachable"));
  });
  step(QStringLiteral("%1 is reachable again").arg(q), [](World& world, const Captures& c, const Table&) {
    world.node.setLinkProblem(c[0], QString());
  });
  step(QStringLiteral("the client is told the node of %1 is offline under its link").arg(q), [](World& world, const Captures&, const Table&) {
    waitForRow(world, [](const QVariantMap& row) { return row.value(QStringLiteral("offline")).toBool(); },
               QStringLiteral("the linked thread to be offline"));
  });
  // The desktop is that client: it reconnects and asks again.
  step(QStringLiteral("a client of the node that asks for the shell with its links' rows sees the thread under the link to %1, offline").arg(q),
       [](World& world, const Captures& c, const Table&) {
         const int before = world.shellSubscriptions();
         world.node.drop();
         world.waitFor([&] { return world.shellSubscriptions() > before && world.native().client()->isReady(); },
                       QStringLiteral("the shell to subscribe again"));
         expectShellWithLinks(world);
         waitForRow(world, [&](const QVariantMap& row) {
           return row.value(QStringLiteral("environmentId")) == c[0] && row.value(QStringLiteral("offline")).toBool();
         }, QStringLiteral("the linked thread to be listed offline"));
       });
  step(QStringLiteral("the user removes the link to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("connections.unlink"), QVariantMap{{QStringLiteral("environmentId"), c[0]}});
  });
  step(QStringLiteral("the client's links no longer include %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !world.node.linked.contains(c[0]); }, QStringLiteral("the node to unlink it"));
    world.sync();
    const QVariantList links = at(world.state(QStringLiteral("connections")), QStringLiteral("links")).toList();
    for (const QVariant& link : links) {
      expect(link.toMap().value(QStringLiteral("environmentId")) != c[0], QStringLiteral("the links are %1").arg(show(links)));
    }
  });
  step(QStringLiteral("the node no longer follows the shell of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    for (const QVariant& row : sidebarRows(world)) {
      expect(row.toMap().value(QStringLiteral("environmentId")) != c[0],
             QStringLiteral("the sidebar still lists %1").arg(show(row)));
    }
  });

  // desktop/native-workspace.feature.
  step(QStringLiteral("%1 has the thread %1 titled %1 in %1 on the branch %1").arg(q), [](World& world, const Captures& c, const Table&) {
    LinkedThread& linked = world.node.part<LinkedThread>();
    linked.environment = c[0];
    linked.id = c[1];
    putProject(world, c[0], c[3]);
    QJsonObject row = threadRow(c[1], c[2], c[3]);
    row.insert(QStringLiteral("branch"), c[4]);
    world.node.sendLinkRow(c[0], c[1], row);
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

  // threads/sidebar-list.feature: an environment the node reaches through a
  // link that is down.
  step(QStringLiteral("the environment %1 is offline").arg(q), [](World& world, const Captures& c, const Table&) {
    LinkedThread& linked = world.node.part<LinkedThread>();
    linked.environment = c[0];
    linked.id = kLinkedThread;
    world.node.sendLinkRow(c[0], kLinkedThread, threadRow(kLinkedThread, QStringLiteral("Deploy"), QStringLiteral("shop")));
    world.node.link(c[0]);
    world.node.setLinkProblem(c[0], QStringLiteral("unreachable"));
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
