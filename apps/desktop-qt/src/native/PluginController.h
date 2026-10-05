#pragma once

#include <QFileSystemWatcher>
#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QSet>
#include <QString>
#include <QVariant>

#include "NativeController.h"

class McClient;
class QNetworkAccessManager;
class ShellBridge;

// This device's UI plugins: the QML files in `<config dir>/plugins`, each a
// `Plugin` whose `Contribution`s fill the bricks' `PluginSlot`s. The
// controller owns which files there are, which are turned off and where a
// downloaded one came from (`plugins.json` beside the directory, the TUI's
// format); the bricks' PluginRegistry loads what `files` lists into the QML
// engine and reports back what loaded and what did not.
//
// `plugins` is {dir, files: [{file, source, revision}], items: [{id, file,
// order, description, slots, shown, url}], disabled: [{id, file}], failed: [{id,
// file, message}]}. A file is read again whenever it is saved, so the
// registry replaces the plugin in place; one that no longer loads leaves the
// version already running.
//
// `plugins.install {url}` downloads a plugin file after the user has been
// told nothing vouches for it, `plugins.disable` / `plugins.enable {id}`
// turn one off and on (kept across restarts), `plugins.remove {id}` deletes
// its file after a question, and `plugins.report {plugins, problems}` is the
// registry's.
class PluginController : public QObject, public NativeController {
  Q_OBJECT

public:
  // What a downloaded plugin file may weigh.
  static constexpr qsizetype maxPluginBytes = 512 * 1024;

  PluginController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  void activate() override {}
  bool handle(const QString& action, const QVariant& payload) override;

  // The shell's config directory: plugins are `<dir>/plugins/*.qml`, in file
  // name order, and the records `<dir>/plugins.json`. Read at once.
  void setConfigDir(const QString& dir);
  QString pluginDir() const { return m_pluginDir; }

private:
  struct Disabled {
    QString id;
    QString file;
  };

  void scan();
  void publish();
  void loadRecords();
  void saveRecords();
  void install(const QString& address);
  void download(const QUrl& url, const QString& file);
  void disable(const QString& id);
  void enable(const QString& id);
  void remove(const QString& id);
  void report(const QVariantMap& report);
  QString fileOf(const QString& id) const;
  void toast(const QString& type, const QString& title, const QString& description = {});

  ShellBridge* m_bridge;
  QNetworkAccessManager* m_http = nullptr;
  QFileSystemWatcher m_watcher;
  QString m_configDir;
  QString m_pluginDir;
  // What the registry is to load, in order: {file, source, revision}.
  QVariantList m_files;
  // What it loaded and what it could not.
  QVariantList m_items;
  QVariantList m_problems;
  QList<Disabled> m_disabled;
  // The URL a downloaded file came from, by file.
  QHash<QString, QString> m_sources;
  // Downloaded and not yet seen to load: a file that is no plugin is taken away again.
  QSet<QString> m_checking;
};
