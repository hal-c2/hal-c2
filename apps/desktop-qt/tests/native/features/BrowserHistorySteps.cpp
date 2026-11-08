// The pages a new browser tab suggests (ThreadPreviews::suggestions over
// PreviewHistory): the pages the device's tabs visited, per project, as the
// fake MC's tab snapshots say they loaded, with the servers and configured
// addresses beside them. features/preview/surfaces.feature.

#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QTimeZone>
#include <QUrl>

#include <optional>

#include "Brick.h"
#include "Browsing.h"
#include "Harness.h"
#include "Preview.h"
#include "PreviewHistory.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "Stream.h"
#include "ThreadPreviews.h"
#include "World.h"

namespace {

using namespace stream;
using preview::model;

// When the pages loaded: a second apart, the first an hour ago.
struct Visits {
  qint64 clock = 0;
  // The pages of "the same page twice", in the order visited.
  QStringList visited;
  // The page visited before the scenario, as visited() kept it.
  PreviewHistory::Page before;
};

QString projectKey(World& world, const QString& project = kProject) {
  return world.mc.environmentId + QLatin1Char(':') + project;
}

PreviewHistory history(World& world) {
  return PreviewHistory::fromVariant(world.native().controller<SettingsController>()->deviceValue(QStringLiteral("previewHistory")));
}

QString iso(qint64 ms) {
  return QDateTime::fromMSecsSinceEpoch(ms, QTimeZone::UTC).toString(Qt::ISODateWithMs);
}

qint64 tick(World& world) {
  Visits& visits = world.mc.part<Visits>();
  if (visits.clock == 0) visits.clock = QDateTime::currentMSecsSinceEpoch() - 3600 * 1000;
  return visits.clock += 1000;
}

// The device visited `url` in the project `ago` ms before the world's now, before the scenario.
void visited(World& world, const QString& url, const QString& title, qint64 ago) {
  PreviewHistory kept = history(world);
  world.mc.part<Visits>().before = {url, title, world.now().toMSecsSinceEpoch() - ago};
  kept.visit(projectKey(world), url, title, world.now().toMSecsSinceEpoch() - ago);
  auto* settings = world.native().controller<SettingsController>();
  expect(settings->writeDevice(QStringLiteral("previewHistory"), kept.toVariant()), settings->deviceError());
}

// The MC's browser tab of `thread` loaded `url`, titled `title`, just now:
// its snapshot changes, and its watchers hear.
void load(World& world, const QString& thread, const QString& url, const QString& title = {}) {
  FakePreviews& fake = world.mc.part<FakePreviews>();
  qsizetype at = 0;
  while (at < fake.tabs.size() && fake.tabs.at(at).value(QLatin1String("threadId")).toString() != thread) ++at;
  if (at == fake.tabs.size()) {
    QJsonObject tab = preview::tabAt(url, int(fake.tabs.size()) + 1);
    tab.insert(QStringLiteral("threadId"), thread);
    fake.tabs.append(tab);
  }
  QJsonObject& tab = fake.tabs[at];
  tab.insert(QStringLiteral("navStatus"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("Success")}, {QStringLiteral("url"), url}, {QStringLiteral("title"), title}});
  tab.insert(QStringLiteral("updatedAt"), iso(tick(world)));
  preview::emitEvent(world.mc, tab, QStringLiteral("navigated"), {{QStringLiteral("snapshot"), tab}});
}

// The MC is reached and the thread's pages show in tabs here, so its tabs are followed while it shows.
void follow(World& world) {
  FakePreviews& fake = world.mc.part<FakePreviews>();
  if (fake.looking) return;
  fake.looking = true;
  webtab::embed(world);
  world.connect();
  world.sync();
}

// Looks at `thread` of `project`, and waits for its tabs to be listed.
void lookAt(World& world, const QString& thread, const QString& project = kProject) {
  follow(world);
  if (!world.mc.projects.contains(project)) {
    world.mc.projects.insert(project, {{QStringLiteral("id"), project}, {QStringLiteral("title"), project},
                                       {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + project}, {QStringLiteral("scripts"), QJsonArray()}});
  }
  world.mc.sendRow(project, world.mc.projects.value(project), QStringLiteral("project"));
  world.mc.threads.insert(thread, {{QStringLiteral("id"), thread}, {QStringLiteral("title"), thread}, {QStringLiteral("projectId"), project},
                                   {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  world.mc.sendRow(thread, world.mc.threads.value(thread));
  world.sync();
  FakeStreams& streams = world.mc.part<FakeStreams>();
  streams.thread = thread;
  streams.environment = world.mc.environmentId;
  const int lists = world.mc.part<FakePreviews>().lists;
  look(world, world.mc.environmentId + QLatin1Char(':') + thread);
  world.waitFor([&] { return model(world).threadId() == thread && model(world).status() == QLatin1String("ready") && world.mc.part<FakePreviews>().lists > lists; },
                [&] { return preview::describe(world); });
  world.sync();
}

// Opens an empty browser tab in the thread shown, and waits for the MC to have it.
void openNewTab(World& world) {
  const int rows = model(world).rowCount();
  world.bridge().dispatch(QStringLiteral("rightPanel.add"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("browser")}});
  world.waitFor([&] { return model(world).rowCount() == rows + 1 && !model(world).emptyTab().isEmpty(); }, [&] { return preview::describe(world); });
  world.sync();
}

QVariantList recent(World& world) {
  QVariantList found;
  for (const QVariant& suggestion : model(world).suggestions()) {
    if (suggestion.toMap().value(QStringLiteral("kind")) == QLatin1String("recent")) found.append(suggestion);
  }
  return found;
}

QStringList recentUrls(World& world) {
  QStringList urls;
  for (const QVariant& page : recent(world)) urls.append(page.toMap().value(QStringLiteral("url")).toString());
  return urls;
}

QString describeRecent(World& world) {
  return QStringLiteral("the recent pages are %1").arg(show(recent(world)));
}

// A drawn row of the start page: what it suggests and how it reads.
struct Row {
  QQuickItem* item = nullptr;
  QVariantMap suggestion;
  QString title;
  QString detail;
  QQuickItem* forget = nullptr;
};

QQuickItem* named(QQuickItem* item, const QString& objectName, bool prefix = false) {
  if (prefix ? item->objectName().startsWith(objectName) : item->objectName() == objectName) return item;
  for (QQuickItem* child : item->childItems()) {
    if (QQuickItem* found = named(child, objectName, prefix)) return found;
  }
  return nullptr;
}

void collect(QQuickItem* item, QList<Row>& rows) {
  if (!item->isVisible()) return;
  static const QRegularExpression row(QStringLiteral("^browserSuggestion-\\d+$"));
  if (row.match(item->objectName()).hasMatch()) {
    Row found{item, item->property("modelData").toMap()};
    if (QQuickItem* title = named(item, QStringLiteral("browserSuggestionTitle"))) found.title = title->property("text").toString();
    if (QQuickItem* detail = named(item, QStringLiteral("browserSuggestionDetail"))) found.detail = detail->property("text").toString();
    found.forget = named(item, QStringLiteral("browserSuggestionForget-"), true);
    rows.append(found);
    return;
  }
  for (QQuickItem* child : item->childItems()) collect(child, rows);
}

// The start page's rows as drawn in the tab showing.
QList<Row> rows(World& world) {
  QList<Row> found;
  if (world.brick) collect(world.brick->window().contentItem(), found);
  return found;
}

QString describeRows(World& world) {
  QStringList shown;
  for (const Row& row : rows(world)) shown.append(QStringLiteral("%1 | %2 (%3)").arg(row.title, row.detail, row.suggestion.value(QStringLiteral("url")).toString()));
  return QStringLiteral("the start page lists %1").arg(shown.isEmpty() ? QStringLiteral("nothing") : shown.join(QStringLiteral("; ")));
}

std::optional<Row> rowFor(World& world, const QString& url) {
  for (const Row& row : rows(world)) {
    if (row.suggestion.value(QStringLiteral("url")) == url) return row;
  }
  return std::nullopt;
}

// The new tab's start page, drawn in the side panel.
void startPage(World& world) {
  webtab::waitForTab(world);
  world.waitFor([&] { QQuickItem* start = world.brick->find(QStringLiteral("browserStart")); return start && start->isVisible(); },
                QStringLiteral("the start page to show"));
  world.sync();
}

const Steps steps([] {
  const QString q = kQuoted;
  // What a new tab offers.
  step(QStringLiteral("the thread's project has no running dev server and no recent pages"), [](World& world, const Captures&, const Table&) {
    webtab::drawEmbedded(world);
    expect(history(world).pages(projectKey(world)).isEmpty(), QStringLiteral("the project has recent pages"));
  });
  step(QStringLiteral("the new tab says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startPage(world);
    expect(world.brick->shows(c[0]), QStringLiteral("the tab does not say \"%1\"; %2").arg(c[0], describeRows(world)));
  });
  step(QStringLiteral("it says to type a URL above or run a dev script and that localhost servers will show up automatically"), [](World& world, const Captures&, const Table&) {
    expect(world.brick->shows(QStringLiteral("Type a URL above or run a dev script. Servers on localhost show up here automatically.")),
           QStringLiteral("the start page does not say how to start"));
    expect(rows(world).isEmpty(), describeRows(world));
  });
  step(QStringLiteral("the user visited %1 titled %1 a few minutes ago").arg(q), [](World& world, const Captures& c, const Table&) {
    visited(world, c[0], c[1], 5 * 60 * 1000 + 20 * 1000);
    webtab::drawEmbedded(world);
  });
  step(QStringLiteral("the user visited %1 which has no title").arg(q), [](World& world, const Captures& c, const Table&) {
    visited(world, c[0], QString(), 5 * 60 * 1000);
    webtab::drawEmbedded(world);
  });
  step(QStringLiteral("the page is listed as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startPage(world);
    world.waitFor([&] { const QList<Row> listed = rows(world); return listed.size() == 1 && listed.first().title == c[0]; }, [&] { return describeRows(world); });
  });
  step(QStringLiteral("beneath it are %1 and how long ago it was visited").arg(q), [](World& world, const Captures& c, const Table&) {
    const Row row = rows(world).value(0);
    expect(row.detail == c[0] + QStringLiteral(" · 5m ago"), describeRows(world));
  });
  step(QStringLiteral("another browser tab of the thread showing that page is resized"), [](World& world, const Captures&, const Table&) {
    const PreviewHistory::Page& page = world.mc.part<Visits>().before;
    FakePreviews& fake = world.mc.part<FakePreviews>();
    // The tab loaded the page when it was visited...
    QJsonObject tab = preview::tabAt(page.url, int(fake.tabs.size()) + 1);
    tab.insert(QStringLiteral("navStatus"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("Success")}, {QStringLiteral("url"), page.url}, {QStringLiteral("title"), page.title}});
    tab.insert(QStringLiteral("updatedAt"), iso(page.at));
    fake.tabs.append(tab);
    preview::emitEvent(world.mc, tab, QStringLiteral("navigated"), {{QStringLiteral("snapshot"), tab}});
    world.sync();
    // ...and is resized now, which the MC stamps too (preview.ex resize).
    tab.insert(QStringLiteral("viewport"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("device")}, {QStringLiteral("width"), 390}, {QStringLiteral("height"), 844}});
    tab.insert(QStringLiteral("updatedAt"), iso(world.now().toMSecsSinceEpoch()));
    fake.tabs.last() = tab;
    preview::emitEvent(world.mc, tab, QStringLiteral("resized"), {{QStringLiteral("snapshot"), tab}});
    world.sync();
  });
  step(QStringLiteral("the row still says when the page was visited, not when the tab was resized"), [](World& world, const Captures&, const Table&) {
    const PreviewHistory::Page& page = world.mc.part<Visits>().before;
    const Row row = rows(world).value(0);
    expect(row.detail == PreviewHistory::shown(PreviewHistory::tidy(page.url)) + QStringLiteral(" · 5m ago"), describeRows(world));
  });
  step(QStringLiteral("the device kept the recent pages %1 and %1 before it kept them per project").arg(q), [](World& world, const Captures& c, const Table&) {
    auto* settings = world.native().controller<SettingsController>();
    expect(settings->writeDevice(QStringLiteral("previewRecentPages"), QStringList{c[0], c[1]}), settings->deviceError());
    webtab::drawEmbedded(world);
  });
  step(QStringLiteral("the pages are listed as %1 then %1, with no time to show").arg(q), [](World& world, const Captures& c, const Table&) {
    startPage(world);
    world.waitFor([&] { const QList<Row> listed = rows(world); return listed.size() == 2 && listed.at(0).detail == c[0] && listed.at(1).detail == c[1]; },
                  [&] { return describeRows(world); });
  });
  step(QStringLiteral("the device keeps them under the project from now on"), [](World& world, const Captures&, const Table&) {
    auto* settings = world.native().controller<SettingsController>();
    expect(!settings->deviceValue(QStringLiteral("previewRecentPages")).isValid(), show(settings->deviceValue(QStringLiteral("previewRecentPages"))));
    expect(history(world).pages(projectKey(world)).size() == 2, show(settings->deviceValue(QStringLiteral("previewHistory"))));
  });
  step(QStringLiteral("the row offers to remove it from history"), [](World& world, const Captures&, const Table&) {
    const Row row = rows(world).value(0);
    expect(row.forget && row.forget->isVisible() && row.forget->objectName() == QLatin1String("browserSuggestionForget-0"), describeRows(world));
  });
  step(QStringLiteral("a new browser tab lists the recent page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    visited(world, c[0], QString(), 60 * 1000);
    webtab::drawEmbedded(world);
    openNewTab(world);
    startPage(world);
    world.waitFor([&] { return rowFor(world, c[0]).has_value(); }, [&] { return describeRows(world); });
  });
  step(QStringLiteral("the user removes %1 from the recent pages").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto row = rowFor(world, c[0]);
    expect(row && row->forget, describeRows(world));
    world.brick->click(row->forget->objectName());
  });
  step(QStringLiteral("the page is no longer listed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return rows(world).isEmpty() && recent(world).isEmpty(); }, [&] { return describeRows(world); });
  });
  step(QStringLiteral("it does not come back when the user opens another new tab"), [](World& world, const Captures&, const Table&) {
    openNewTab(world);
    startPage(world);
    expect(rows(world).isEmpty() && recent(world).isEmpty(), describeRows(world));
    expect(history(world).pages(projectKey(world)).isEmpty(), QStringLiteral("the device still keeps the page"));
  });
  step(QStringLiteral("%1 is visited again on an MC whose clock is behind this device's").arg(q), [](World& world, const Captures& c, const Table&) {
    // The MC stamps the load just after the scenario's now, weeks before this device's clock.
    world.mc.part<Visits>().clock = world.now().toMSecsSinceEpoch();
    expect(world.now().toMSecsSinceEpoch() < QDateTime::currentMSecsSinceEpoch(), QStringLiteral("the MC's clock is not behind this device's"));
    load(world, kThread, c[0]);
  });
  step(QStringLiteral("a thread on another MC, whose clock is ahead, has a page open"), [](World& world, const Captures&, const Table&) {
    FakePreviews& fake = world.mc.part<FakePreviews>();
    QJsonObject tab = preview::tabAt(QStringLiteral("http://localhost:4000/ahead"), int(fake.tabs.size()) + 1);
    tab.insert(QStringLiteral("threadId"), stream::kPeerThread);
    tab.insert(QStringLiteral("updatedAt"), QStringLiteral("2031-01-01T00:00:00Z"));
    fake.tabs.append(tab);
    ++fake.revision;
    world.mc.join(stream::kPeer, stream::kPeerEnvironment);
    world.sync();
    preview::lookAtPeerThread(world);
    world.waitFor([&] { return model(world).threadId() == stream::kPeerThread && model(world).status() == QLatin1String("ready") && model(world).rowCount() == 1; },
                  [&] { return preview::describe(world); });
  });
  step(QStringLiteral("the user goes back to the thread"), [](World& world, const Captures&, const Table&) {
    lookAt(world, kThread);
    startPage(world);
  });
  step(QStringLiteral("a new tab lists %1 again").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return history(world).pages(projectKey(world)).value(0).url == c[0]; }, [&] { return show(history(world).toVariant()); });
    openNewTab(world);
    startPage(world);
    world.waitFor([&] { return rowFor(world, c[0]).has_value(); }, [&] { return describeRows(world); });
  });
  step(QStringLiteral("the project configures %1 and %1 as preview addresses").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonArray scripts;
    for (const QString& url : {c[0], c[1]}) {
      scripts.append(QJsonObject{{QStringLiteral("id"), QStringLiteral("dev-%1").arg(scripts.size())}, {QStringLiteral("name"), QStringLiteral("Dev")},
                                 {QStringLiteral("command"), QStringLiteral("bun dev")}, {QStringLiteral("icon"), QStringLiteral("play")},
                                 {QStringLiteral("runOnWorktreeCreate"), false}, {QStringLiteral("previewUrl"), url}});
    }
    world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject},
                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + kProject}, {QStringLiteral("scripts"), scripts}});
    lookAt(world, kThread);
  });
  step(QStringLiteral("the page %1 is suggested once, with the anchor of the first").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString first = world.mc.projects.value(kProject).value(QLatin1String("scripts")).toArray().first().toObject().value(QLatin1String("previewUrl")).toString();
    QStringList configured;
    for (const QVariant& suggestion : model(world).suggestions()) {
      if (suggestion.toMap().value(QStringLiteral("kind")) == QLatin1String("configured")) configured.append(suggestion.toMap().value(QStringLiteral("url")).toString());
    }
    expect(configured == QStringList{first} && QUrl(first).adjusted(QUrl::RemoveFragment).toString() == c[0], show(model(world).suggestions()));
  });

  // Opening a suggested server.
  step(QStringLiteral("a new browser tab suggests a dev server on port (\\d+)"), [](World& world, const Captures& c, const Table&) {
    // The test's own server stands in for the port named: nothing else on this machine is loaded.
    Q_UNUSED(c);
    const QString url = webtab::serverUrl(world);
    world.mc.part<FakePreviews>().servers = QJsonArray{QJsonObject{{QStringLiteral("host"), QStringLiteral("localhost")}, {QStringLiteral("port"), QUrl(url).port()},
                                                                   {QStringLiteral("url"), url}, {QStringLiteral("processName"), QStringLiteral("vite")},
                                                                   {QStringLiteral("pid"), 4242}, {QStringLiteral("terminal"), QJsonValue::Null}}};
    webtab::drawEmbedded(world);
    openNewTab(world);
    startPage(world);
    world.waitFor([&] { return rowFor(world, url).has_value(); }, [&] { return describeRows(world); });
    world.mc.part<Visits>().visited = {url};
  });
  step(QStringLiteral("the user opens the suggestion"), [](World& world, const Captures&, const Table&) {
    const auto row = rowFor(world, world.mc.part<Visits>().visited.value(0));
    expect(row.has_value(), describeRows(world));
    world.brick->click(row->item->objectName());
  });
  step(QStringLiteral("the page opens in a browser tab beside the thread"), [](World& world, const Captures&, const Table&) {
    const QString url = world.mc.part<Visits>().visited.value(0);
    FakePreviews& fake = world.mc.part<FakePreviews>();
    world.waitFor([&] { return !fake.navigations.isEmpty() && fake.navigations.last().value(QLatin1String("url")).toString().startsWith(url); },
                  [&] { return preview::describe(world); });
    webtab::waitForEngine(world, [&] { QQuickItem* view = world.brick->find(QStringLiteral("browserView"));
                                     return view && view->property("url").toUrl().toString().startsWith(url); },
                          [&] { return preview::describe(world); });
    expect(world.openedUrls.isEmpty(), QStringLiteral("the user's browser opened %1").arg(show(QVariant::fromValue(world.openedUrls))));
  });
  step(QStringLiteral("the server is remembered among the recent pages"), [](World& world, const Captures&, const Table&) {
    const QString url = world.mc.part<Visits>().visited.value(0);
    world.waitFor([&] { return history(world).pages(projectKey(world)).value(0).url == PreviewHistory::tidy(url); }, QStringLiteral("the server to be remembered"));
  });

  // Visits, filed per project.
  step(QStringLiteral("the user visits %1 in a browser tab of a project").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, kThread);
    load(world, kThread, c[0]);
    world.waitFor([&] { return history(world).pages(projectKey(world)).value(0).url == c[0]; }, QStringLiteral("the visit to be remembered"));
  });
  step(QStringLiteral("the user visited %1 in a project's browser tab").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, kThread);
    load(world, kThread, c[0]);
    world.waitFor([&] { return history(world).pages(projectKey(world)).value(0).url == c[0]; }, QStringLiteral("the visit to be remembered"));
  });
  step(QStringLiteral("the user opens a new browser tab in another thread of that project"), [](World& world, const Captures&, const Table&) {
    lookAt(world, QStringLiteral("thread-2"));
    openNewTab(world);
  });
  step(QStringLiteral("the user opens a new browser tab in a different project"), [](World& world, const Captures&, const Table&) {
    lookAt(world, QStringLiteral("thread-garden"), QStringLiteral("garden"));
    openNewTab(world);
  });
  step(QStringLiteral("%1 is among the recent pages").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return recentUrls(world).contains(c[0]); }, [&] { return describeRecent(world); });
  });
  step(QStringLiteral("%1 is not among the recent pages").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(!recentUrls(world).contains(c[0]), describeRecent(world));
  });
  step(QStringLiteral("the user visits %1 titled %1 in a browser tab of a thread of the project").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, kThread);
    load(world, kThread, c[0], c[1]);
    world.waitFor([&] { return history(world).pages(projectKey(world)).value(0).title == c[1]; }, QStringLiteral("the visit to be remembered"));
  });
  step(QStringLiteral("the user restarts HAL-C2 and opens a new browser tab in that project"), [](World& world, const Captures&, const Table&) {
    // The MC keeps no tab of it: what is suggested is what the device kept.
    world.mc.part<FakePreviews>().tabs.clear();
    world.restart();
    webtab::embed(world);
    world.connect();
    world.sync();
    lookAt(world, kThread);
    openNewTab(world);
  });
  step(QStringLiteral("%1 at %1 is among the recent pages").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QVariant& page : recent(world)) {
        if (page.toMap().value(QStringLiteral("url")) == c[1] && page.toMap().value(QStringLiteral("title")) == c[0]) return true;
      }
      return false;
    }, [&] { return describeRecent(world); });
  });
  step(QStringLiteral("an agent loads %1 titled %1 in a thread's browser tab").arg(q), [](World& world, const Captures& c, const Table&) {
    // The tab was open before; the side panel is not.
    FakePreviews& fake = world.mc.part<FakePreviews>();
    QJsonObject tab = preview::tabAt(QString(), 1);
    tab.insert(QStringLiteral("navStatus"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("Idle")}});
    fake.tabs.append(tab);
    lookAt(world, kThread);
    load(world, kThread, c[0], c[1]);
  });
  step(QStringLiteral("the browser is not shown for that thread"), [](World& world, const Captures&, const Table&) {
    RightPanelController* panel = world.native().controller<RightPanelController>();
    expect(!panel->isOpen() || !panel->activeTab().startsWith(QLatin1String("browser:")), show(world.state(QStringLiteral("panel"))));
  });
  step(QStringLiteral("the user opens a new browser tab in that project"), [](World& world, const Captures&, const Table&) {
    openNewTab(world);
  });
  step(QStringLiteral("%1 is the title of %1 among the recent pages").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (const QVariant& page : recent(world)) {
        if (page.toMap().value(QStringLiteral("url")) == c[1]) return page.toMap().value(QStringLiteral("title")) == c[0];
      }
      return false;
    }, [&] { return describeRecent(world); });
  });
  step(QStringLiteral("thread %1 loaded %1 titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString thread = QStringLiteral("thread-") + c[0];
    follow(world);
    load(world, thread, c[1], c[2]);
    lookAt(world, thread);
    world.waitFor([&] { return history(world).pages(projectKey(world)).value(0).title == c[2]; }, QStringLiteral("the visit to be remembered"));
  });
  step(QStringLiteral("thread %1 of the same project later loaded it titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString thread = QStringLiteral("thread-") + c[0];
    load(world, thread, history(world).pages(projectKey(world)).value(0).url, c[1]);
    lookAt(world, thread);
    world.waitFor([&] { return history(world).pages(projectKey(world)).value(0).title == c[1]; }, QStringLiteral("the later visit to be remembered"));
  });
  step(QStringLiteral("the user switches back to thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // Its tab is listed again, with the title it last had.
    lookAt(world, QStringLiteral("thread-") + c[0]);
  });
  step(QStringLiteral("%1 is titled %1 among the recent pages").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto pages = history(world).pages(projectKey(world));
    expect(pages.size() == 1 && pages.first().url == c[0] && pages.first().title == c[1],
           QStringLiteral("the device keeps \"%1\" for %2").arg(pages.value(0).title, pages.value(0).url));
    expect(recent(world).value(0).toMap().value(QStringLiteral("title")) == c[1], describeRecent(world));
  });

  // Kept tidy, and bounded.
  step(QStringLiteral("the user visits %1 then %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, kThread);
    load(world, kThread, c[0]);
    load(world, kThread, c[1]);
    world.waitFor([&] { return history(world).pages(projectKey(world)).value(0).at == world.mc.part<Visits>().clock; }, QStringLiteral("the visits to be remembered"));
  });
  step(QStringLiteral("the user visits %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAt(world, kThread);
    load(world, kThread, c[0]);
    world.waitFor([&] { return history(world).pages(projectKey(world)).value(0).at == world.mc.part<Visits>().clock; }, QStringLiteral("the visit to be remembered"));
  });
  step(QStringLiteral("the user visits the same page twice"), [](World& world, const Captures&, const Table&) {
    lookAt(world, kThread);
    QStringList& visited = world.mc.part<Visits>().visited;
    visited = {QStringLiteral("http://localhost:5173/a"), QStringLiteral("http://localhost:5173/b"), QStringLiteral("http://localhost:5173/a")};
    for (const QString& url : std::as_const(visited)) load(world, kThread, url);
    world.waitFor([&] { return history(world).pages(projectKey(world)).value(0).at == world.mc.part<Visits>().clock; }, QStringLiteral("the visits to be remembered"));
  });
  step(QStringLiteral("the recent pages list one page for that local server"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(recentUrls(world) == QStringList{QStringLiteral("http://localhost:5173")}, describeRecent(world));
  });
  step(QStringLiteral("the recent pages list %1 without credentials").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(recentUrls(world) == QStringList{c[0]}, describeRecent(world));
    expect(!show(world.native().controller<SettingsController>()->deviceValue(QStringLiteral("previewHistory"))).contains(QLatin1String("secret")),
           QStringLiteral("the device keeps the password"));
  });
  step(QStringLiteral("the recent pages list the page once, as the most recent"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(recentUrls(world) == QStringList{QStringLiteral("http://localhost:5173/a"), QStringLiteral("http://localhost:5173/b")}, describeRecent(world));
  });
  step(QStringLiteral("the user has visited fifty one different pages in a project"), [](World& world, const Captures&, const Table&) {
    lookAt(world, kThread);
    for (int n = 1; n <= 51; ++n) load(world, kThread, QStringLiteral("http://localhost:5173/page-%1").arg(n));
    world.waitFor([&] { return history(world).pages(projectKey(world)).value(0).url == QLatin1String("http://localhost:5173/page-51"); },
                  QStringLiteral("the visits to be remembered"));
  });
  step(QStringLiteral("the recent pages remember the fifty most recent ones"), [](World& world, const Captures&, const Table&) {
    const auto pages = history(world).pages(projectKey(world));
    expect(pages.size() == 50 && pages.first().url == QLatin1String("http://localhost:5173/page-51") && pages.last().url == QLatin1String("http://localhost:5173/page-2"),
           QStringLiteral("the device keeps %1 pages, %2 to %3").arg(pages.size()).arg(pages.value(0).url, pages.value(pages.size() - 1).url));
    // A new tab shows the newest ten of them.
    expect(recent(world).size() == ThreadPreviews::maxRecents, describeRecent(world));
  });
  step(QStringLiteral("the user has browsed in twenty one projects"), [](World& world, const Captures&, const Table&) {
    follow(world);
    for (int n = 1; n <= 21; ++n) {
      const QString thread = QStringLiteral("thread-p%1").arg(n);
      load(world, thread, QStringLiteral("http://localhost:5173/p%1").arg(n));
      lookAt(world, thread, QStringLiteral("project-%1").arg(n));
      world.waitFor([&] { return history(world).projects().value(0) == projectKey(world, QStringLiteral("project-%1").arg(n)); },
                    QStringLiteral("the visit to be remembered"));
    }
  });
  step(QStringLiteral("the history of the project used longest ago is forgotten"), [](World& world, const Captures&, const Table&) {
    const QStringList projects = history(world).projects();
    expect(projects.size() == PreviewHistory::projectsKept && !projects.contains(projectKey(world, QStringLiteral("project-1"))) &&
               projects.contains(projectKey(world, QStringLiteral("project-2"))),
           show(projects));
  });
});

}  // namespace
