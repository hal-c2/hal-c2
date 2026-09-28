#pragma once

#include <QDateTime>
#include <QJsonObject>
#include <QLocale>
#include <QObject>
#include <QSet>
#include <QTimer>
#include <QVariant>

#include <functional>

#include "SidebarModel.h"

class NodeClient;
class ShellBridge;
class ShellStore;
class ToastController;

// Owns the `sidebar` key once the shell has its own node connection: rows
// come from ShellStore, project groups and drafts from the page's
// `sidebarInput`, and the row actions (settle, snooze, wake, mark unread,
// dismiss the woke pill) go straight to the node.
class SidebarController : public QObject {
  Q_OBJECT

public:
  SidebarController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  // Starts publishing `sidebar` and claiming its actions, from the page's scope.
  void activate();
  // Leaves `sidebar` and its actions to the page again.
  void deactivate() { m_active = false; }
  bool isActive() const { return m_active; }
  // Whether every project the page groups lives on the node's cluster; rows
  // from any other environment exist only in the page.
  bool coversPage() const;
  // The rows' keys in the order they render.
  const QStringList& orderedKeys() const { return m_view.orderedKeys; }
  // The project group a thread belongs to, as the page groups projects.
  std::optional<QString> projectKeyOf(const QString& threadKey) const;

  // Tests pin the clock and locale; the app uses the system's.
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }
  void setLocale(const QLocale& locale) { m_locale = locale; }

  void refresh();
  // The ShellBridge interceptor: true when the action was handled here.
  bool handle(const QString& action, const QVariant& payload);

private:
  void command(const QString& environmentId, QJsonObject command, const QString& failureTitle,
               std::function<void()> onSuccess = {});
  void park(const QString& key, QJsonObject command, const QString& failureTitle,
            std::function<void()> onSuccess = {});
  void openSnoozeMenu(const QString& key, double x, double y);
  void selectSnooze(const QString& id);
  ToastController* toasts() const;
  // The open thread, from the shell's route.
  QString activeThreadKey() const;
  std::optional<QString> logicalProjectKey(const sidebar::Thread& thread) const;

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTime(); };
  QLocale m_locale;
  QTimer m_minute;
  bool m_active = false;
  bool m_inputReceived = false;
  sidebar::Input m_input;
  sidebar::Nullable m_scope;
  sidebar::View m_view;
  QSet<QString> m_pending;
  int m_nextMenuId = 1;
  struct SnoozeMenu {
    QString requestId;
    QString key;
    QList<sidebar::SnoozePreset> presets;
  };
  std::optional<SnoozeMenu> m_menu;
};
