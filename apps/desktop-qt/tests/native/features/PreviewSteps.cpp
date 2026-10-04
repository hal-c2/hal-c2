// The right panel's Previews tab (ThreadPreviews): a thread's browser tabs as
// the MC keeps them (apps/server-ex preview.ex: `preview.list`,
// `preview.close`, and PreviewEvents on the `preview` shape), listed and
// opened in the user's browser. features/preview/surfaces.feature.

#include <QJsonArray>
#include <QJsonObject>

#include "Brick.h"
#include "ComposerBrick.h"
#include "CommandPaletteController.h"
#include "Harness.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "Stream.h"
#include "ThreadPreviews.h"
#include "World.h"

namespace {

using namespace stream;

// The MC's browser tabs of the thread, oldest change first, and how it
// answers a close.
struct FakePreviews {
  QString epoch = QStringLiteral("epoch-1");
  qint64 revision = 0;
  QList<QJsonObject> tabs;
  bool refuseClose = false;
  bool holdClose = false;
  bool holdList = false;
  int lists = 0;
  // The web servers listening on the MC's machine (DiscoveredLocalServer).
  QJsonArray servers;
  // Every preview.open and preview.navigate payload.
  QList<QJsonObject> opens;
  QList<QJsonObject> navigations;
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
void emitEvent(FakeMc& mc, const QJsonObject& tab, const QString& type, QJsonObject fields = {}) {
  FakePreviews& fake = mc.part<FakePreviews>();
  fields.insert(QStringLiteral("type"), type);
  fields.insert(QStringLiteral("threadId"), tab.value(QLatin1String("threadId")));
  fields.insert(QStringLiteral("tabId"), tab.value(QLatin1String("tabId")));
  fields.insert(QStringLiteral("serverEpoch"), fake.epoch);
  fields.insert(QStringLiteral("revision"), ++fake.revision);
  for (const int id : mc.subscribers(QStringLiteral("preview"))) {
    mc.send({{QStringLiteral("t"), QStringLiteral("preview")}, {QStringLiteral("id"), id}, {QStringLiteral("event"), fields}});
  }
}

int indexOfTab(const QList<QJsonObject>& tabs, const QString& tabId) {
  for (qsizetype at = 0; at < tabs.size(); ++at) {
    if (tabs.at(at).value(QLatin1String("tabId")).toString() == tabId) return int(at);
  }
  return -1;
}

const FakeMc::Extension previews([](FakeMc& mc) {
  // The MC sends nothing on subscribing; events follow as they happen.
  mc.onShape(QStringLiteral("preview"), [](int, const QJsonObject&) {});
  mc.onRpc(QStringLiteral("preview.list"), [&mc](const FakeMc::Rpc& rpc) {
    FakePreviews& fake = mc.part<FakePreviews>();
    ++fake.lists;
    QJsonArray sessions;
    for (const QJsonObject& tab : std::as_const(fake.tabs)) {
      if (tab.value(QLatin1String("threadId")) == rpc.payload.value(QLatin1String("threadId"))) sessions.append(tab);
    }
    // The list as it is now; a held answer arrives after whatever changes next.
    const QJsonObject list{{QStringLiteral("sessions"), sessions}, {QStringLiteral("serverEpoch"), fake.epoch}, {QStringLiteral("revision"), fake.revision}};
    if (fake.holdList) {
      mc.defer([&mc, rpc, list] { mc.reply(rpc, list); });
      return;
    }
    mc.reply(rpc, list);
  });
  // The MC's machine's web servers, to whoever watches (local_servers.ex).
  mc.onShape(QStringLiteral("localServers"), [&mc](int id, const QJsonObject&) {
    mc.send({{QStringLiteral("t"), QStringLiteral("localServers")}, {QStringLiteral("id"), id},
             {QStringLiteral("list"), QJsonObject{{QStringLiteral("servers"), mc.part<FakePreviews>().servers}, {QStringLiteral("scannedAt"), QStringLiteral("2026-09-23T10:00:00Z")}}}});
  });
  // preview.ex open/2 and navigate/2: the tab's snapshot, and its event.
  mc.onRpc(QStringLiteral("preview.open"), [&mc](const FakeMc::Rpc& rpc) {
    FakePreviews& fake = mc.part<FakePreviews>();
    fake.opens.append(rpc.payload);
    QJsonObject tab = tabAt(rpc.payload.value(QLatin1String("url")).toString(), int(fake.tabs.size()) + 1);
    tab.insert(QStringLiteral("threadId"), rpc.payload.value(QLatin1String("threadId")));
    tab.insert(QStringLiteral("navStatus"), rpc.payload.contains(QLatin1String("url"))
                                                ? QJsonObject{{QStringLiteral("_tag"), QStringLiteral("Loading")}, {QStringLiteral("url"), rpc.payload.value(QLatin1String("url"))}, {QStringLiteral("title"), QString()}}
                                                : QJsonObject{{QStringLiteral("_tag"), QStringLiteral("Idle")}});
    fake.tabs.append(tab);
    emitEvent(mc, tab, QStringLiteral("opened"), {{QStringLiteral("snapshot"), tab}});
    mc.reply(rpc, tab);
  });
  mc.onRpc(QStringLiteral("preview.navigate"), [&mc](const FakeMc::Rpc& rpc) {
    FakePreviews& fake = mc.part<FakePreviews>();
    fake.navigations.append(rpc.payload);
    const int at = indexOfTab(fake.tabs, rpc.payload.value(QLatin1String("tabId")).toString());
    if (at < 0) {
      mc.refuse(rpc, QStringLiteral("Unknown preview session"));
      return;
    }
    fake.tabs[at].insert(QStringLiteral("navStatus"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("Success")}, {QStringLiteral("url"), rpc.payload.value(QLatin1String("url"))}, {QStringLiteral("title"), QString()}});
    emitEvent(mc, fake.tabs.at(at), QStringLiteral("navigated"), {{QStringLiteral("snapshot"), fake.tabs.at(at)}});
    mc.reply(rpc, fake.tabs.at(at));
  });
  mc.onRpc(QStringLiteral("preview.close"), [&mc](const FakeMc::Rpc& rpc) {
    auto answer = [&mc, rpc] {
      FakePreviews& fake = mc.part<FakePreviews>();
      if (fake.refuseClose) {
        mc.refuse(rpc, QStringLiteral("Preview is busy"));
        return;
      }
      const int at = indexOfTab(fake.tabs, rpc.payload.value(QLatin1String("tabId")).toString());
      if (at >= 0) emitEvent(mc, fake.tabs.takeAt(at), QStringLiteral("closed"));
      mc.reply(rpc, QJsonValue::Null);
    };
    if (mc.part<FakePreviews>().holdClose) {
      mc.defer(answer);
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

// The MC has the thread's tabs at `addresses` before the user looks.
void haveTabs(World& world, const QStringList& addresses) {
  FakePreviews& fake = world.mc.part<FakePreviews>();
  for (const QString& url : addresses) {
    fake.tabs.append(tabAt(url, int(fake.tabs.size()) + 1));
    ++fake.revision;
  }
}

// Looks at the thread with its Previews tab showing, as mod+shift+j does.
void showPreviews(World& world) {
  FakePreviews& fake = world.mc.part<FakePreviews>();
  if (!fake.looking) {
    fake.looking = true;
    world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject},
                                          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + kProject}, {QStringLiteral("scripts"), QJsonArray()}});
    world.connect();
    world.sync();
    lookAtThread(world, kProject);
  }
  RightPanelController* panel = world.native().controller<RightPanelController>();
  if (!panel->isOpen() || panel->activeTab() != QLatin1String("previews")) panel->togglePreviews();
  world.sync();
  world.waitFor([&] { return model(world).status() == QLatin1String("ready") && !world.mc.subscribers(QStringLiteral("preview")).isEmpty(); },
                [&] { return describe(world); });
  expect(at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")) == QLatin1String("previews"), show(world.state(QStringLiteral("panel"))));
}

const Steps steps([] {
  Brick::registerSingletons();
  const QString q = kQuoted;

  step(QStringLiteral("the thread has browser tabs at %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    haveTabs(world, {c[0], c[1]});
  });
  step(QStringLiteral("the user shows the thread's previews"), [](World& world, const Captures&, const Table&) { showPreviews(world); });
  step(QStringLiteral("the user is showing the thread's previews"), [](World& world, const Captures&, const Table&) { showPreviews(world); });
  step(QStringLiteral("%1 and %1 are listed").arg(q), [](World& world, const Captures& c, const Table&) { waitForUrls(world, {c[0], c[1]}); });
  step(QStringLiteral("%1 is listed").arg(q), [](World& world, const Captures& c, const Table&) {
    if (modelPickerLists(world, c[0], true)) return;
    // In an open command palette: an entry of that title.
    if (auto* palette = world.native().controller<CommandPaletteController>(); palette && palette->isOpen()) {
      world.sync();
      for (int row = 0; row < palette->rowCount(); ++row) {
        if (palette->index(row).data(CommandPaletteController::TitleRole) == c[0]) return;
      }
      fail(QStringLiteral("the command palette does not list \"%1\"").arg(c[0]));
    }
    waitForUrls(world, {c[0]});
  });
  step(QStringLiteral("no browser tabs are listed"), [](World& world, const Captures&, const Table&) { waitForUrls(world, {}); });
  step(QStringLiteral("the user opens %1 from the previews").arg(q), [](World& world, const Captures& c, const Table&) {
    model(world).open(tabIdOf(world, c[0]));
  });

  // What the MC tells every client.
  step(QStringLiteral("the agent opens a browser tab at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    FakePreviews& fake = world.mc.part<FakePreviews>();
    fake.tabs.append(tabAt(c[0], int(fake.tabs.size()) + 1));
    emitEvent(world.mc, fake.tabs.last(), QStringLiteral("opened"), {{QStringLiteral("snapshot"), fake.tabs.last()}});
    world.sync();
  });
  step(QStringLiteral("the page at %1 fails to load").arg(q), [](World& world, const Captures& c, const Table&) {
    FakePreviews& fake = world.mc.part<FakePreviews>();
    const QJsonObject tab = fake.tabs.value(indexOfTab(fake.tabs, tabIdOf(world, c[0])));
    emitEvent(world.mc, tab, QStringLiteral("failed"),
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
  step(QStringLiteral("the tab at %1 is closed on the MC").arg(q), [](World& world, const Captures& c, const Table&) {
    FakePreviews& fake = world.mc.part<FakePreviews>();
    emitEvent(world.mc, fake.tabs.takeAt(indexOfTab(fake.tabs, tabIdOf(world, c[0]))), QStringLiteral("closed"));
    world.sync();
  });

  // Across an MC restart and out-of-order answers (preview/remote.feature).
  step(QStringLiteral("the client shows a thread's browser tabs"), [](World& world, const Captures&, const Table&) {
    haveTabs(world, {QStringLiteral("http://localhost:5173"), QStringLiteral("http://localhost:6006")});
    showPreviews(world);
    waitForUrls(world, {QStringLiteral("http://localhost:5173"), QStringLiteral("http://localhost:6006")});
  });
  step(QStringLiteral("the MC restarts and a tab change arrives with a new run number"), [](World& world, const Captures&, const Table&) {
    FakePreviews& fake = world.mc.part<FakePreviews>();
    // A new run keeps none of the old tabs and counts its changes from the start.
    fake.epoch = QStringLiteral("epoch-2");
    fake.revision = 0;
    fake.tabs.clear();
    fake.lists = 0;
    fake.tabs.append(tabAt(QStringLiteral("http://localhost:3000"), 9));
    emitEvent(world.mc, fake.tabs.last(), QStringLiteral("opened"), {{QStringLiteral("snapshot"), fake.tabs.last()}});
    world.sync();
  });
  step(QStringLiteral("the client lists the thread's tabs again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.mc.part<FakePreviews>().lists == 1; },
                  [&] { return QStringLiteral("one new preview.list; the MC got %1").arg(world.mc.part<FakePreviews>().lists); });
  });
  step(QStringLiteral("it shows only the tabs the restarted MC has"), [](World& world, const Captures&, const Table&) {
    waitForUrls(world, {QStringLiteral("http://localhost:3000")});
    // And follows the new run's changes from there.
    FakePreviews& fake = world.mc.part<FakePreviews>();
    fake.tabs.append(tabAt(QStringLiteral("http://localhost:3001"), 10));
    emitEvent(world.mc, fake.tabs.last(), QStringLiteral("opened"), {{QStringLiteral("snapshot"), fake.tabs.last()}});
    waitForUrls(world, {QStringLiteral("http://localhost:3000"), QStringLiteral("http://localhost:3001")});
  });
  step(QStringLiteral("the client has seen a tab change with a newer change number"), [](World& world, const Captures&, const Table&) {
    haveTabs(world, {QStringLiteral("http://localhost:5173")});
    showPreviews(world);
    waitForUrls(world, {QStringLiteral("http://localhost:5173")});
    // The user reloads the list; the MC's answer, read now, is on its way...
    FakePreviews& fake = world.mc.part<FakePreviews>();
    fake.holdList = true;
    fake.lists = 0;
    model(world).reload();
    world.waitFor([&] { return fake.lists == 1; }, QStringLiteral("the list to be asked for"));
    // ...when the agent opens another tab, which the client hears of first.
    fake.tabs.append(tabAt(QStringLiteral("http://localhost:6006"), 2));
    emitEvent(world.mc, fake.tabs.last(), QStringLiteral("opened"), {{QStringLiteral("snapshot"), fake.tabs.last()}});
    waitForUrls(world, {QStringLiteral("http://localhost:5173"), QStringLiteral("http://localhost:6006")});
  });
  step(QStringLiteral("an older tab list arrives"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakePreviews>().holdList = false;
    world.mc.answerHeld();
    world.sync();
  });
  step(QStringLiteral("the client keeps the newer tab state"), [](World& world, const Captures&, const Table&) {
    expect(urls(world) == QStringList{QStringLiteral("http://localhost:5173"), QStringLiteral("http://localhost:6006")} &&
               model(world).status() == QLatin1String("ready"),
           describe(world));
    // The next change still counts from the newer one.
    FakePreviews& fake = world.mc.part<FakePreviews>();
    emitEvent(world.mc, fake.tabs.takeAt(0), QStringLiteral("closed"));
    waitForUrls(world, {QStringLiteral("http://localhost:6006")});
  });

  // A new browser tab, and what it offers (preview/surfaces.feature, remote.feature).
  const auto server = [](const QString& url, const QString& process) {
    return QJsonObject{{QStringLiteral("host"), QStringLiteral("localhost")}, {QStringLiteral("port"), QUrl(url).port()}, {QStringLiteral("url"), url},
                       {QStringLiteral("processName"), process}, {QStringLiteral("pid"), 4242}, {QStringLiteral("terminal"), QJsonValue::Null}};
  };
  const auto suggested = [](World& world, const QString& kind) {
    QStringList found;
    for (const QVariant& suggestion : model(world).suggestions()) {
      if (suggestion.toMap().value(QStringLiteral("kind")) == kind) found.append(suggestion.toMap().value(QStringLiteral("url")).toString());
    }
    return found;
  };
  step(QStringLiteral("the side panel is open"), [](World& world, const Captures&, const Table&) {
    showPreviews(world);
    expect(world.native().controller<RightPanelController>()->isOpen(), show(world.state(QStringLiteral("panel"))));
  });
  step(QStringLiteral("the user opens the side panel's add menu"), [](World& world, const Captures&, const Table&) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nItem { RightPanel { anchors.fill: parent } }\n", QSize(700, 600));
    world.brick->click(QStringLiteral("panelAdd"));
    world.waitFor([&] { return world.brick->shows(QStringLiteral("Browser tab")); }, QStringLiteral("the add menu to open"));
  });
  step(QStringLiteral("it offers a browser tab next to diff, files, terminal and pull request"), [](World& world, const Captures&, const Table&) {
    for (const QString& entry : {QStringLiteral("Diff"), QStringLiteral("Files"), QStringLiteral("Terminal"), QStringLiteral("Pull requests"), QStringLiteral("Browser tab")}) {
      expect(world.brick->shows(entry), QStringLiteral("the add menu has no \"%1\"").arg(entry));
    }
    // Choosing it opens an empty tab on the MC, shown with the thread's others.
    QQuickItem* entry = world.brick->item(QStringLiteral("panelAddBrowser"));
    expect(entry->isEnabled(), QStringLiteral("the browser tab entry is off"));
    world.brick->click(QStringLiteral("panelAddBrowser"));
    FakePreviews& fake = world.mc.part<FakePreviews>();
    world.waitFor([&] { return fake.opens.size() == 1 && model(world).rowCount() == 1; }, [&] { return describe(world); });
    expect(fake.opens.first().value(QLatin1String("threadId")) == kThread && !fake.opens.first().contains(QLatin1String("url")) &&
               at(world.state(QStringLiteral("panel")), QStringLiteral("activeId")) == QLatin1String("previews") &&
               model(world).index(0).data(ThreadPreviews::StatusRole) == QLatin1String("idle"),
           describe(world));
  });
  step(QStringLiteral("the thread's project has a dev server running and recently visited pages"), [server](World& world, const Captures&, const Table&) {
    FakePreviews& fake = world.mc.part<FakePreviews>();
    fake.servers = QJsonArray{server(QStringLiteral("http://localhost:5173"), QStringLiteral("vite"))};
    // The project's script names its own preview address.
    world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + kProject},
                                          {QStringLiteral("scripts"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("dev")}, {QStringLiteral("name"), QStringLiteral("Dev")},
                                                                                             {QStringLiteral("command"), QStringLiteral("bun dev")}, {QStringLiteral("icon"), QStringLiteral("play")},
                                                                                             {QStringLiteral("runOnWorktreeCreate"), false},
                                                                                             {QStringLiteral("previewUrl"), QStringLiteral("http://localhost:3000")}}}}});
    fake.looking = true;
    world.connect();
    world.sync();
    lookAtThread(world, kProject);
    // Twelve pages opened from browser tabs on this device, the newest first.
    QStringList pages;
    for (int n = 12; n >= 1; --n) pages.append(QStringLiteral("https://docs.example.com/page-%1").arg(n));
    auto* settings = world.native().controller<SettingsController>();
    expect(settings->writeDevice(QStringLiteral("previewRecentPages"), pages), settings->deviceError());
  });
  step(QStringLiteral("the user opens a new browser tab"), [](World& world, const Captures&, const Table&) {
    showPreviews(world);
    world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("browser")}});
    world.waitFor([&] { return model(world).rowCount() == 1 && model(world).index(0).data(ThreadPreviews::StatusRole) == QLatin1String("idle"); },
                  [&] { return describe(world); });
    world.sync();
  });
  step(QStringLiteral("the tab suggests the running servers, configured preview addresses and up to 10 recent pages"), [suggested](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return suggested(world, QStringLiteral("server")) == QStringList{QStringLiteral("http://localhost:5173")}; },
                  [&] { return QStringLiteral("the MC's server to be suggested; the tab suggests %1").arg(show(model(world).suggestions())); });
    expect(suggested(world, QStringLiteral("configured")) == QStringList{QStringLiteral("http://localhost:3000")}, show(model(world).suggestions()));
    const QStringList recent = suggested(world, QStringLiteral("recent"));
    expect(recent.size() == 10 && recent.first() == QLatin1String("https://docs.example.com/page-12") && recent.last() == QLatin1String("https://docs.example.com/page-3"),
           show(model(world).suggestions()));
    // The empty tab draws them, and one click opens the page.
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\nPreviewsPanel { source: Panel.previews }\n", QSize(420, 900));
    for (const QString& url : {QStringLiteral("http://localhost:5173"), QStringLiteral("http://localhost:3000"), QStringLiteral("https://docs.example.com/page-12")}) {
      expect(world.brick->shows(url), QStringLiteral("the tab does not draw %1").arg(url));
    }
    expect(!world.brick->shows(QStringLiteral("https://docs.example.com/page-2")), QStringLiteral("an eleventh recent page is drawn"));
    world.brick->click(QStringLiteral("previewSuggestion-0"));
    FakePreviews& fake = world.mc.part<FakePreviews>();
    world.waitFor([&] { return fake.navigations.size() == 1 && world.openedUrls == QList<QUrl>{QUrl(QStringLiteral("http://localhost:5173"))}; },
                  [&] { return describe(world); });
    expect(fake.navigations.first().value(QLatin1String("url")) == QLatin1String("http://localhost:5173"), describe(world));
    waitForUrls(world, {QStringLiteral("http://localhost:5173")});
    // And it is the newest recent page from now on.
    world.waitFor([&] { return suggested(world, QStringLiteral("server")).size() == 1 &&
                               world.native().controller<SettingsController>()->deviceValue(QStringLiteral("previewRecentPages")).toStringList().value(0) == QLatin1String("http://localhost:5173"); },
                  QStringLiteral("the page to be remembered"));
  });
  step(QStringLiteral("the desktop is connected to an MC on another machine"), [server](World& world, const Captures&, const Table&) {
    // The MC's machine runs these; nothing is scanned on the desktop's.
    world.mc.part<FakePreviews>().servers = QJsonArray{server(QStringLiteral("http://localhost:4321"), QStringLiteral("astro")),
                                                        server(QStringLiteral("http://localhost:8080"), QStringLiteral("caddy"))};
    world.bridge().setLocalFolderImportEnabled(false);
  });
  step(QStringLiteral("the suggestions are the dev servers running on the MC's machine"), [suggested](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return suggested(world, QStringLiteral("server")) == QStringList{QStringLiteral("http://localhost:4321"), QStringLiteral("http://localhost:8080")}; },
                  [&] { return QStringLiteral("the MC's servers; the tab suggests %1").arg(show(model(world).suggestions())); });
    expect(model(world).suggestions().size() == 2, show(model(world).suggestions()));
    // Asked of the MC that serves the thread, by name.
    const QList<int> watchers = world.mc.subscribers(QStringLiteral("localServers"));
    expect(watchers.size() == 1 && world.mc.shapeOf(watchers.first()).value(QLatin1String("mc")) == world.mc.name,
           QStringLiteral("%1 watch the MC's servers").arg(watchers.size()));
    // And the MC's list is followed as it changes.
    FakePreviews& fake = world.mc.part<FakePreviews>();
    fake.servers.removeLast();
    world.mc.send({{QStringLiteral("t"), QStringLiteral("localServers")}, {QStringLiteral("id"), watchers.first()},
                   {QStringLiteral("list"), QJsonObject{{QStringLiteral("servers"), fake.servers}, {QStringLiteral("scannedAt"), QStringLiteral("2026-09-23T10:00:05Z")}}}});
    world.waitFor([&] { return suggested(world, QStringLiteral("server")) == QStringList{QStringLiteral("http://localhost:4321")}; },
                  [&] { return show(model(world).suggestions()); });
  });

  // Closing.
  step(QStringLiteral("the MC refuses to close a browser tab"), [](World& world, const Captures&, const Table&) {
    haveTabs(world, {QStringLiteral("http://localhost:5173"), QStringLiteral("http://localhost:6006")});
    world.mc.part<FakePreviews>().refuseClose = true;
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
    world.mc.part<FakePreviews>().holdClose = true;
    model(world).close(tabIdOf(world, QStringLiteral("http://localhost:5173")));
    world.sync();
  });
  step(QStringLiteral("the tab disappears at once, even if an older update about it arrives"), [](World& world, const Captures&, const Table&) {
    expect(urls(world).isEmpty(), describe(world));
    // The page finished loading before the close reached the MC.
    FakePreviews& fake = world.mc.part<FakePreviews>();
    QJsonObject tab = fake.tabs.first();
    tab.insert(QStringLiteral("navStatus"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("Success")}, {QStringLiteral("url"), QStringLiteral("http://localhost:5173")},
                                                        {QStringLiteral("title"), QStringLiteral("Vite")}});
    emitEvent(world.mc, tab, QStringLiteral("navigated"), {{QStringLiteral("snapshot"), tab}});
    world.sync();
    expect(urls(world).isEmpty(), describe(world));
    world.mc.answerHeld();
    world.sync();
    expect(urls(world).isEmpty() && world.mc.part<FakePreviews>().tabs.isEmpty(), describe(world));
  });
});

}  // namespace
