// The right panel's Previews tab (ThreadPreviews): a thread's browser tabs as
// the node keeps them (apps/server-ex preview.ex: `preview.list`,
// `preview.close`, and PreviewEvents on the `preview` shape), listed and
// opened in the user's browser. features/preview/surfaces.feature.

#include <QJsonArray>
#include <QJsonObject>

#include "Harness.h"
#include "RightPanelController.h"
#include "Stream.h"
#include "ThreadPreviews.h"
#include "World.h"

namespace {

using namespace stream;

// The node's browser tabs of the thread, oldest change first, and how it
// answers a close.
struct FakePreviews {
  QString epoch = QStringLiteral("epoch-1");
  qint64 revision = 0;
  QList<QJsonObject> tabs;
  bool refuseClose = false;
  bool holdClose = false;
  bool looking = false;
};

QJsonObject tabAt(const QString& url, int n) {
  return {{QStringLiteral("threadId"), kThread},
          {QStringLiteral("tabId"), QStringLiteral("tab-%1").arg(n)},
          {QStringLiteral("navStatus"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("Success")}, {QStringLiteral("url"), url}, {QStringLiteral("title"), QString()}}},
          {QStringLiteral("canGoBack"), false},
          {QStringLiteral("canGoForward"), false},
          {QStringLiteral("viewport"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("fill")}}},
          {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
}

// A PreviewEvent to every watcher, as preview.ex emit/4.
void emitEvent(FakeNode& node, const QJsonObject& tab, const QString& type, QJsonObject fields = {}) {
  FakePreviews& fake = node.part<FakePreviews>();
  fields.insert(QStringLiteral("type"), type);
  fields.insert(QStringLiteral("threadId"), tab.value(QLatin1String("threadId")));
  fields.insert(QStringLiteral("tabId"), tab.value(QLatin1String("tabId")));
  fields.insert(QStringLiteral("serverEpoch"), fake.epoch);
  fields.insert(QStringLiteral("revision"), ++fake.revision);
  for (const int id : node.subscribers(QStringLiteral("preview"))) {
    node.send({{QStringLiteral("t"), QStringLiteral("preview")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), fields}});
  }
}

int indexOfTab(const QList<QJsonObject>& tabs, const QString& tabId) {
  for (qsizetype at = 0; at < tabs.size(); ++at) {
    if (tabs.at(at).value(QLatin1String("tabId")).toString() == tabId) return int(at);
  }
  return -1;
}

const FakeNode::Extension previews([](FakeNode& node) {
  // The node sends nothing on subscribing; events follow as they happen.
  node.onShape(QStringLiteral("preview"), [](int, const QJsonObject&) {});
  node.onRpc(QStringLiteral("preview.list"), [&node](const FakeNode::Rpc& rpc) {
    FakePreviews& fake = node.part<FakePreviews>();
    QJsonArray sessions;
    for (const QJsonObject& tab : std::as_const(fake.tabs)) {
      if (tab.value(QLatin1String("threadId")) == rpc.payload.value(QLatin1String("threadId"))) sessions.append(tab);
    }
    node.reply(rpc, QJsonObject{{QStringLiteral("sessions"), sessions}, {QStringLiteral("serverEpoch"), fake.epoch}, {QStringLiteral("revision"), fake.revision}});
  });
  node.onRpc(QStringLiteral("preview.close"), [&node](const FakeNode::Rpc& rpc) {
    auto answer = [&node, rpc] {
      FakePreviews& fake = node.part<FakePreviews>();
      if (fake.refuseClose) {
        node.refuse(rpc, QStringLiteral("Preview is busy"));
        return;
      }
      const int at = indexOfTab(fake.tabs, rpc.payload.value(QLatin1String("tabId")).toString());
      if (at >= 0) emitEvent(node, fake.tabs.takeAt(at), QStringLiteral("closed"));
      node.reply(rpc, QJsonValue::Null);
    };
    if (node.part<FakePreviews>().holdClose) {
      node.defer(answer);
    } else {
      answer();
    }
  });
});

ThreadPreviews& model(World& world) {
  return *world.native().controller<RightPanelController>()->previews();
}

QString describe(World& world) {
  ThreadPreviews& list = model(world);
  QStringList rows;
  for (int row = 0; row < list.rowCount(); ++row) {
    const QModelIndex index = list.index(row);
    rows.append(QStringLiteral("%1 %2 (%3)").arg(index.data(ThreadPreviews::TabIdRole).toString(), index.data(ThreadPreviews::UrlRole).toString(),
                                                 index.data(ThreadPreviews::StatusRole).toString()));
  }
  return QStringLiteral("Previews is %1 (%2) and lists %3")
      .arg(list.status(), list.message(), rows.isEmpty() ? QStringLiteral("nothing") : rows.join(QStringLiteral("; ")));
}

QStringList urls(World& world) {
  QStringList listed;
  for (int row = 0; row < model(world).rowCount(); ++row) listed.append(model(world).index(row).data(ThreadPreviews::UrlRole).toString());
  return listed;
}

QString tabIdOf(World& world, const QString& url) {
  for (int row = 0; row < model(world).rowCount(); ++row) {
    const QModelIndex index = model(world).index(row);
    if (index.data(ThreadPreviews::UrlRole) == url) return index.data(ThreadPreviews::TabIdRole).toString();
  }
  fail(describe(world));
}

void waitForUrls(World& world, const QStringList& wanted) {
  world.waitFor([&] { return model(world).status() == QLatin1String("ready") && urls(world) == wanted; }, [&] { return describe(world); });
}

// The node has the thread's tabs at `addresses` before the user looks.
void haveTabs(World& world, const QStringList& addresses) {
  FakePreviews& fake = world.node.part<FakePreviews>();
  for (const QString& url : addresses) {
    fake.tabs.append(tabAt(url, int(fake.tabs.size()) + 1));
    ++fake.revision;
  }
}

// Looks at the thread with its Previews tab showing, as mod+shift+j does.
void showPreviews(World& world) {
  FakePreviews& fake = world.node.part<FakePreviews>();
  if (!fake.looking) {
    fake.looking = true;
    world.node.projects.insert(kProject, {{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject},
                                          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + kProject}, {QStringLiteral("scripts"), QJsonArray()}});
    world.connect();
    world.sync();
    lookAtThread(world, kProject);
  }
  RightPanelController* panel = world.native().controller<RightPanelController>();
  if (!panel->isOpen() || panel->activeTab() != QLatin1String("previews")) panel->togglePreviews();
  world.sync();
  world.waitFor([&] { return model(world).status() == QLatin1String("ready") && !world.node.subscribers(QStringLiteral("preview")).isEmpty(); },
                [&] { return describe(world); });
  expect(at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")) == QLatin1String("previews"), show(world.state(QStringLiteral("panel"))));
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the thread has browser tabs at %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    haveTabs(world, {c[0], c[1]});
  });
  step(QStringLiteral("the user shows the thread's previews"), [](World& world, const Captures&, const Table&) { showPreviews(world); });
  step(QStringLiteral("the user is showing the thread's previews"), [](World& world, const Captures&, const Table&) { showPreviews(world); });
  step(QStringLiteral("%1 and %1 are listed").arg(q), [](World& world, const Captures& c, const Table&) { waitForUrls(world, {c[0], c[1]}); });
  step(QStringLiteral("%1 is listed").arg(q), [](World& world, const Captures& c, const Table&) { waitForUrls(world, {c[0]}); });
  step(QStringLiteral("no browser tabs are listed"), [](World& world, const Captures&, const Table&) { waitForUrls(world, {}); });
  step(QStringLiteral("the user opens %1 from the previews").arg(q), [](World& world, const Captures& c, const Table&) {
    model(world).open(tabIdOf(world, c[0]));
  });

  // What the node tells every client.
  step(QStringLiteral("the agent opens a browser tab at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    FakePreviews& fake = world.node.part<FakePreviews>();
    fake.tabs.append(tabAt(c[0], int(fake.tabs.size()) + 1));
    emitEvent(world.node, fake.tabs.last(), QStringLiteral("opened"), {{QStringLiteral("snapshot"), fake.tabs.last()}});
    world.sync();
  });
  step(QStringLiteral("the page at %1 fails to load").arg(q), [](World& world, const Captures& c, const Table&) {
    FakePreviews& fake = world.node.part<FakePreviews>();
    const QJsonObject tab = fake.tabs.value(indexOfTab(fake.tabs, tabIdOf(world, c[0])));
    emitEvent(world.node, tab, QStringLiteral("failed"),
              {{QStringLiteral("url"), c[0]}, {QStringLiteral("title"), QString()}, {QStringLiteral("code"), QStringLiteral("ERR_CONNECTION_REFUSED")},
               {QStringLiteral("description"), QStringLiteral("Connection refused")}});
    world.sync();
  });
  step(QStringLiteral("the previews say %1 failed to load").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString tabId = tabIdOf(world, c[0]);
    world.waitFor([&] {
      const QModelIndex index = model(world).index(0);
      return index.data(ThreadPreviews::TabIdRole) == tabId && index.data(ThreadPreviews::StatusRole) == QLatin1String("failed") &&
             index.data(ThreadPreviews::ProblemRole) == QLatin1String("Connection refused");
    }, [&] { return describe(world); });
  });
  step(QStringLiteral("the tab at %1 is closed on the node").arg(q), [](World& world, const Captures& c, const Table&) {
    FakePreviews& fake = world.node.part<FakePreviews>();
    emitEvent(world.node, fake.tabs.takeAt(indexOfTab(fake.tabs, tabIdOf(world, c[0]))), QStringLiteral("closed"));
    world.sync();
  });

  // Closing.
  step(QStringLiteral("the node refuses to close a browser tab"), [](World& world, const Captures&, const Table&) {
    haveTabs(world, {QStringLiteral("http://localhost:5173"), QStringLiteral("http://localhost:6006")});
    world.node.part<FakePreviews>().refuseClose = true;
    showPreviews(world);
  });
  step(QStringLiteral("the user closes the tab"), [](World& world, const Captures&, const Table&) {
    model(world).close(tabIdOf(world, QStringLiteral("http://localhost:5173")));
    expect(urls(world) == QStringList{QStringLiteral("http://localhost:6006")}, describe(world));
    world.sync();
  });
  step(QStringLiteral("the tab returns as it was"), [](World& world, const Captures&, const Table&) {
    waitForUrls(world, {QStringLiteral("http://localhost:5173"), QStringLiteral("http://localhost:6006")});
    const QVariantList items = world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
    expect(!items.isEmpty() && items.last().toMap().value(QStringLiteral("title")) == QLatin1String("Could not close the browser tab"),
           show(items));
  });
  step(QStringLiteral("the user closes a browser tab"), [](World& world, const Captures&, const Table&) {
    haveTabs(world, {QStringLiteral("http://localhost:5173")});
    showPreviews(world);
    world.node.part<FakePreviews>().holdClose = true;
    model(world).close(tabIdOf(world, QStringLiteral("http://localhost:5173")));
    world.sync();
  });
  step(QStringLiteral("the tab disappears at once, even if an older update about it arrives"), [](World& world, const Captures&, const Table&) {
    expect(urls(world).isEmpty(), describe(world));
    // The page finished loading before the close reached the node.
    FakePreviews& fake = world.node.part<FakePreviews>();
    QJsonObject tab = fake.tabs.first();
    tab.insert(QStringLiteral("navStatus"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("Success")}, {QStringLiteral("url"), QStringLiteral("http://localhost:5173")},
                                                        {QStringLiteral("title"), QStringLiteral("Vite")}});
    emitEvent(world.node, tab, QStringLiteral("navigated"), {{QStringLiteral("snapshot"), tab}});
    world.sync();
    expect(urls(world).isEmpty(), describe(world));
    world.node.answerHeld();
    world.sync();
    expect(urls(world).isEmpty() && world.node.part<FakePreviews>().tabs.isEmpty(), describe(world));
  });
});

}  // namespace
