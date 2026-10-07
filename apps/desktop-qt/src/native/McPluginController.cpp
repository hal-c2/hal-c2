#include "McPluginController.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJSValue>
#include <QRegularExpression>
#include <QSaveFile>
#include <QTimer>
#include <QUrl>

#include "McClient.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<McPluginController> registrar(QStringLiteral("mcPlugins"), {QStringLiteral("mcPlugins")},
                                                             "McPlugins", NativeControllerScope::Shared);

const QString kKey = QStringLiteral("mcPlugins");

QString str(const QJsonValue& value) { return value.isString() ? value.toString() : QString(); }

// A name safe as one directory of the cache.
QString segment(const QString& name) {
  static const QRegularExpression unsafe(QStringLiteral("[^A-Za-z0-9._-]"));
  QString safe = QString(name).replace(unsafe, QStringLiteral("_"));
  return safe.isEmpty() || safe == QLatin1String(".") || safe == QLatin1String("..") ? QStringLiteral("_") : safe;
}

bool running(const QJsonObject& entry) { return entry.value(QLatin1String("status")).toString() == QLatin1String("running"); }

QJsonObject contributes(const QJsonObject& entry) { return entry.value(QLatin1String("contributes")).toObject(); }

// The files a plugin's clients load: everything its manifest names while it
// runs, and what the plugin list shows of it otherwise.
QStringList filesOf(const QJsonObject& entry) {
  const QJsonObject parts = contributes(entry);
  QStringList paths{str(entry.value(QLatin1String("icon"))), str(parts.value(QLatin1String("settingsPage")))};
  for (const QJsonValue& shot : entry.value(QLatin1String("screenshots")).toArray()) paths.append(str(shot[QLatin1String("path")]));
  if (running(entry)) {
    for (const QJsonValue& page : parts.value(QLatin1String("pages")).toArray()) paths.append(str(page[QLatin1String("qml")]));
    for (const QJsonValue& kind : parts.value(QLatin1String("threadKinds")).toArray()) {
      paths.append(str(kind[QLatin1String("rowMark")]));
      paths.append(str(kind[QLatin1String("header")]));
    }
    for (const QJsonValue& slot : parts.value(QLatin1String("slots")).toArray()) paths.append(str(slot[QLatin1String("qml")]));
  }
  paths.removeAll(QString());
  paths.removeDuplicates();
  return paths;
}

}  // namespace

McPluginController::McPluginController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

void McPluginController::activate() {
  if (m_active) return;
  m_active = true;
  connect(m_store, &ShellStore::changed, this, &McPluginController::follow);
  follow();
  publish();
}

QString McPluginController::label(const QString& environment) const {
  const QString label = m_store->environment(environment).value(QLatin1String("label")).toString();
  return label.isEmpty() ? environment : label;
}

// Every online environment's plugins; an environment that goes offline takes
// its plugins with it until it is back.
void McPluginController::follow() {
  QStringList online;
  for (const QString& environment : m_store->environments()) {
    if (m_store->environmentOnline(environment)) online.append(environment);
  }
  bool dropped = false;
  for (auto it = m_subscriptions.begin(); it != m_subscriptions.end();) {
    if (online.contains(it.key())) {
      ++it;
      continue;
    }
    m_client->unsubscribe(it.value());
    m_plugins.remove(it.key());
    dropped = true;
    it = m_subscriptions.erase(it);
  }
  for (const QString& environment : online) {
    if (m_subscriptions.contains(environment)) continue;
    const QJsonObject shape{{QStringLiteral("type"), QStringLiteral("plugins")}, {QStringLiteral("environment"), environment}};
    m_subscriptions.insert(environment, m_client->subscribe(this, shape, [this, environment](const QJsonObject& frame) {
      if (frame.value(QLatin1String("t")).toString() != QLatin1String("plugins")) return;
      const QJsonArray plugins = frame.value(QLatin1String("plugins")).toArray();
      m_plugins.insert(environment, plugins);
      for (const QJsonValue& entry : plugins) fetch(environment, entry.toObject());
      publish();
    }));
  }
  if (dropped) publish();
}

// Where `path` of a plugin's files is kept. What a running plugin's clients
// load is kept apart from what the plugin list shows of it otherwise, so a
// directory QML has read never gains a file: Qt lists a directory once and
// then refuses files that were not in it.
QString McPluginController::cachePath(const QString& environment, const QString& id, const QString& revision, bool runs,
                                      const QString& path) const {
  const QString root = m_cacheDir.isEmpty() ? QDir::temp().filePath(QStringLiteral("hal-c2-mc-plugins")) : m_cacheDir;
  QStringList parts{segment(environment), segment(id), segment(revision), runs ? QStringLiteral("running") : QStringLiteral("listed")};
  for (const QString& part : path.split(QLatin1Char('/'), Qt::SkipEmptyParts)) parts.append(segment(part));
  return QDir(root).filePath(parts.join(QLatin1Char('/')));
}

// Fetches what the plugin's clients load at its current revision; a file
// already kept for that revision is not asked for again. None of them is
// shown until all have come, for the reason cachePath gives.
void McPluginController::fetch(const QString& environment, const QJsonObject& entry) {
  const QString id = str(entry.value(QLatin1String("id")));
  const QString revision = str(entry.value(QLatin1String("revision")));
  const bool runs = running(entry);
  if (id.isEmpty() || revision.isEmpty()) return;
  const QString key = environment + QLatin1Char('/') + id;
  Files& files = m_files[key];
  if (files.revision != revision || files.runs != runs) files = Files{revision, runs, {}, {}, {}};
  // What failed is asked again on news: the plugin may run now.
  files.errors.clear();
  for (const QString& path : filesOf(entry)) {
    if (files.urls.contains(path) || files.errors.contains(path) || files.pending.contains(path)) continue;
    const QString local = cachePath(environment, id, revision, runs, path);
    if (QFileInfo::exists(local)) {
      files.urls.insert(path, QUrl::fromLocalFile(local).toString());
      continue;
    }
    files.pending.insert(path);
    const QJsonObject input{{QStringLiteral("id"), id}, {QStringLiteral("path"), path}};
    m_client->call(this, environment, QStringLiteral("plugins.file"), input,
                   [this, environment, id, key, revision, runs, path](const QJsonValue& result, const std::optional<QString>& error) {
                     auto it = m_files.find(key);
                     if (it == m_files.end() || it->revision != revision || it->runs != runs) return;
                     it->pending.remove(path);
                     const QJsonObject file = result.toObject();
                     if (error) {
                       it->errors.insert(path, *error);
                     } else if (str(file.value(QLatin1String("revision"))) != revision) {
                       // A newer version answered: its own list brings it.
                       return;
                     } else {
                       const QString content = str(file.value(QLatin1String("content")));
                       const QByteArray bytes = file.value(QLatin1String("encoding")).toString() == QLatin1String("base64")
                                                    ? QByteArray::fromBase64(content.toLatin1())
                                                    : content.toUtf8();
                       const QString local = cachePath(environment, id, revision, runs, path);
                       QDir().mkpath(QFileInfo(local).absolutePath());
                       QSaveFile out(local);
                       if (out.open(QIODevice::WriteOnly) && out.write(bytes) == bytes.size() && out.commit()) {
                         it->urls.insert(path, QUrl::fromLocalFile(local).toString());
                       } else {
                         it->errors.insert(path, QStringLiteral("%1 could not be kept: %2").arg(path, out.errorString()));
                       }
                     }
                     publish();
                   });
  }
}

void McPluginController::publish() {
  if (!m_active) return;
  QVariantList environments;
  QVariantList pages;
  QHash<QString, int> pageAt;
  QHash<QString, int> tabs;
  QVariantMap threadKinds;
  QVariantList slotParts;
  for (const QString& environment : m_store->environments()) {
    if (!m_plugins.contains(environment)) continue;
    QVariantList plugins;
    for (const QJsonValue& value : m_plugins.value(environment)) {
      const QJsonObject entry = value.toObject();
      const QString id = str(entry.value(QLatin1String("id")));
      const Files files = m_files.value(environment + QLatin1Char('/') + id);
      const bool current = files.revision == str(entry.value(QLatin1String("revision"))) && files.runs == running(entry) && files.pending.isEmpty();
      const auto url = [&](const QString& path) { return current ? files.urls.value(path) : QString(); };
      const auto failed = [&](const QString& path) { return current ? files.errors.value(path) : QString(); };

      QVariantMap shown = entry.toVariantMap();
      shown.insert(QStringLiteral("environment"), environment);
      shown.insert(QStringLiteral("iconUrl"), url(str(entry.value(QLatin1String("icon")))));
      QVariantList shots;
      for (const QJsonValue& shot : entry.value(QLatin1String("screenshots")).toArray()) {
        shots.append(QVariantMap{{QStringLiteral("url"), url(str(shot[QLatin1String("path")]))},
                                 {QStringLiteral("caption"), str(shot[QLatin1String("caption")])}});
      }
      shown.insert(QStringLiteral("screenshotUrls"), shots);
      shown.insert(QStringLiteral("settingsPageUrl"), url(str(contributes(entry).value(QLatin1String("settingsPage")))));
      plugins.append(shown);
      if (!running(entry)) continue;

      const QJsonObject parts = contributes(entry);
      for (const QJsonValue& page : parts.value(QLatin1String("pages")).toArray()) {
        const QString pageId = str(page[QLatin1String("id")]);
        const QString path = str(page[QLatin1String("qml")]);
        const QString pageKey = id + QLatin1Char('/') + pageId;
        // One tab per page, whichever environments run the plugin, as long as they run
        // the same version of it: one page's code cannot be given another version's MC
        // part to talk to, so an environment on another revision gets a tab of its own.
        // The key names the version, so environments coming and going leave it alone.
        const QString group = pageKey + QLatin1Char('@') + str(entry.value(QLatin1String("revision")));
        if (!pageAt.contains(group)) {
          pageAt.insert(group, pages.size());
          pages.append(QVariantMap{{QStringLiteral("key"), group},
                                   {QStringLiteral("pluginId"), id},
                                   {QStringLiteral("pageId"), pageId},
                                   {QStringLiteral("pluginName"), str(entry.value(QLatin1String("name")))},
                                   {QStringLiteral("title"), str(page[QLatin1String("title")])},
                                   {QStringLiteral("icon"), str(page[QLatin1String("icon")])},
                                   {QStringLiteral("url"), url(path)},
                                   {QStringLiteral("error"), failed(path)},
                                   {QStringLiteral("environments"), QStringList{environment}}});
          tabs[pageKey] += 1;
          continue;
        }
        QVariantMap merged = pages.at(pageAt.value(group)).toMap();
        merged.insert(QStringLiteral("environments"), merged.value(QStringLiteral("environments")).toStringList() << environment);
        if (merged.value(QStringLiteral("url")).toString().isEmpty() && !url(path).isEmpty()) {
          merged.insert(QStringLiteral("url"), url(path));
          merged.insert(QStringLiteral("error"), QString());
        }
        pages[pageAt.value(group)] = merged;
      }
      for (const QJsonValue& kind : parts.value(QLatin1String("threadKinds")).toArray()) {
        threadKinds.insert(environment + QLatin1Char('/') + id + QLatin1Char('/') + str(kind[QLatin1String("kind")]),
                           QVariantMap{{QStringLiteral("label"), str(kind[QLatin1String("label")])},
                                       {QStringLiteral("rowMark"), url(str(kind[QLatin1String("rowMark")]))},
                                       {QStringLiteral("header"), url(str(kind[QLatin1String("header")]))}});
      }
      for (const QJsonValue& slot : parts.value(QLatin1String("slots")).toArray()) {
        const QString slotUrl = url(str(slot[QLatin1String("qml")]));
        if (slotUrl.isEmpty()) continue;
        slotParts.append(QVariantMap{{QStringLiteral("slot"), str(slot[QLatin1String("slot")])},
                                 {QStringLiteral("url"), slotUrl},
                                 {QStringLiteral("pluginId"), id},
                                 {QStringLiteral("environment"), environment},
                                 {QStringLiteral("order"), slot[QLatin1String("order")].toInt()}});
      }
    }
    environments.append(QVariantMap{{QStringLiteral("id"), environment},
                                    {QStringLiteral("label"), label(environment)},
                                    {QStringLiteral("plugins"), plugins}});
  }
  // A page split by version says which environments each of its tabs is for.
  for (QVariant& value : pages) {
    QVariantMap page = value.toMap();
    const QString pageKey = page.value(QStringLiteral("pluginId")).toString() + QLatin1Char('/') + page.value(QStringLiteral("pageId")).toString();
    if (tabs.value(pageKey) < 2) continue;
    QStringList labels;
    for (const QString& environment : page.value(QStringLiteral("environments")).toStringList()) labels.append(label(environment));
    page.insert(QStringLiteral("title"), page.value(QStringLiteral("title")).toString() + QStringLiteral(" · ") + labels.join(QStringLiteral(", ")));
    value = page;
  }
  m_bridge->publish(kKey, QVariantMap{{QStringLiteral("environments"), environments},
                                      {QStringLiteral("pages"), pages},
                                      {QStringLiteral("threadKinds"), threadKinds},
                                      {QStringLiteral("slots"), slotParts}});
  if (pages != m_pages) {
    m_pages = pages;
    emit pagesChanged();
  }
}

bool McPluginController::handle(const QString& action, const QVariant& payload) {
  if (!action.startsWith(QLatin1String("mcPlugins."))) return false;
  const QVariantMap map = payload.toMap();
  const QString environment = map.value(QStringLiteral("environment")).toString();
  const QString id = map.value(QStringLiteral("id")).toString();
  if (environment.isEmpty() || id.isEmpty()) return true;
  const QJsonObject input{{QStringLiteral("id"), id}};
  if (action == QLatin1String("mcPlugins.enable")) {
    enable(environment, id);
  } else if (action == QLatin1String("mcPlugins.disable")) {
    request(environment, QStringLiteral("plugins.disable"), input, QStringLiteral("The plugin could not be disabled"));
  } else if (action == QLatin1String("mcPlugins.restart")) {
    request(environment, QStringLiteral("plugins.restart"), input, QStringLiteral("The plugin could not be restarted"));
  } else {
    return false;
  }
  return true;
}

// A plugin runs only with the permissions it asks for, so the user sees each
// one, and why, before it starts.
void McPluginController::enable(const QString& environment, const QString& id) {
  QJsonObject entry;
  for (const QJsonValue& value : m_plugins.value(environment)) {
    if (str(value[QLatin1String("id")]) == id) entry = value.toObject();
  }
  QStringList accepted;
  QStringList lines;
  for (const QJsonValue& permission : entry.value(QLatin1String("permissions")).toArray()) {
    accepted.append(str(permission[QLatin1String("id")]));
    const QString reason = str(permission[QLatin1String("reason")]);
    lines.append(reason.isEmpty() ? QStringLiteral("• %1").arg(str(permission[QLatin1String("label")]))
                                  : QStringLiteral("• %1: %2").arg(str(permission[QLatin1String("label")]), reason));
  }
  if (entry.value(QLatin1String("runsCode")).toBool()) {
    lines.append(QStringLiteral("It runs its own code inside the MC on %1.").arg(label(environment)));
  }
  const QJsonObject input{{QStringLiteral("id"), id}, {QStringLiteral("acceptPermissions"), QJsonArray::fromStringList(accepted)}};
  const QString failed = QStringLiteral("The plugin could not be enabled");
  auto* menu = NativeShell::of(this)->controller<MenuController>();
  if (lines.isEmpty() || !menu) {
    request(environment, QStringLiteral("plugins.enable"), input, failed);
    return;
  }
  const QString name = str(entry.value(QLatin1String("name")));
  menu->confirm(QStringLiteral("Enable \"%1\"?").arg(name.isEmpty() ? id : name),
                QStringLiteral("It asks to:\n%1").arg(lines.join(QLatin1Char('\n'))), QStringLiteral("Enable"), false,
                [this, environment, input, failed] { request(environment, QStringLiteral("plugins.enable"), input, failed); });
}

void McPluginController::request(const QString& environment, const QString& method, const QJsonObject& input,
                                 const QString& failed) {
  m_client->call(this, environment, method, input, [this, failed](const QJsonValue&, const std::optional<QString>& error) {
    if (!error) return;
    if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) toasts->error(failed, *error);
  });
}

int McPluginController::ask(const QString& environment, const QString& method, const QJsonObject& input) {
  const int request = m_nextRequest++;
  m_client->call(this, environment, method, input, [this, request](const QJsonValue& result, const std::optional<QString>& error) {
    emit answered(request, error ? QVariant() : result.toVariant(), error.value_or(QString()));
  });
  return request;
}

int McPluginController::call(const QString& environment, const QString& id, const QString& method, const QVariant& input) {
  // A JS object comes as a QJSValue, which QJsonValue cannot read.
  const QVariant plain = input.metaType() == QMetaType::fromType<QJSValue>() ? input.value<QJSValue>().toVariant() : input;
  return ask(environment, QStringLiteral("plugins.call"),
             {{QStringLiteral("id"), id}, {QStringLiteral("method"), method}, {QStringLiteral("input"), QJsonValue::fromVariant(plain)}});
}

int McPluginController::saveSettings(const QString& environment, const QString& id, const QVariantMap& settings) {
  return ask(environment, QStringLiteral("plugins.saveSettings"),
             {{QStringLiteral("id"), id}, {QStringLiteral("settings"), QJsonObject::fromVariantMap(settings)}});
}

int McPluginController::watch(const QString& environment, const QString& id, const QString& topic) {
  const QString key = environment + QLatin1Char('/') + id + QLatin1Char('/') + topic;
  if (!m_topics.contains(key)) {
    const QJsonObject shape{{QStringLiteral("type"), QStringLiteral("plugin")}, {QStringLiteral("environment"), environment},
                            {QStringLiteral("id"), id}, {QStringLiteral("topic"), topic}};
    m_topics[key].subscription = m_client->subscribe(this, shape, [this, key](const QJsonObject& frame) {
      if (frame.value(QLatin1String("t")).toString() != QLatin1String("plugin") || !m_topics.contains(key)) return;
      Topic& followed = m_topics[key];
      followed.last = frame.value(QLatin1String("value")).toVariant();
      followed.known = true;
      const QVariant value = followed.last;
      for (const int watch : QSet<int>(followed.watches)) emit published(watch, value);
    });
  }
  const int watch = m_nextWatch++;
  m_topics[key].watches.insert(watch);
  m_watches.insert(watch, key);
  if (m_topics[key].known) {
    // After the caller has kept the watch, as when the MC answers.
    QTimer::singleShot(0, this, [this, watch] {
      const auto it = m_topics.constFind(m_watches.value(watch));
      if (it != m_topics.constEnd() && it->known) emit published(watch, it->last);
    });
  }
  return watch;
}

void McPluginController::unwatch(int watch) {
  const QString key = m_watches.take(watch);
  const auto it = m_topics.find(key);
  if (it == m_topics.end()) return;
  it->watches.remove(watch);
  if (!it->watches.isEmpty()) return;
  m_client->unsubscribe(it->subscription);
  m_topics.erase(it);
}
