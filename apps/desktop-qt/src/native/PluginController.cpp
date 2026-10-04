#include "PluginController.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSaveFile>
#include <QUrl>

#include <algorithm>

#include "../ShellBridge.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<PluginController> registrar(QStringLiteral("plugins"), {QStringLiteral("plugins")}, nullptr,
                                                            NativeControllerScope::Shared);

const QString kRecords = QStringLiteral("plugins.json");

QString baseName(const QString& file) {
  return QFileInfo(file).completeBaseName();
}

}  // namespace

PluginController::PluginController(ShellBridge* bridge, McClient*, QObject* parent) : QObject(parent), m_bridge(bridge) {
  // A saved plugin file is read again; a new or deleted one changes the list.
  connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, &PluginController::scan);
  connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, &PluginController::scan);
}

void PluginController::setConfigDir(const QString& dir) {
  m_configDir = dir;
  m_pluginDir = QDir(dir).filePath(QStringLiteral("plugins"));
  QDir().mkpath(m_pluginDir);
  if (!m_watcher.directories().isEmpty()) m_watcher.removePaths(m_watcher.directories());
  m_watcher.addPath(m_pluginDir);
  loadRecords();
  scan();
  // Even with nothing to load: the list says what is turned off.
  publish();
}

bool PluginController::handle(const QString& action, const QVariant& payload) {
  if (!action.startsWith(QLatin1String("plugins."))) return false;
  const QVariantMap args = payload.toMap();
  if (action == QLatin1String("plugins.report")) {
    report(args);
  } else if (action == QLatin1String("plugins.install")) {
    install(args.value(QStringLiteral("url")).toString().trimmed());
  } else if (action == QLatin1String("plugins.disable")) {
    disable(args.value(QStringLiteral("id")).toString());
  } else if (action == QLatin1String("plugins.enable")) {
    enable(args.value(QStringLiteral("id")).toString());
  } else if (action == QLatin1String("plugins.remove")) {
    remove(args.value(QStringLiteral("id")).toString());
  } else {
    return false;
  }
  return true;
}

void PluginController::loadRecords() {
  m_disabled.clear();
  m_sources.clear();
  QFile file(QDir(m_configDir).filePath(kRecords));
  if (!file.open(QIODevice::ReadOnly)) return;
  const QJsonObject records = QJsonDocument::fromJson(file.readAll()).object();
  for (const QJsonValue& value : records.value(QLatin1String("disabled")).toArray()) {
    const QJsonObject entry = value.toObject();
    const QString id = entry.value(QLatin1String("id")).toString();
    const QString path = entry.value(QLatin1String("file")).toString();
    if (!id.isEmpty() && !path.isEmpty()) m_disabled.append({id, path});
  }
  const QJsonObject sources = records.value(QLatin1String("sources")).toObject();
  for (auto it = sources.begin(); it != sources.end(); ++it) m_sources.insert(it.key(), it.value().toString());
}

void PluginController::saveRecords() {
  if (m_configDir.isEmpty()) return;
  QJsonArray disabled;
  for (const Disabled& entry : std::as_const(m_disabled)) {
    disabled.append(QJsonObject{{QStringLiteral("id"), entry.id}, {QStringLiteral("file"), entry.file}});
  }
  QJsonObject sources;
  for (auto it = m_sources.cbegin(); it != m_sources.cend(); ++it) sources.insert(it.key(), it.value());
  QSaveFile file(QDir(m_configDir).filePath(kRecords));
  if (!file.open(QIODevice::WriteOnly)) return;
  file.write(QJsonDocument(QJsonObject{{QStringLiteral("disabled"), disabled}, {QStringLiteral("sources"), sources}}).toJson());
  file.commit();
}

// The plugin files there are, less the ones turned off, each with its text:
// the registry instantiates that, so a save is seen as a new revision.
void PluginController::scan() {
  if (m_pluginDir.isEmpty()) return;
  QVariantList files;
  QStringList watched;
  const QFileInfoList entries = QDir(m_pluginDir).entryInfoList({QStringLiteral("*.qml")}, QDir::Files, QDir::Name);
  for (const QFileInfo& info : entries) {
    const QString path = info.absoluteFilePath();
    watched.append(path);
    if (std::any_of(m_disabled.cbegin(), m_disabled.cend(), [&](const Disabled& entry) { return entry.file == path; })) continue;
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) continue;
    const QByteArray source = file.readAll();
    files.append(QVariantMap{{QStringLiteral("file"), path},
                             {QStringLiteral("source"), QString::fromUtf8(source)},
                             {QStringLiteral("revision"), QString::number(qHash(source)) + QLatin1Char(':') + QString::number(source.size())}});
  }
  // A file replaced by a save loses its watch.
  for (const QString& path : watched) {
    if (!m_watcher.files().contains(path)) m_watcher.addPath(path);
  }
  // A turned-off plugin whose file is gone is gone.
  const qsizetype before = m_disabled.size();
  m_disabled.removeIf([&](const Disabled& entry) { return !watched.contains(entry.file); });
  if (m_disabled.size() != before) saveRecords();
  if (files == m_files) return;
  m_files = files;
  publish();
}

void PluginController::publish() {
  QVariantList items;
  for (const QVariant& value : std::as_const(m_items)) {
    QVariantMap item = value.toMap();
    item.insert(QStringLiteral("url"), m_sources.value(item.value(QStringLiteral("file")).toString()));
    items.append(item);
  }
  QVariantList disabled;
  for (const Disabled& entry : std::as_const(m_disabled)) {
    disabled.append(QVariantMap{{QStringLiteral("id"), entry.id}, {QStringLiteral("file"), entry.file}});
  }
  m_bridge->publish(QStringLiteral("plugins"), QVariantMap{
                                                   {QStringLiteral("dir"), m_pluginDir},
                                                   {QStringLiteral("files"), m_files},
                                                   {QStringLiteral("items"), items},
                                                   {QStringLiteral("disabled"), disabled},
                                                   {QStringLiteral("failed"), m_problems},
                                               });
}

// What the registry loaded ({id, file, order, description, slots}) and could
// not ({id, file, message}).
void PluginController::report(const QVariantMap& report) {
  m_items = report.value(QStringLiteral("plugins")).toList();
  m_problems = report.value(QStringLiteral("problems")).toList();
  // The loader is the check of a downloaded file: one that is no plugin goes.
  const QSet<QString> checking = std::exchange(m_checking, {});
  bool removed = false;
  for (const QString& file : checking) {
    const auto of = [&](const QVariantList& list) -> QVariantMap {
      for (const QVariant& value : list) {
        if (value.toMap().value(QStringLiteral("file")) == file) return value.toMap();
      }
      return {};
    };
    const QVariantMap loaded = of(m_items);
    if (!loaded.isEmpty()) {
      toast(QStringLiteral("success"), QStringLiteral("Plugin \"%1\" loaded.").arg(loaded.value(QStringLiteral("id")).toString()));
      continue;
    }
    const QVariantMap problem = of(m_problems);
    if (problem.isEmpty()) {
      // Not looked at yet.
      m_checking.insert(file);
      continue;
    }
    toast(QStringLiteral("error"), QStringLiteral("The plugin could not be loaded"), problem.value(QStringLiteral("message")).toString());
    removed = QFile::remove(file) || removed;
    m_sources.remove(file);
    saveRecords();
    m_problems.removeIf([&](const QVariant& value) { return value.toMap().value(QStringLiteral("file")) == file; });
  }
  publish();
  if (removed) scan();
}

void PluginController::install(const QString& address) {
  const QUrl url(address, QUrl::StrictMode);
  static const QRegularExpression pluginFile(QStringLiteral("^[\\w.-]+\\.qml$"));
  const QString name = QFileInfo(url.path()).fileName();
  if (!url.isValid() || (url.scheme() != QLatin1String("https") && url.scheme() != QLatin1String("http")) || !pluginFile.match(name).hasMatch()) {
    toast(QStringLiteral("error"), QStringLiteral("A plugin URL is an http(s) address of a .qml file."));
    return;
  }
  if (m_pluginDir.isEmpty()) return;
  const QString file = QDir(m_pluginDir).filePath(name);
  if (QFileInfo::exists(file) && m_sources.value(file) != url.toString()) {
    toast(QStringLiteral("error"), QStringLiteral("A plugin file named %1 is already installed.").arg(name));
    return;
  }
  // Nothing vouches for a pasted address: the user says so first.
  auto* menu = NativeShell::of(this)->controller<MenuController>();
  if (!menu) return;
  menu->confirm(QStringLiteral("Load this unsigned plugin?"),
                QStringLiteral("This plugin is not signed: nothing vouches for what %1 serves, and a plugin runs with this app's own access.").arg(url.host()),
                QStringLiteral("Load plugin"), true, [this, url, file] { download(url, file); },
                [this] { toast(QStringLiteral("info"), QStringLiteral("Nothing was loaded.")); });
}

void PluginController::download(const QUrl& url, const QString& file) {
  if (!m_http) m_http = new QNetworkAccessManager(this);
  QNetworkRequest request(url);
  request.setTransferTimeout(15000);
  QNetworkReply* reply = m_http->get(request);
  connect(reply, &QNetworkReply::finished, this, [this, reply, url, file] {
    reply->deleteLater();
    const QString failed = QStringLiteral("The plugin could not be downloaded");
    if (reply->error() != QNetworkReply::NoError) {
      toast(QStringLiteral("error"), failed, reply->errorString());
      return;
    }
    const QByteArray source = reply->readAll();
    if (source.trimmed().isEmpty() || source.size() > maxPluginBytes) {
      toast(QStringLiteral("error"), failed,
            QStringLiteral("%1 is %2.").arg(QFileInfo(file).fileName(), source.trimmed().isEmpty() ? QStringLiteral("empty") : QStringLiteral("too large")));
      return;
    }
    QSaveFile saved(file);
    if (!saved.open(QIODevice::WriteOnly) || saved.write(source) != source.size() || !saved.commit()) {
      toast(QStringLiteral("error"), failed, saved.errorString());
      return;
    }
    m_sources.insert(file, url.toString());
    m_checking.insert(file);
    saveRecords();
    scan();
  });
}

QString PluginController::fileOf(const QString& id) const {
  for (const QVariant& value : m_items) {
    const QVariantMap item = value.toMap();
    if (item.value(QStringLiteral("id")) == id) return item.value(QStringLiteral("file")).toString();
  }
  return {};
}

void PluginController::disable(const QString& id) {
  const QString file = fileOf(id);
  if (file.isEmpty()) return;
  m_disabled.removeIf([&](const Disabled& entry) { return entry.id == id || entry.file == file; });
  m_disabled.append({id, file});
  saveRecords();
  scan();
  publish();
}

void PluginController::enable(const QString& id) {
  if (m_disabled.removeIf([&](const Disabled& entry) { return entry.id == id; }) == 0) return;
  saveRecords();
  scan();
  publish();
}

void PluginController::remove(const QString& id) {
  QString file = fileOf(id);
  for (const Disabled& entry : std::as_const(m_disabled)) {
    if (entry.id == id) file = entry.file;
  }
  auto* menu = NativeShell::of(this)->controller<MenuController>();
  if (file.isEmpty() || !menu) return;
  menu->confirm(QStringLiteral("Remove the plugin \"%1\"?").arg(id), QStringLiteral("This deletes %1.").arg(QFileInfo(file).fileName()),
                QStringLiteral("Remove plugin"), true, [this, file] {
                  QFile::remove(file);
                  m_sources.remove(file);
                  m_disabled.removeIf([&](const Disabled& entry) { return entry.file == file; });
                  saveRecords();
                  scan();
                  publish();
                });
}

void PluginController::toast(const QString& type, const QString& title, const QString& description) {
  if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) toasts->show(type, title, description);
}
