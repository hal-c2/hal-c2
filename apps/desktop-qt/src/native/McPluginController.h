#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QVariantList>
#include <QVariantMap>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// The plugins each environment's MC runs (packages/contracts plugin.ts), and
// their UI parts. Every online environment's `plugins` shape is followed; the
// files a plugin's manifest names (pages, thread looks, slots, its settings
// page, icon and screenshots) are fetched with `plugins.file` and kept under
// the cache by environment, plugin and revision, so a new version is loaded
// from its own files and an unchanged one is not fetched again.
//
// Publishes `mcPlugins`: {environments [{id, label, plugins [PluginEntry +
// {iconUrl, screenshotUrls [{url, caption}], settingsPageUrl}]}], pages [{key
// ("<plugin>/<page>"), pluginId, pageId, title, iconUrl, url, error,
// environments [ids]}], one per page whatever runs it, threadKinds
// {"<environment>/<plugin>/<kind>": {label, rowMark, header}} of running
// plugins, slots [{slot, url, pluginId, environment, order}]}. A page's `url`
// is empty while its file is on its way; `error` says why it never will be.
//
// Actions: `mcPlugins.enable {environment, id}` (asks for the permissions the
// plugin wants first, and enables it only with them), `mcPlugins.disable`,
// `mcPlugins.restart`; what the MC refuses is toasted.
//
// UI parts reach their MC part through the `McPlugins` singleton:
// call(...) answers with `answered`, and watch(...) follows a topic with
// `published` until unwatch(...) (PluginContext.qml wraps both). Settings are
// saved with saveSettings(...), answered the same way, so the page that saves
// them can show what the plugin refuses.
class McPluginController : public QObject, public NativeController {
  Q_OBJECT

public:
  McPluginController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Where fetched files are kept (`<cache>/mc-plugins`).
  void setCacheDir(const QString& dir) { m_cacheDir = dir; }
  // The published pages, for the window's tabs.
  QVariantList pages() const { return m_pages; }

  // Asks plugin `id` on `environment` (`plugins.call`); the answer comes as
  // `answered(request, result, error)`.
  Q_INVOKABLE int call(const QString& environment, const QString& id, const QString& method, const QVariant& input);
  // Saves plugin `id`'s settings on `environment` (`plugins.saveSettings`); the
  // answer comes as `answered`.
  Q_INVOKABLE int saveSettings(const QString& environment, const QString& id, const QVariantMap& settings);
  // Follows what plugin `id` publishes on `topic`, as `published(watch, value)`.
  // Watches of one topic share one subscription, and a later one is given the
  // last value at once, so a part repeated per row costs one topic's traffic.
  Q_INVOKABLE int watch(const QString& environment, const QString& id, const QString& topic);
  Q_INVOKABLE void unwatch(int watch);

signals:
  void pagesChanged();
  void answered(int request, const QVariant& result, const QString& error);
  void published(int watch, const QVariant& value);

private:
  // One `plugin` shape the UI parts follow, and the watches that share it.
  struct Topic {
    int subscription = -1;
    QSet<int> watches;
    QVariant last;
    bool known = false;
  };

  // One plugin's files at one revision.
  struct Files {
    QString revision;
    bool runs = false;
    QHash<QString, QString> urls;    // path → local file URL
    QHash<QString, QString> errors;  // path → why it could not be fetched
    QSet<QString> pending;
  };

  void follow();
  void fetch(const QString& environment, const QJsonObject& entry);
  QString cachePath(const QString& environment, const QString& id, const QString& revision, bool runs, const QString& path) const;
  void publish();
  QString label(const QString& environment) const;
  void enable(const QString& environment, const QString& id);
  void request(const QString& environment, const QString& method, const QJsonObject& input, const QString& failed);
  // Calls `method`, answered as `answered(request, ...)`.
  int ask(const QString& environment, const QString& method, const QJsonObject& input);

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  QString m_cacheDir;
  QHash<QString, int> m_subscriptions;     // environment → `plugins` shape
  QHash<QString, QJsonArray> m_plugins;    // environment → PluginEntry[]
  QHash<QString, Files> m_files;           // "<environment>/<id>" → files
  QHash<QString, Topic> m_topics;          // "<environment>/<id>/<topic>" → its subscription
  QHash<int, QString> m_watches;           // watch → its topic
  int m_nextWatch = 1;
  int m_nextRequest = 1;
  QVariantList m_pages;
};
