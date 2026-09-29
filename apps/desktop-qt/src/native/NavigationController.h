#pragma once

#include <QList>
#include <QObject>
#include <QString>
#include <QVariantMap>

#include <optional>

#include "NativeController.h"

class NodeClient;
class ShellBridge;
class ShellStore;

// Where the window is: the shell's route, its back stack, and the last route
// kept across restarts (setStorePath). Publishes `route`: {kind, threadKey,
// draftId, projectKey, section, title, canGoBack, target, targetSeq}, where
// kind is one of home, thread, draft, newThread, settings (section: the
// settings path), pullRequests, usage. `target` is the setting a settings
// search result opened (its objectName on the native page) until the route
// moves on; `targetSeq` counts the openings, so opening it again reveals it
// again.
//
// The page still renders some settings sections, so it follows: every route
// that is not one of the shell's own pages (isNative) and the page does not
// already show goes to it as `route.follow {kind, threadKey, draftId,
// projectKey, section}` (a draft adds its environmentId, projectId and
// threadId, from DraftController), and the page reports where its own links and
// redirects took it as `route.open {..., replace}`. The page is not the source
// of truth; this is.
class NavigationController : public QObject, public NativeController {
  Q_OBJECT

public:
  struct Route {
    QString kind = QStringLiteral("home");
    QString threadKey;
    QString draftId;
    QString projectKey;
    QString section;

    static Route thread(const QString& key) { return {QStringLiteral("thread"), key, {}, {}, {}}; }
    static Route draft(const QString& id) { return {QStringLiteral("draft"), {}, id, {}, {}}; }
    static Route newThread(const QString& projectKey = {}) { return {QStringLiteral("newThread"), {}, {}, projectKey, {}}; }
    static Route settings(const QString& section = {}) { return {QStringLiteral("settings"), {}, {}, {}, section}; }
    static Route of(const QString& kind) { return {kind, {}, {}, {}, {}}; }
    static std::optional<Route> fromVariant(const QVariant& value);
    QVariantMap toVariant() const;
    bool operator==(const Route&) const = default;
  };

  // The shell's own settings pages, which the page does not show.
  static inline const QString kClusterSection = QStringLiteral("/settings/cluster");
  static inline const QString kKeybindingsSection = QStringLiteral("/settings/keybindings");
  static inline const QString kConnectionsSection = QStringLiteral("/settings/connections");
  static inline const QString kProvidersSection = QStringLiteral("/settings/providers");
  static inline const QString kArchivedSection = QStringLiteral("/settings/archived");
  // The shell's own pages: those settings sections and pull requests.
  // The page is not told about them and stays where it was.
  static bool isNative(const Route& route) {
    return route == Route::settings(kClusterSection) || route == Route::settings(kConnectionsSection) ||
           route == Route::settings(kKeybindingsSection) ||
           route == Route::settings(kProvidersSection) ||
           route == Route::settings(kArchivedSection) || route.kind == QLatin1String("pullRequests") ||
           route.kind == QLatin1String("usage");
  }

  // Its commands in Keybindings.commands.
  static inline const QString kOpenSettings = QStringLiteral("settings.open");
  static inline const QString kOpenUsage = QStringLiteral("usage.open");

  NavigationController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  const Route& route() const { return m_route; }
  // The open thread's key, or empty.
  QString threadKey() const { return m_route.kind == QLatin1String("thread") ? m_route.threadKey : QString(); }
  // Moves to `route`, keeping where the user was on the back stack.
  void open(const Route& route) { go(route, false, true); }
  // Moves to `route` in place of the current one (a draft that became a
  // thread, or went away).
  void replace(const Route& route) { go(route, true, true); }
  // Back to where the user was before, or home.
  void back();

  // Where the last route is kept; restores it from there.
  void setStorePath(const QString& path);
  // A (re)loaded page shows nothing the shell knows of: tell it the route.
  void pageReady();

signals:
  void changed();

private:
  void go(const Route& route, bool replace, bool follow);
  // On one of the shell's own settings pages.
  void follow();
  void publish();
  // Brings a setting of the settings page showing into view (route.target).
  void reveal(const QString& target);
  void save() const;

  ShellBridge* m_bridge;
  ShellStore* m_store;
  Route m_route;
  QList<Route> m_backStack;
  // What the page shows as far as the shell knows: the last route it was told
  // or reported. Unknown until the page first says so.
  std::optional<Route> m_pageRoute;
  QString m_storePath;
  bool m_active = false;
  // The setting the last search result opened, until the route moves on.
  QString m_target;
  int m_targetSeq = 0;
  // The route came from the last run and the page has not been anywhere since.
  bool m_restored = false;
};
