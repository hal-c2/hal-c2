#pragma once

#include <QList>
#include <QObject>
#include <QString>
#include <QVariantMap>

#include <optional>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// Where the window is: the shell's route, its back stack, and the last route
// kept across restarts (setStorePath). Publishes `route`: {kind, threadKey,
// draftId, projectKey, section, title, canGoBack, target, targetSeq}, where
// kind is one of home, thread, draft, settings (section: the settings path),
// pullRequests, usage. `target` is the setting a settings
// search result opened (its objectName in the settings section) until the
// route moves on; `targetSeq` counts the openings, so opening it again reveals
// it again.
//
// Home is where the window has no thread; DraftController lands it on a
// draft from there. The open thread going away (deleted here or elsewhere)
// sends the window home too.
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
    static Route settings(const QString& section = {}) { return {QStringLiteral("settings"), {}, {}, {}, section}; }
    static Route of(const QString& kind) { return {kind, {}, {}, {}, {}}; }
    static std::optional<Route> fromVariant(const QVariant& value);
    QVariantMap toVariant() const;
    bool operator==(const Route&) const = default;
  };

  // Settings sections other controllers open and close.
  static inline const QString kClusterSection = QStringLiteral("/settings/cluster");
  static inline const QString kKeybindingsSection = QStringLiteral("/settings/keybindings");
  static inline const QString kConnectionsSection = QStringLiteral("/settings/connections");
  static inline const QString kProvidersSection = QStringLiteral("/settings/providers");
  static inline const QString kArchivedSection = QStringLiteral("/settings/archived");
  // Its commands in Keybindings.commands.
  static inline const QString kOpenSettings = QStringLiteral("settings.open");
  static inline const QString kOpenUsage = QStringLiteral("usage.open");
  static inline const QString kOpenPullRequests = QStringLiteral("pullRequests.open");

  NavigationController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  const Route& route() const { return m_route; }
  // The open thread's key, or empty.
  QString threadKey() const { return m_route.kind == QLatin1String("thread") ? m_route.threadKey : QString(); }
  // Moves to `route`, keeping where the user was on the back stack.
  void open(const Route& route) { go(route, false); }
  // Moves to `route` in place of the current one (a draft that became a
  // thread, or went away).
  void replace(const Route& route) { go(route, true); }
  // Back to where the user was before, or home.
  void back();
  // To where back() left, if nothing was opened since.
  void forward();

  // Where the last route is kept; restores it from there.
  void setStorePath(const QString& path);

signals:
  void changed();

private:
  void go(Route route, bool replace);
  void publish();
  // Brings a setting of the settings page showing into view (route.target).
  void reveal(const QString& target);
  void save() const;
  // The open thread's row went away: home, unless the sidebar is already
  // moving the window on (park()).
  void leaveVanishedThread();

  ShellBridge* m_bridge;
  ShellStore* m_store;
  Route m_route;
  QList<Route> m_backStack;
  QList<Route> m_forwardStack;
  QString m_storePath;
  bool m_active = false;
  // The setting the last search result opened, until the route moves on.
  QString m_target;
  int m_targetSeq = 0;
  // The open thread's row has been seen, so its absence means it went away
  // rather than has not arrived yet.
  bool m_threadSeen = false;
};
