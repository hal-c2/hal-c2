// What MC plugins add to the desktop (features/plugins/plugin-contributions.feature):
// a fake MC's `plugins` shape and `plugins.*` calls, the plugin "code-review"
// with a page, thread looks, a sidebar section and a settings page of its own,
// and the real DefaultShell window that draws them.

#include <QBuffer>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QJsonArray>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>

#include "CommandPaletteController.h"
#include "Harness.h"
#include "Keymap.h"
#include "NativeShell.h"
#include "Plugins.h"
#include "ThreadList.h"
#include "World.h"

namespace {

const QString kCodeReview = QStringLiteral("code-review");
const QString kReviewThread = QStringLiteral("t-review");
const QString kReviewTitle = QStringLiteral("Review acme/shop#7");
const QString kMarker = QStringLiteral("••••••");

// The plugins each environment's MC runs, the files of their packages, and
// what one of them publishes.
struct FakeMcPlugins {
  QHash<QString, QList<QJsonObject>> plugins;
  // "<revision>/<path>", or "*/<path>" for every revision.
  QHash<QString, QByteArray> files;
  // What `plugins.saveSettings` refuses with, when it does.
  QString refusal;
  QJsonArray reviews;
  // Plugins faked by other steps, by id.
  QHash<QString, FakePluginPart> parts;
  // The page a scenario keeps an eye on, to tell a reload from an update.
  QPointer<QQuickItem> page;
};

QString environmentOf(const FakeMc& mc, const QString& environment) {
  return environment.isEmpty() ? mc.environmentId : environment;
}

QByteArray png() {
  QImage image(4, 4, QImage::Format_RGB32);
  image.fill(Qt::darkCyan);
  QBuffer buffer;
  buffer.open(QIODevice::WriteOnly);
  image.save(&buffer, "PNG");
  return buffer.data();
}

QByteArray reviewsSource(const QString& version) {
  return QStringLiteral(R"(import QtQuick

Item {
    id: page

    property var plugin
    property string version: "%1"
    property string filter: "all"
    property var reviews: []
    property string answer: ""
    property int seen: -1

    function ask(environment) {
        page.answer = "";
        page.plugin.call("reviews", { state: "failed" }, (result, error) => page.answer = error ? "error: " + error : result.from, environment || undefined);
    }

    function watchAgain(topic) {
        page.plugin.watch(topic, value => page.seen = value.length);
    }

    function open(threadId) {
        page.plugin.openThread(threadId);
    }

    objectName: "reviewsPage"
    implicitWidth: 400
    implicitHeight: 300
    Component.onCompleted: page.plugin.watch("reviews", value => page.reviews = value)

    Column {
        Text { objectName: "reviewsEnvironments"; text: page.plugin.environments.join(",") }
        Text { objectName: "reviewsList"; text: page.reviews.filter(review => page.filter === "all" || review.state === page.filter).map(review => review.title).join(", ") }
        Text { text: "v" + page.version }
    }
}
)")
      .arg(version)
      .toUtf8();
}

// A part that draws `text`, made with the thread it is for when it has one.
QByteArray textPart(const QString& text) {
  return QStringLiteral("import QtQuick\nText {\n    property var plugin\n    property var thread\n    text: %1\n}\n").arg(text).toUtf8();
}

const FakeMc::Extension extension([](FakeMc& mc) {
  FakeMcPlugins& fake = mc.part<FakeMcPlugins>();
  fake.files.insert(QStringLiteral("*/icon.png"), png());
  fake.files.insert(QStringLiteral("*/screenshots/queue.png"), png());
  fake.files.insert(QStringLiteral("*/pages/Reviews.qml"), reviewsSource(QStringLiteral("1")));
  fake.files.insert(QStringLiteral("2/pages/Reviews.qml"), reviewsSource(QStringLiteral("2")));
  fake.files.insert(QStringLiteral("*/threads/ReviewMark.qml"), textPart(QStringLiteral("\"[review mark]\"")));
  fake.files.insert(QStringLiteral("*/threads/ReviewHeader.qml"), textPart(QStringLiteral("thread ? \"Reviewing \" + thread.title : \"\"")));
  fake.files.insert(QStringLiteral("*/slots/Section.qml"), textPart(QStringLiteral("\"[code-review section]\"")));
  fake.files.insert(QStringLiteral("*/settings/Settings.qml"), textPart(QStringLiteral("\"[code-review settings]\"")));
  fake.reviews = QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("Add cache")}, {QStringLiteral("state"), QStringLiteral("passed")}},
                            QJsonObject{{QStringLiteral("title"), QStringLiteral("Fix login")}, {QStringLiteral("state"), QStringLiteral("failed")}}};

  mc.onShape(QStringLiteral("plugins"), [&mc](int id, const QJsonObject& shape) {
    const QString environment = environmentOf(mc, shape.value(QLatin1String("environment")).toString());
    QJsonArray plugins;
    for (const QJsonObject& entry : mc.part<FakeMcPlugins>().plugins.value(environment)) plugins.append(entry);
    mc.send({{QStringLiteral("t"), QStringLiteral("plugins")}, {QStringLiteral("id"), id}, {QStringLiteral("plugins"), plugins}});
  });
  mc.onShape(QStringLiteral("plugin"), [&mc](int id, const QJsonObject& shape) {
    const QString topic = shape.value(QLatin1String("topic")).toString();
    if (const auto part = mc.part<FakeMcPlugins>().parts.find(shape.value(QLatin1String("id")).toString()); part != mc.part<FakeMcPlugins>().parts.end()) {
      if (part->topics.contains(topic)) mc.send({{QStringLiteral("t"), QStringLiteral("plugin")}, {QStringLiteral("id"), id}, {QStringLiteral("topic"), topic}, {QStringLiteral("value"), part->topics.value(topic)}});
      return;
    }
    if (topic != QLatin1String("reviews")) return;
    mc.send({{QStringLiteral("t"), QStringLiteral("plugin")}, {QStringLiteral("id"), id}, {QStringLiteral("topic"), QStringLiteral("reviews")},
             {QStringLiteral("value"), mc.part<FakeMcPlugins>().reviews}});
  });
  mc.onRpc(QStringLiteral("plugins."), [&mc](const FakeMc::Rpc& rpc) {
    FakeMcPlugins& fake = mc.part<FakeMcPlugins>();
    const QString environment = environmentOf(mc, rpc.environment);
    const QString id = rpc.payload.value(QLatin1String("id")).toString();
    QList<QJsonObject>& plugins = fake.plugins[environment];
    const auto entry = std::find_if(plugins.begin(), plugins.end(), [&](const QJsonObject& each) { return each.value(QLatin1String("id")) == id; });
    if (entry == plugins.end()) return mc.refuse(rpc, QStringLiteral("unknown plugin %1").arg(id));
    const QString revision = entry->value(QLatin1String("revision")).toString();
    const auto changed = [&](const QString& status) {
      entry->insert(QStringLiteral("status"), status);
      mc.reply(rpc, *entry);
      for (const int subscriber : mc.subscribers(QStringLiteral("plugins"))) {
        if (environmentOf(mc, mc.shapeOf(subscriber).value(QLatin1String("environment")).toString()) != environment) continue;
        QJsonArray list;
        for (const QJsonObject& each : std::as_const(plugins)) list.append(each);
        mc.send({{QStringLiteral("t"), QStringLiteral("plugins")}, {QStringLiteral("id"), subscriber}, {QStringLiteral("plugins"), list}});
      }
    };
    const auto part = fake.parts.constFind(id);
    if (rpc.method == QLatin1String("plugins.file")) {
      const QString path = rpc.payload.value(QLatin1String("path")).toString();
      QByteArray bytes = fake.files.value(revision + QLatin1Char('/') + path, fake.files.value(QStringLiteral("*/") + path));
      if (part != fake.parts.constEnd()) {
        QFile file(QDir(part->package).filePath(path));
        bytes = file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
      }
      if (bytes.isEmpty()) return mc.refuse(rpc, QStringLiteral("%1 is not in the package").arg(path));
      const bool binary = path.endsWith(QLatin1String(".png"));
      mc.reply(rpc, QJsonObject{{QStringLiteral("path"), path},
                                {QStringLiteral("encoding"), binary ? QStringLiteral("base64") : QStringLiteral("utf8")},
                                {QStringLiteral("content"), binary ? QString::fromLatin1(bytes.toBase64()) : QString::fromUtf8(bytes)},
                                {QStringLiteral("revision"), revision}});
    } else if (rpc.method == QLatin1String("plugins.enable") || rpc.method == QLatin1String("plugins.restart")) {
      changed(QStringLiteral("running"));
    } else if (rpc.method == QLatin1String("plugins.disable")) {
      changed(QStringLiteral("disabled"));
    } else if (rpc.method == QLatin1String("plugins.saveSettings")) {
      if (!fake.refusal.isEmpty()) return mc.refuse(rpc, fake.refusal);
      QJsonObject settings = rpc.payload.value(QLatin1String("settings")).toObject();
      // The mask keeps the secret it stands for.
      const QJsonObject before = entry->value(QLatin1String("settings")).toObject();
      for (auto it = settings.begin(); it != settings.end(); ++it) {
        if (it.value() == kMarker) it.value() = before.value(it.key());
      }
      entry->insert(QStringLiteral("saved"), settings);
      changed(entry->value(QLatin1String("status")).toString());
    } else if (rpc.method == QLatin1String("plugins.call")) {
      if (part != fake.parts.constEnd()) return part->call ? part->call(rpc) : mc.refuse(rpc, QStringLiteral("no such call"));
      mc.reply(rpc, QJsonObject{{QStringLiteral("from"), QStringLiteral("Reviews on %1").arg(environment)}});
    } else {
      mc.refuse(rpc, QStringLiteral("no such call"));
    }
  });
});

QJsonObject codeReview() {
  const auto object = [](std::initializer_list<QPair<QString, QJsonValue>> fields) { return QJsonObject(fields); };
  return {
      {QStringLiteral("id"), kCodeReview},
      {QStringLiteral("name"), QStringLiteral("Code review")},
      {QStringLiteral("version"), QStringLiteral("1.0.0")},
      {QStringLiteral("description"), QStringLiteral("Agents review the pull requests of the repositories you choose.")},
      {QStringLiteral("author"), object({{QStringLiteral("name"), QStringLiteral("HAL-C2")}})},
      {QStringLiteral("icon"), QStringLiteral("icon.png")},
      {QStringLiteral("screenshots"), QJsonArray{object({{QStringLiteral("path"), QStringLiteral("screenshots/queue.png")},
                                                         {QStringLiteral("caption"), QStringLiteral("The review queue")}})}},
      {QStringLiteral("status"), QStringLiteral("running")},
      {QStringLiteral("error"), QJsonValue::Null},
      {QStringLiteral("lastError"), QJsonValue::Null},
      {QStringLiteral("revision"), QStringLiteral("1")},
      {QStringLiteral("runsCode"), true},
      {QStringLiteral("permissions"),
       QJsonArray{object({{QStringLiteral("id"), QStringLiteral("pullRequests:write")},
                          {QStringLiteral("label"), QStringLiteral("Comment on pull requests")},
                          {QStringLiteral("reason"), QStringLiteral("It posts the reviews it writes.")},
                          {QStringLiteral("granted"), true}}),
                  object({{QStringLiteral("id"), QStringLiteral("threads:create")},
                          {QStringLiteral("label"), QStringLiteral("Start threads")},
                          {QStringLiteral("reason"), QStringLiteral("Each review runs in a thread of its own.")},
                          {QStringLiteral("granted"), true}})}},
      {QStringLiteral("settingsSchema"),
       QJsonArray{object({{QStringLiteral("key"), QStringLiteral("repos")}, {QStringLiteral("type"), QStringLiteral("list")},
                          {QStringLiteral("label"), QStringLiteral("Repositories")}})}},
      {QStringLiteral("settings"), object({{QStringLiteral("repos"), QJsonArray{QStringLiteral("acme/shop")}}})},
      {QStringLiteral("contributes"),
       object({{QStringLiteral("pages"), QJsonArray{object({{QStringLiteral("id"), QStringLiteral("reviews")},
                                                            {QStringLiteral("title"), QStringLiteral("Reviews")},
                                                            {QStringLiteral("icon"), QStringLiteral("git-pull-request")},
                                                            {QStringLiteral("qml"), QStringLiteral("pages/Reviews.qml")}})}},
               {QStringLiteral("threadKinds"), QJsonArray{object({{QStringLiteral("kind"), QStringLiteral("review")},
                                                                  {QStringLiteral("label"), QStringLiteral("Review")},
                                                                  {QStringLiteral("rowMark"), QStringLiteral("threads/ReviewMark.qml")},
                                                                  {QStringLiteral("header"), QStringLiteral("threads/ReviewHeader.qml")}})}}})},
  };
}

FakeMcPlugins& fake(World& world) { return world.mc.part<FakeMcPlugins>(); }

// Sends each environment's list to the client following it.
void announce(World& world) {
  for (const int subscriber : world.mc.subscribers(QStringLiteral("plugins"))) {
    const QString environment = environmentOf(world.mc, world.mc.shapeOf(subscriber).value(QLatin1String("environment")).toString());
    QJsonArray list;
    for (const QJsonObject& entry : fake(world).plugins.value(environment)) list.append(entry);
    world.mc.send({{QStringLiteral("t"), QStringLiteral("plugins")}, {QStringLiteral("id"), subscriber}, {QStringLiteral("plugins"), list}});
  }
}

// Changes plugin `id` on every MC that runs it, and tells the client.
void change(World& world, const QString& id, const std::function<void(QJsonObject&)>& edit) {
  bool found = false;
  for (QList<QJsonObject>& plugins : fake(world).plugins) {
    for (QJsonObject& entry : plugins) {
      if (entry.value(QLatin1String("id")) != id) continue;
      edit(entry);
      found = true;
    }
  }
  expect(found, QStringLiteral("no MC runs %1").arg(id));
  announce(world);
}

void changeContributions(World& world, const QString& id, const std::function<void(QJsonObject&)>& edit) {
  change(world, id, [&](QJsonObject& entry) {
    QJsonObject parts = entry.value(QLatin1String("contributes")).toObject();
    edit(parts);
    entry.insert(QStringLiteral("contributes"), parts);
  });
}

QVariantMap published(World& world) { return world.state(QStringLiteral("mcPlugins")).toMap(); }

// Plugin `id` as the client lists it on `environment`.
QVariantMap listed(World& world, const QString& id, const QString& environment = {}) {
  const QString wanted = environment.isEmpty() ? world.mc.environmentId : environment;
  for (const QVariant& each : published(world).value(QStringLiteral("environments")).toList()) {
    if (each.toMap().value(QStringLiteral("id")) != wanted) continue;
    for (const QVariant& plugin : each.toMap().value(QStringLiteral("plugins")).toList()) {
      if (plugin.toMap().value(QStringLiteral("id")) == id) return plugin.toMap();
    }
  }
  return {};
}

QString describe(World& world) {
  return QStringLiteral("the client has %1; the route is %2").arg(show(published(world)), show(world.state(QStringLiteral("route"))));
}

void waitStatus(World& world, const QString& id, const QString& status) {
  world.waitFor([&] { return listed(world, id).value(QStringLiteral("status")) == status; },
                [&] { return QStringLiteral("%1 to be %2; %3").arg(id, status, describe(world)); });
}

// The shown item named `objectName` in the window, else the first hidden
// one: a thread can have a row in more than one section, or a page a copy
// that is not on screen.
QQuickItem* shownNamed(QQuickItem* item, const QString& objectName) {
  if (item->objectName() == objectName && item->isVisible()) return item;
  for (QQuickItem* child : item->childItems()) {
    if (QQuickItem* found = shownNamed(child, objectName)) return found;
  }
  return nullptr;
}

QQuickItem* named(World& world, const QString& objectName) {
  QQuickItem* root = pluginShell(world)->contentItem();
  QQuickItem* shown = shownNamed(root, objectName);
  return shown ? shown : findNamed(root, objectName);
}

int countNamed(const QQuickItem* item, const QString& objectName) {
  int count = item->objectName() == objectName ? 1 : 0;
  for (const QQuickItem* child : item->childItems()) count += countNamed(child, objectName);
  return count;
}

int countPrefixed(const QQuickItem* item, const QString& prefix) {
  int count = item->objectName().startsWith(prefix) ? 1 : 0;
  for (const QQuickItem* child : item->childItems()) count += countPrefixed(child, prefix);
  return count;
}

QQuickItem* waitNamed(World& world, const QString& objectName, const std::function<bool(QQuickItem*)>& ready = {}) {
  QQuickItem* found = nullptr;
  world.waitFor([&] { return (found = named(world, objectName)) != nullptr && found->isVisible() && (!ready || ready(found)); },
                [&] {
                  const QString problem = found ? found->property("problem").toString() : QString();
                  return QStringLiteral("%1 to be shown%2; %3").arg(objectName, problem.isEmpty() ? QString() : QStringLiteral(" (%1)").arg(problem), describe(world));
                });
  return found;
}

QString routeTab(World& world) { return at(world.state(QStringLiteral("route")), QStringLiteral("tab")).toString(); }

// A tab's key by its title.
QString tabKey(World& world, const QString& title) {
  if (title == QLatin1String("Threads")) return QStringLiteral("threads");
  QString key;
  world.waitFor([&] {
    for (const QVariant& page : published(world).value(QStringLiteral("pages")).toList()) {
      if (page.toMap().value(QStringLiteral("title")) == title) key = page.toMap().value(QStringLiteral("key")).toString();
    }
    return !key.isEmpty();
  }, [&] { return QStringLiteral("a page titled %1; %2").arg(title, describe(world)); });
  return key;
}

void waitTab(World& world, const QString& title) {
  const QString key = tabKey(world, title);
  world.waitFor([&] { return routeTab(world) == key; }, [&] { return QStringLiteral("the %1 tab to be selected; %2").arg(title, describe(world)); });
}

// The user clicks a tab in the window's strip.
void clickTab(World& world, const QString& title) {
  clickItem(world, waitNamed(world, QStringLiteral("tab:") + tabKey(world, title)));
  waitTab(world, title);
}

// The plugin's page, drawn in its tab.
QQuickItem* showPage(World& world, const QString& title) {
  clickTab(world, title);
  QQuickItem* page = waitNamed(world, QStringLiteral("reviewsPage"));
  fake(world).page = page;
  return page;
}

QString reviewsShown(World& world) {
  return waitNamed(world, QStringLiteral("reviewsList"))->property("text").toString();
}

void addThread(World& world, const QString& id, const QString& title, const QJsonValue& plugin = QJsonValue::Null) {
  pluginShell(world);
  QJsonObject row{{QStringLiteral("id"), id},
                  {QStringLiteral("title"), title},
                  {QStringLiteral("projectId"), QStringLiteral("p1")},
                  {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                  {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
  if (!plugin.isNull()) row.insert(QStringLiteral("plugin"), plugin);
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
  world.sync();
}

void addReviewThread(World& world, bool listedInSidebar) {
  addThread(world, kReviewThread, kReviewTitle,
            QJsonObject{{QStringLiteral("id"), kCodeReview}, {QStringLiteral("kind"), QStringLiteral("review")}, {QStringLiteral("listed"), listedInSidebar}});
}

QString key(World& world, const QString& thread) { return world.mc.environmentId + QLatin1Char(':') + thread; }

void openThread(World& world, const QString& thread) {
  world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key(world, thread)}});
  world.waitFor([&] { return at(world.state(QStringLiteral("route")), QStringLiteral("threadKey")) == key(world, thread); },
                [&] { return describe(world); });
}

QQuickItem* openSettings(World& world, const QString& id) {
  pluginShell(world);
  world.bridge().dispatch(QStringLiteral("settings.navigate"),
                          QVariantMap{{QStringLiteral("to"), QStringLiteral("/settings/plugin/%1/%2").arg(world.mc.environmentId, id)}});
  return waitNamed(world, QStringLiteral("pluginSettings"));
}

// The settings page's own `set(key, value)`, as the fields call it.
void setSetting(World& world, const QString& key, const QVariant& value) {
  QQuickItem* page = waitNamed(world, QStringLiteral("pluginSettings"));
  expect(QMetaObject::invokeMethod(page, "set", Q_ARG(QVariant, key), Q_ARG(QVariant, value)), QStringLiteral("the settings page cannot be changed"));
}

void askPage(QQuickItem* page, const QString& environment) {
  expect(QMetaObject::invokeMethod(page, "ask", Q_ARG(QVariant, environment)), QStringLiteral("the page cannot ask"));
}

QList<FakeMc::Rpc> callsOf(World& world, const QString& method) {
  QList<FakeMc::Rpc> found;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == method) found.append(rpc);
  }
  return found;
}

QQuickItem* reviewMark(World& world) {
  QQuickItem* mark = named(world, QStringLiteral("pluginRowMark"));
  return mark && mark->isVisible() ? mark : nullptr;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("an environment whose MC runs the plugin %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kCodeReview, QStringLiteral("the fake MC has no plugin %1").arg(c[0]));
    fake(world).plugins[world.mc.environmentId] = {codeReview()};
    pluginShell(world);
    waitStatus(world, c[0], QStringLiteral("running"));
  });

  // Pages are tabs.
  step(QStringLiteral("%1 adds the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitNamed(world, QStringLiteral("tab:") + tabKey(world, c[1]));
  });
  step(QStringLiteral("no running plugin adds a page"), [](World& world, const Captures&, const Table&) {
    changeContributions(world, kCodeReview, [](QJsonObject& parts) { parts.remove(QStringLiteral("pages")); });
    world.waitFor([&] { return published(world).value(QStringLiteral("pages")).toList().isEmpty(); }, [&] { return describe(world); });
  });
  for (const QString& shown : {QStringLiteral("the shell is shown"), QStringLiteral("the thread list is shown")}) {
    step(shown, [](World& world, const Captures&, const Table&) {
      pluginShell(world);
      world.sync();
    });
  }
  step(QStringLiteral("the shell has the tabs %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitNamed(world, QStringLiteral("shellTabs"));
    for (const QString& title : c) {
      QQuickItem* tab = waitNamed(world, QStringLiteral("tab:") + tabKey(world, title));
      expect(drawsText(tab, title), QStringLiteral("the %1 tab does not say so").arg(title));
    }
  });
  step(QStringLiteral("%1 is selected").arg(q), [](World& world, const Captures& c, const Table&) { waitTab(world, c[0]); });
  step(QStringLiteral("the shell shows the threads with no tabs"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { QQuickItem* tabs = named(world, QStringLiteral("shellTabs")); return tabs && !tabs->isVisible(); },
                  [&] { return QStringLiteral("the tabs to go; %1").arg(describe(world)); });
    expect(routeTab(world) == QLatin1String("threads") && !named(world, QStringLiteral("pluginPages"))->isVisible(), describe(world));
  });
  step(QStringLiteral("the user is reading the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addThread(world, QStringLiteral("t-auth"), c[0]);
    openThread(world, QStringLiteral("t-auth"));
  });
  step(QStringLiteral("the user switches to the %1 tab").arg(q), [](World& world, const Captures& c, const Table&) {
    clickTab(world, c[0]);
    if (c[0] != QLatin1String("Threads")) waitNamed(world, QStringLiteral("pluginPages"));
  });
  step(QStringLiteral("then switches back to the %1 tab").arg(q), [](World& world, const Captures& c, const Table&) { clickTab(world, c[0]); });
  step(QStringLiteral("the thread %1 is shown where the user left it").arg(q), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !named(world, QStringLiteral("pluginPages"))->isVisible(); }, [&] { return describe(world); });
    expect(routeTab(world) == QLatin1String("threads") &&
               at(world.state(QStringLiteral("route")), QStringLiteral("threadKey")) == key(world, QStringLiteral("t-auth")),
           describe(world));
  });
  step(QStringLiteral("the user filtered the %1 page to failed reviews").arg(q), [](World& world, const Captures& c, const Table&) {
    showPage(world, c[0])->setProperty("filter", QStringLiteral("failed"));
    world.waitFor([&] { return reviewsShown(world) == QLatin1String("Fix login"); }, [&] { return reviewsShown(world); });
  });
  step(QStringLiteral("the user switches to %1 and back to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    clickTab(world, c[0]);
    clickTab(world, c[1]);
  });
  step(QStringLiteral("the %1 page still shows only failed reviews").arg(q), [](World& world, const Captures&, const Table&) {
    QQuickItem* page = waitNamed(world, QStringLiteral("reviewsPage"));
    expect(page == fake(world).page, QStringLiteral("the page was made again"));
    expect(page->property("filter") == QStringLiteral("failed") && reviewsShown(world) == QLatin1String("Fix login"),
           QStringLiteral("the page shows %1").arg(reviewsShown(world)));
  });
  for (const QString& on : {QStringLiteral("the user is on the %1 page"), QStringLiteral("the user is on the %1 tab"), QStringLiteral("the %1 page is shown")}) {
    step(on.arg(q), [](World& world, const Captures& c, const Table&) { showPage(world, c[0]); });
  }
  step(QStringLiteral("the user opens the thread of a review"), [](World& world, const Captures&, const Table&) {
    addReviewThread(world, true);
    expect(QMetaObject::invokeMethod(fake(world).page.data(), "open", Q_ARG(QVariant, kReviewThread)), QStringLiteral("the page cannot open a thread"));
  });
  step(QStringLiteral("the %1 tab is selected with that thread open").arg(q), [](World& world, const Captures& c, const Table&) {
    waitTab(world, c[0]);
    world.waitFor([&] { return at(world.state(QStringLiteral("route")), QStringLiteral("threadKey")) == key(world, kReviewThread); },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("the user searches the command palette for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    pluginShell(world);
    auto* palette = world.native().controller<CommandPaletteController>();
    palette->show();
    palette->setQuery(c[0]);
  });
  step(QStringLiteral("opening the result switches to the %1 tab").arg(q), [](World& world, const Captures& c, const Table&) {
    auto* palette = world.native().controller<CommandPaletteController>();
    int row = -1;
    world.waitFor([&] {
      if (palette->searching()) return false;
      for (int each = 0; each < palette->rowCount(); ++each) {
        if (palette->index(each).data(CommandPaletteController::TitleRole) == c[0]) row = each;
      }
      return row >= 0;
    }, [&] { return QStringLiteral("the palette to list %1").arg(c[0]); });
    palette->run(row);
    waitTab(world, c[0]);
  });
  step(QStringLiteral("the %1 tab is selected").arg(q), [](World& world, const Captures& c, const Table&) {
    if (!world.checking) clickTab(world, c[0]);
    waitTab(world, c[0]);
  });
  step(QStringLiteral("the user presses the keybinding for the (next|previous) tab"), [](World& world, const Captures& c, const Table&) {
    pressKey(world, c[0] == QLatin1String("next") ? QStringLiteral("mod+alt+]") : QStringLiteral("mod+alt+["));
    expect(keyRan(world, QStringLiteral("tabs.") + c[0]), describeKeyPress(world));
  });
  step(QStringLiteral("the %1 tab is gone").arg(q), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return published(world).value(QStringLiteral("pages")).toList().isEmpty() &&
                               countPrefixed(pluginShell(world)->contentItem(), QStringLiteral("tab:code-review/reviews@")) == 0; },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("the threads are shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return routeTab(world) == QLatin1String("threads") && !named(world, QStringLiteral("pluginPages"))->isVisible(); },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("a second environment also runs %1").arg(q), [](World& world, const Captures& c, const Table&) {
    pluginShell(world);
    fake(world).plugins[QStringLiteral("work")] = {codeReview()};
    world.mc.join(QStringLiteral("work"));
    world.waitFor([&] { return listed(world, c[0], QStringLiteral("work")).value(QStringLiteral("status")) == QLatin1String("running"); },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("a second environment runs another version of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    pluginShell(world);
    QJsonObject other = codeReview();
    other.insert(QStringLiteral("revision"), QStringLiteral("other"));
    fake(world).plugins[QStringLiteral("work")] = {other};
    world.mc.join(QStringLiteral("work"));
    world.waitFor([&] { return listed(world, c[0], QStringLiteral("work")).value(QStringLiteral("status")) == QLatin1String("running"); },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("there is a %1 tab for each environment, named after it").arg(q), [](World& world, const Captures& c, const Table&) {
    QVariantList pages;
    world.waitFor([&] { return (pages = published(world).value(QStringLiteral("pages")).toList()).size() == 2; }, [&] { return describe(world); });
    QStringList titles;
    for (const QVariant& page : std::as_const(pages)) {
      const QString title = page.toMap().value(QStringLiteral("title")).toString();
      expect(title.startsWith(c[0] + QStringLiteral(" · ")), QStringLiteral("a tab is named %1").arg(title));
      titles.append(title);
      waitNamed(world, QStringLiteral("tab:") + page.toMap().value(QStringLiteral("key")).toString());
    }
    expect(titles.first() != titles.last(), QStringLiteral("both tabs are named %1").arg(titles.first()));
  });
  step(QStringLiteral("each tab's page runs on its own environment only"), [](World& world, const Captures&, const Table&) {
    QStringList runsOn;
    for (const QVariant& page : published(world).value(QStringLiteral("pages")).toList()) {
      runsOn.append(page.toMap().value(QStringLiteral("environments")).toStringList().join(QLatin1Char(',')));
    }
    runsOn.sort();
    QStringList wanted{world.mc.environmentId, QStringLiteral("work")};
    wanted.sort();
    expect(runsOn == wanted, QStringLiteral("the pages run on %1").arg(runsOn.join(QLatin1Char(' '))));
  });
  step(QStringLiteral("the user is on the %1 tab of the second environment").arg(q), [](World& world, const Captures&, const Table&) {
    QString key;
    world.waitFor([&] {
      for (const QVariant& page : published(world).value(QStringLiteral("pages")).toList()) {
        if (page.toMap().value(QStringLiteral("environments")).toStringList() == QStringList{QStringLiteral("work")}) key = page.toMap().value(QStringLiteral("key")).toString();
      }
      return !key.isEmpty();
    }, [&] { return describe(world); });
    clickItem(world, waitNamed(world, QStringLiteral("tab:") + key));
    world.waitFor([&] { return routeTab(world) == key; }, [&] { return describe(world); });
    fake(world).page = waitNamed(world, QStringLiteral("reviewsPage"));
  });
  step(QStringLiteral("%1 stops on the first environment").arg(q), [](World& world, const Captures&, const Table&) {
    for (QJsonObject& entry : fake(world).plugins[world.mc.environmentId]) entry.insert(QStringLiteral("status"), QStringLiteral("stopped"));
    announce(world);
    world.waitFor([&] { return published(world).value(QStringLiteral("pages")).toList().size() == 1; }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user is still on the same page"), [](World& world, const Captures&, const Table&) {
    QQuickItem* page = fake(world).page.data();
    expect(page != nullptr && page->isVisible(), QStringLiteral("the page was replaced or hidden; tab %1; %2").arg(routeTab(world), describe(world)));
  });
  step(QStringLiteral("there is one %1 tab").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = tabKey(world, c[0]);
    QVariantMap page;
    world.waitFor([&] {
      const QVariantList pages = published(world).value(QStringLiteral("pages")).toList();
      page = pages.size() == 1 ? pages.first().toMap() : QVariantMap();
      return page.value(QStringLiteral("environments")).toStringList().size() == 2;
    }, [&] { return describe(world); });
    waitNamed(world, QStringLiteral("tab:") + key);
    expect(countNamed(pluginShell(world)->contentItem(), QStringLiteral("tab:") + key) == 1, QStringLiteral("the strip has more than one %1 tab").arg(c[0]));
  });
  step(QStringLiteral("the page can tell each environment's data apart"), [](World& world, const Captures&, const Table&) {
    QQuickItem* page = showPage(world, QStringLiteral("Reviews"));
    const QString environments = waitNamed(world, QStringLiteral("reviewsEnvironments"))->property("text").toString();
    QStringList runsOn = environments.split(QLatin1Char(','));
    runsOn.sort();
    expect(runsOn == QStringList{world.mc.environmentId, QStringLiteral("work")}, QStringLiteral("the page runs on %1").arg(environments));
    for (const QString& environment : {world.mc.environmentId, QStringLiteral("work")}) {
      askPage(page, environment);
      world.waitFor([&] { return page->property("answer") == QStringLiteral("Reviews on %1").arg(environment); },
                    [&] { return QStringLiteral("the answer from %1; the page has %2").arg(environment, page->property("answer").toString()); });
    }
  });
  step(QStringLiteral("the %1 page of %1 fails to load").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).files.insert(QStringLiteral("broken/pages/Reviews.qml"), "import QtQuick\nItem { this is not QML }\n");
    change(world, c[1], [](QJsonObject& entry) { entry.insert(QStringLiteral("revision"), QStringLiteral("broken")); });
  });
  step(QStringLiteral("the tab shows that %1 failed with its message").arg(q), [](World& world, const Captures&, const Table&) {
    QQuickItem* problem = waitNamed(world, QStringLiteral("pluginPageProblem"));
    const QString text = problem->property("text").toString();
    expect(text.startsWith(QLatin1String("Code review failed: ")) && text.size() > 24, QStringLiteral("the tab says \"%1\"").arg(text));
  });
  step(QStringLiteral("the other tabs keep working"), [](World& world, const Captures&, const Table&) {
    clickTab(world, QStringLiteral("Threads"));
    world.waitFor([&] { return !named(world, QStringLiteral("pluginPages"))->isVisible(); }, [&] { return describe(world); });
  });

  // A plugin's threads.
  step(QStringLiteral("%1 started a(?: listed)? %1 thread").arg(q), [](World& world, const Captures&, const Table&) { addReviewThread(world, true); });
  step(QStringLiteral("%1 started a %1 thread that is not listed").arg(q), [](World& world, const Captures&, const Table&) { addReviewThread(world, false); });
  step(QStringLiteral("the thread's row shows the mark %1 gives %1 threads").arg(q), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { QQuickItem* mark = reviewMark(world); return mark && drawsText(mark, QStringLiteral("[review mark]")); },
                  [&] { return QStringLiteral("the review mark; %1").arg(describe(world)); });
  });
  step(QStringLiteral("the user opens that thread"), [](World& world, const Captures&, const Table&) { openThread(world, kReviewThread); });
  step(QStringLiteral("the plugin's header for %1 threads is shown above the conversation").arg(q), [](World& world, const Captures&, const Table&) {
    QQuickItem* header = waitNamed(world, QStringLiteral("pluginThreadHeader"), [](QQuickItem* item) { return item->height() > 0; });
    expect(header->property("look") == QStringLiteral("header"), QStringLiteral("the header is not the thread's header"));
  });
  step(QStringLiteral("the header is given the thread it is shown for"), [](World& world, const Captures&, const Table&) {
    QQuickItem* header = waitNamed(world, QStringLiteral("pluginThreadHeader"));
    world.waitFor([&] { return drawsText(header, QStringLiteral("Reviewing ") + kReviewTitle); }, QStringLiteral("the header to name the thread"));
  });
  step(QStringLiteral("the thread is not in it"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(sidebarSectionOf(world, key(world, kReviewThread)).isEmpty(), QStringLiteral("the thread is listed in %1").arg(sidebarSectionOf(world, key(world, kReviewThread))));
  });
  step(QStringLiteral("%1 is disabled").arg(q), [](World& world, const Captures& c, const Table&) {
    change(world, c[0], [](QJsonObject& entry) { entry.insert(QStringLiteral("status"), QStringLiteral("disabled")); });
    waitStatus(world, c[0], QStringLiteral("disabled"));
  });
  step(QStringLiteral("the thread is listed and opens as an ordinary thread"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !sidebarSectionOf(world, key(world, kReviewThread)).isEmpty() && reviewMark(world) == nullptr; },
                  [&] { return QStringLiteral("the thread listed without its mark; %1").arg(describe(world)); });
    openThread(world, kReviewThread);
    world.sync();
    QQuickItem* header = named(world, QStringLiteral("pluginThreadHeader"));
    expect(header == nullptr || !header->isVisible(), QStringLiteral("the plugin's header is shown"));
  });

  // Settings.
  step(QStringLiteral("%1 is listed under its environment with its description, version, author and screenshots").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* list = showPluginList(world);
    // The list draws each environment again when what it publishes changes,
    // so the card is looked up afresh each time it is read.
    const auto card = [&]() -> QQuickItem* {
      QQuickItem* environment = findNamed(list, QStringLiteral("mcPlugins:") + world.mc.environmentId);
      return environment && environment->isVisible() ? findNamed(environment, QStringLiteral("mcPlugin:%1/%2").arg(world.mc.environmentId, c[0])) : nullptr;
    };
    const QString description = codeReview().value(QLatin1String("description")).toString();
    QString byline;
    world.waitFor([&] {
      QQuickItem* shown = card();
      QQuickItem* by = shown ? findNamed(shown, QStringLiteral("mcPluginByline")) : nullptr;
      byline = by ? by->property("text").toString() : QString();
      return by && drawsText(shown, description);
    }, [&] { return QStringLiteral("the card with its description; %1").arg(describe(world)); });
    expect(byline.contains(QLatin1String("1.0.0")) && byline.contains(QLatin1String("HAL-C2")), QStringLiteral("the card says \"%1\"").arg(byline));
    world.waitFor([&] {
      QQuickItem* shown = card();
      QQuickItem* shot = shown ? findNamed(shown, QStringLiteral("mcPluginScreenshot")) : nullptr;
      return shot && shot->isVisible() && shot->property("status").toInt() == 1;  // Image.Ready
    }, QStringLiteral("the screenshot to be drawn"));
  });
  step(QStringLiteral("the user is shown each permission it asks for with its reason"), [](World& world, const Captures&, const Table&) {
    QVariantMap question;
    world.waitFor([&] { return !(question = world.state(QStringLiteral("confirmation")).toMap()).isEmpty(); }, QStringLiteral("the shell to ask"));
    const QString description = question.value(QStringLiteral("description")).toString();
    expect(question.value(QStringLiteral("title")) == QStringLiteral("Enable \"Code review\"?"), show(question));
    for (const QJsonValue& permission : codeReview().value(QLatin1String("permissions")).toArray()) {
      const QString line = QStringLiteral("%1: %2").arg(permission[QLatin1String("label")].toString(), permission[QLatin1String("reason")].toString());
      expect(description.contains(line), QStringLiteral("the question does not say \"%1\": %2").arg(line, description));
    }
  });
  step(QStringLiteral("%1 runs only after the user accepts them").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(callsOf(world, QStringLiteral("plugins.enable")).isEmpty(), QStringLiteral("the plugin was enabled before the user accepted"));
    answerQuestion(world, true);
    waitStatus(world, c[0], QStringLiteral("running"));
    const QJsonArray accepted = callsOf(world, QStringLiteral("plugins.enable")).value(0).payload.value(QLatin1String("acceptPermissions")).toArray();
    expect(accepted == QJsonArray{QStringLiteral("pullRequests:write"), QStringLiteral("threads:create")}, QStringLiteral("it was enabled with %1").arg(show(accepted)));
  });
  step(QStringLiteral("the user enables %1 and declines its permissions").arg(q), [](World& world, const Captures& c, const Table&) {
    switchMcPlugin(world, c[0]);
    world.waitFor([&] { return !world.state(QStringLiteral("confirmation")).toMap().isEmpty(); }, QStringLiteral("the shell to ask"));
    answerQuestion(world, false);
  });
  step(QStringLiteral("%1 stays disabled").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(callsOf(world, QStringLiteral("plugins.enable")).isEmpty(), QStringLiteral("the plugin was enabled"));
    expect(listed(world, c[0]).value(QStringLiteral("status")) == QLatin1String("disabled"), describe(world));
  });
  step(QStringLiteral("the plugin %1 declares a server address and a secret token").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject entry = codeReview();
    entry.insert(QStringLiteral("id"), c[0]);
    entry.insert(QStringLiteral("name"), QStringLiteral("ntfy"));
    entry.insert(QStringLiteral("runsCode"), false);
    entry.insert(QStringLiteral("contributes"), QJsonObject());
    entry.insert(QStringLiteral("settingsSchema"),
                 QJsonArray{QJsonObject{{QStringLiteral("key"), QStringLiteral("server")}, {QStringLiteral("type"), QStringLiteral("text")},
                                        {QStringLiteral("label"), QStringLiteral("Server address")}},
                            QJsonObject{{QStringLiteral("key"), QStringLiteral("token")}, {QStringLiteral("type"), QStringLiteral("secret")},
                                        {QStringLiteral("label"), QStringLiteral("Token")}}});
    entry.insert(QStringLiteral("settings"), QJsonObject{{QStringLiteral("server"), QStringLiteral("https://ntfy.sh")}, {QStringLiteral("token"), kMarker}});
    fake(world).plugins[world.mc.environmentId].append(entry);
    announce(world);
    waitStatus(world, c[0], QStringLiteral("running"));
  });
  step(QStringLiteral("the plugin %1 declares a setting that takes JSON").arg(q), [](World& world, const Captures& c, const Table&) {
    QJsonObject entry = codeReview();
    entry.insert(QStringLiteral("id"), c[0]);
    entry.insert(QStringLiteral("name"), QStringLiteral("ntfy"));
    entry.insert(QStringLiteral("runsCode"), false);
    entry.insert(QStringLiteral("contributes"), QJsonObject());
    entry.insert(QStringLiteral("settingsSchema"), QJsonArray{QJsonObject{{QStringLiteral("key"), QStringLiteral("topics")},
                                                                          {QStringLiteral("type"), QStringLiteral("object")},
                                                                          {QStringLiteral("label"), QStringLiteral("Topics")}}});
    entry.insert(QStringLiteral("settings"), QJsonObject{{QStringLiteral("topics"), QJsonObject{{QStringLiteral("alerts"), true}}}});
    fake(world).plugins[world.mc.environmentId].append(entry);
    announce(world);
    waitStatus(world, c[0], QStringLiteral("running"));
  });
  step(QStringLiteral("the user changes that setting to JSON that does not parse"), [](World& world, const Captures&, const Table&) {
    QQuickItem* page = waitNamed(world, QStringLiteral("pluginSettings"));
    expect(QMetaObject::invokeMethod(page, "setJson", Q_ARG(QVariant, QStringLiteral("topics")), Q_ARG(QVariant, QStringLiteral("{\"alerts\": false}"))),
           QStringLiteral("the settings page cannot be changed"));
    expect(waitNamed(world, QStringLiteral("pluginSettingsSave"))->isEnabled(), QStringLiteral("a change that parses cannot be saved"));
    QMetaObject::invokeMethod(page, "setJson", Q_ARG(QVariant, QStringLiteral("topics")), Q_ARG(QVariant, QStringLiteral("{\"alerts\": fa")));
  });
  step(QStringLiteral("the page says the setting is not valid JSON"), [](World& world, const Captures&, const Table&) {
    QQuickItem* unparsed = waitNamed(world, QStringLiteral("pluginSettingsUnparsed"));
    expect(unparsed->property("text").toString().contains(QStringLiteral("Topics")), unparsed->property("text").toString());
    expect(!named(world, QStringLiteral("pluginSettingsSave"))->isEnabled(), QStringLiteral("the stale value can be saved"));
  });
  step(QStringLiteral("it can be saved again once the JSON parses"), [](World& world, const Captures&, const Table&) {
    QQuickItem* page = waitNamed(world, QStringLiteral("pluginSettings"));
    QMetaObject::invokeMethod(page, "setJson", Q_ARG(QVariant, QStringLiteral("topics")), Q_ARG(QVariant, QStringLiteral("{\"alerts\": false, \"news\": true}")));
    clickItem(world, waitNamed(world, QStringLiteral("pluginSettingsSave")));
    world.waitFor([&] { return !callsOf(world, QStringLiteral("plugins.saveSettings")).isEmpty(); }, QStringLiteral("the settings to be saved"));
    const QJsonObject settings = callsOf(world, QStringLiteral("plugins.saveSettings")).first().payload.value(QLatin1String("settings")).toObject();
    const QJsonObject wanted{{QStringLiteral("topics"), QJsonObject{{QStringLiteral("alerts"), false}, {QStringLiteral("news"), true}}}};
    expect(settings == wanted, QStringLiteral("the MC was sent %1").arg(show(settings)));
  });
  step(QStringLiteral("the user opens the settings of %1").arg(q), [](World& world, const Captures& c, const Table&) { openSettings(world, c[0]); });
  step(QStringLiteral("the page shows a field for each declared setting"), [](World& world, const Captures&, const Table&) {
    for (const QString& setting : {QStringLiteral("server"), QStringLiteral("token")}) waitNamed(world, QStringLiteral("pluginSetting:") + setting);
  });
  step(QStringLiteral("saving it stores the settings on the MC"), [](World& world, const Captures&, const Table&) {
    setSetting(world, QStringLiteral("server"), QStringLiteral("https://ntfy.example.com"));
    clickItem(world, waitNamed(world, QStringLiteral("pluginSettingsSave")));
    world.waitFor([&] { return !callsOf(world, QStringLiteral("plugins.saveSettings")).isEmpty(); }, QStringLiteral("the settings to be saved"));
    const QJsonObject settings = callsOf(world, QStringLiteral("plugins.saveSettings")).first().payload.value(QLatin1String("settings")).toObject();
    expect(settings == QJsonObject{{QStringLiteral("server"), QStringLiteral("https://ntfy.example.com")}, {QStringLiteral("token"), kMarker}},
           QStringLiteral("the MC was sent %1").arg(show(settings)));
    world.waitFor([&] { QQuickItem* save = named(world, QStringLiteral("pluginSettingsSave")); return save && !save->isEnabled(); }, QStringLiteral("the page to be saved"));
  });
  step(QStringLiteral("%1 adds its own settings page").arg(q), [](World& world, const Captures& c, const Table&) {
    changeContributions(world, c[0], [](QJsonObject& parts) { parts.insert(QStringLiteral("settingsPage"), QStringLiteral("settings/Settings.qml")); });
    world.waitFor([&] { return !listed(world, c[0]).value(QStringLiteral("settingsPageUrl")).toString().isEmpty(); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the plugin's settings page is shown"), [](World& world, const Captures&, const Table&) {
    QQuickItem* own = waitNamed(world, QStringLiteral("pluginOwnSettings"));
    world.waitFor([&] { return drawsText(own, QStringLiteral("[code-review settings]")); }, QStringLiteral("the plugin's page to be drawn"));
    QQuickItem* field = named(world, QStringLiteral("pluginSetting:repos"));
    expect(field == nullptr || !field->isVisible(), QStringLiteral("the generated fields are shown too"));
  });
  step(QStringLiteral("the user saves settings that %1 refuses").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world).refusal = QStringLiteral("acme/nope is not a repository");
    openSettings(world, c[0]);
    setSetting(world, QStringLiteral("repos"), QStringList{QStringLiteral("acme/nope")});
    clickItem(world, waitNamed(world, QStringLiteral("pluginSettingsSave")));
  });
  step(QStringLiteral("the plugin's message is shown"), [](World& world, const Captures&, const Table&) {
    QQuickItem* refusal = waitNamed(world, QStringLiteral("pluginSettingsRefusal"));
    expect(refusal->property("text").toString().contains(fake(world).refusal), refusal->property("text").toString());
  });
  step(QStringLiteral("the saved settings are unchanged"), [](World& world, const Captures&, const Table&) {
    const QJsonObject entry = fake(world).plugins.value(world.mc.environmentId).first();
    expect(!entry.contains(QLatin1String("saved")), QStringLiteral("the MC saved %1").arg(show(entry.value(QLatin1String("saved")))));
    // What the user typed stays, to be fixed and saved again.
    expect(waitNamed(world, QStringLiteral("pluginSettingsSave"))->isEnabled(), QStringLiteral("the page forgot the change"));
  });
  step(QStringLiteral("%1 is listed as failed with its last error").arg(q), [](World& world, const Captures& c, const Table&) {
    change(world, c[0], [](QJsonObject& entry) {
      entry.insert(QStringLiteral("status"), QStringLiteral("failed"));
      entry.insert(QStringLiteral("lastError"), QStringLiteral("exited with status 1"));
    });
    waitStatus(world, c[0], QStringLiteral("failed"));
  });
  step(QStringLiteral("the user restarts %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openSettings(world, c[0]);
    clickItem(world, waitNamed(world, QStringLiteral("pluginSettingsRestart")));
  });
  step(QStringLiteral("%1 runs again").arg(q), [](World& world, const Captures& c, const Table&) {
    waitStatus(world, c[0], QStringLiteral("running"));
    expect(callsOf(world, QStringLiteral("plugins.restart")).size() == 1, QStringLiteral("the plugin was not restarted"));
  });

  // The shell's named places, and the way to the MC part.
  step(QStringLiteral("%1 contributes to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    changeContributions(world, c[0], [&](QJsonObject& parts) {
      parts.insert(QStringLiteral("slots"), QJsonArray{QJsonObject{{QStringLiteral("slot"), c[1]}, {QStringLiteral("qml"), QStringLiteral("slots/Section.qml")}}});
    });
  });
  step(QStringLiteral("the plugin's section is shown below the threads"), [](World& world, const Captures&, const Table&) {
    QQuickItem* slot = waitNamed(world, QStringLiteral("sidebarSectionsSlot"));
    world.waitFor([&] { return drawsText(slot, QStringLiteral("[code-review section]")); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the page asks %1 for its reviews").arg(q), [](World& world, const Captures&, const Table&) {
    askPage(fake(world).page.data(), QString());
  });
  step(QStringLiteral("the answer comes from the MC that runs %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* page = fake(world).page.data();
    world.waitFor([&] { return page->property("answer") == QStringLiteral("Reviews on %1").arg(world.mc.environmentId); },
                  [&] { return QStringLiteral("the answer; the page has %1").arg(page->property("answer").toString()); });
    const FakeMc::Rpc call = callsOf(world, QStringLiteral("plugins.call")).value(0);
    expect(call.payload.value(QLatin1String("id")) == c[0] && call.payload.value(QLatin1String("method")) == QLatin1String("reviews") &&
               call.payload.value(QLatin1String("input")) == QJsonObject{{QStringLiteral("state"), QStringLiteral("failed")}},
           QStringLiteral("the MC was asked %1").arg(show(call.payload)));
  });
  step(QStringLiteral("the %1 page watches the %1 topic").arg(q), [](World& world, const Captures& c, const Table&) {
    showPage(world, c[0]);
    world.waitFor([&] {
      for (const int subscriber : world.mc.subscribers(QStringLiteral("plugin"))) {
        if (world.mc.shapeOf(subscriber).value(QLatin1String("topic")) == c[1]) return true;
      }
      return false;
    }, QStringLiteral("the page to watch the topic"));
    world.waitFor([&] { return reviewsShown(world) == QLatin1String("Add cache, Fix login"); }, [&] { return reviewsShown(world); });
  });
  step(QStringLiteral("another part of %1 watches the %1 topic").arg(q), [](World& world, const Captures& c, const Table&) {
    QMetaObject::invokeMethod(fake(world).page.data(), "watchAgain", Q_ARG(QVariant, c[1]));
  });
  step(QStringLiteral("the other part is given the last list at once"), [](World& world, const Captures&, const Table&) {
    QQuickItem* page = fake(world).page.data();
    world.waitFor([&] { return page->property("seen").toInt() == fake(world).reviews.size(); },
                  [&] { return QStringLiteral("the other part has %1 reviews").arg(page->property("seen").toInt()); });
  });
  step(QStringLiteral("the MC sends the %1 topic to the client once").arg(q), [](World& world, const Captures& c, const Table&) {
    int following = 0;
    for (const int subscriber : world.mc.subscribers(QStringLiteral("plugin"))) {
      if (world.mc.shapeOf(subscriber).value(QLatin1String("topic")) == c[0]) ++following;
    }
    expect(following == 1, QStringLiteral("the client follows the topic %1 times").arg(following));
  });
  step(QStringLiteral("%1 publishes a new list of reviews").arg(q), [](World& world, const Captures&, const Table&) {
    fake(world).reviews.append(QJsonObject{{QStringLiteral("title"), QStringLiteral("Bump deps")}, {QStringLiteral("state"), QStringLiteral("running")}});
    for (const int subscriber : world.mc.subscribers(QStringLiteral("plugin"))) {
      world.mc.send({{QStringLiteral("t"), QStringLiteral("plugin")}, {QStringLiteral("id"), subscriber}, {QStringLiteral("topic"), QStringLiteral("reviews")},
                     {QStringLiteral("value"), fake(world).reviews}});
    }
  });
  step(QStringLiteral("the page shows the new list without reloading"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return reviewsShown(world) == QLatin1String("Add cache, Fix login, Bump deps"); }, [&] { return reviewsShown(world); });
    expect(waitNamed(world, QStringLiteral("reviewsPage")) == fake(world).page, QStringLiteral("the page was made again"));
  });
  step(QStringLiteral("the MC runs a new version of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    change(world, c[0], [](QJsonObject& entry) {
      entry.insert(QStringLiteral("revision"), QStringLiteral("2"));
      entry.insert(QStringLiteral("version"), QStringLiteral("1.1.0"));
    });
  });
  step(QStringLiteral("the page is loaded again from the new version"), [](World& world, const Captures&, const Table&) {
    QQuickItem* page = nullptr;
    world.waitFor([&] { return (page = named(world, QStringLiteral("reviewsPage"))) && page->property("version") == QStringLiteral("2"); },
                  [&] { return describe(world); });
    expect(page != fake(world).page && page->isVisible(), QStringLiteral("the new page is not shown"));
  });
});

}  // namespace

void runFakePlugin(World& world, const QJsonObject& entry, const FakePluginPart& part) {
  const QString id = entry.value(QLatin1String("id")).toString();
  fake(world).parts.insert(id, part);
  fake(world).plugins[world.mc.environmentId] = {entry};
  pluginShell(world);
  announce(world);
  waitStatus(world, id, QStringLiteral("running"));
}

FakePluginPart& fakePluginPart(World& world, const QString& id) {
  expect(fake(world).parts.contains(id), QStringLiteral("no plugin %1 is faked").arg(id));
  return fake(world).parts[id];
}

void publishTopic(World& world, const QString& id, const QString& topic) {
  const QJsonValue value = fakePluginPart(world, id).topics.value(topic);
  for (const int subscriber : world.mc.subscribers(QStringLiteral("plugin"))) {
    const QJsonObject shape = world.mc.shapeOf(subscriber);
    if (shape.value(QLatin1String("id")) != id || shape.value(QLatin1String("topic")) != topic) continue;
    world.mc.send({{QStringLiteral("t"), QStringLiteral("plugin")}, {QStringLiteral("id"), subscriber}, {QStringLiteral("topic"), topic}, {QStringLiteral("value"), value}});
  }
}

QQuickItem* waitShownNamed(World& world, const QString& objectName, const std::function<bool(QQuickItem*)>& ready) {
  return waitNamed(world, objectName, ready);
}

void switchToTab(World& world, const QString& title) {
  clickTab(world, title);
  waitNamed(world, QStringLiteral("pluginPages"));
}

void addPluginThread(World& world, const QString& id, const QString& title, const QJsonObject& plugin) { addThread(world, id, title, plugin); }

void openPluginThread(World& world, const QString& id) { openThread(world, id); }

bool isMcPlugin(World& world, const QString& id) {
  for (const QList<QJsonObject>& plugins : std::as_const(world.mc.part<FakeMcPlugins>().plugins)) {
    for (const QJsonObject& entry : plugins) {
      if (entry.value(QLatin1String("id")) == id) return true;
    }
  }
  return false;
}

void switchMcPlugin(World& world, const QString& id) {
  QQuickItem* list = showPluginList(world);
  QQuickItem* card = nullptr;
  world.waitFor([&] { return (card = findNamed(list, QStringLiteral("mcPlugin:%1/%2").arg(world.mc.environmentId, id))) != nullptr; },
                [&] { return describe(world); });
  clickItem(world, findNamed(card, QStringLiteral("mcPluginToggle")));
  world.sync();
}
