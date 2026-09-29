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

// Owns the `sidebar` key once the shell has its node's first snapshot: rows
// and projects come from ShellStore, grouped as the page groups them
// (sidebar::groupProjects), drafts from DraftController, and the row actions
// (settle, snooze, wake, mark unread, dismiss the woke pill) and the project
// scope stay here.
class SidebarController : public QObject {
  Q_OBJECT

public:
  SidebarController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  // Starts publishing `sidebar` and claiming its actions.
  void activate();
  bool isActive() const { return m_active; }

  // The logical projects, in sidebar order.
  const QList<sidebar::ProjectGroup>& groups() const { return m_groups; }
  const sidebar::ProjectGroup* group(const QString& key) const;
  // The logical project `<environmentId>:<projectId>` belongs to.
  std::optional<QString> logicalProjectKey(const QString& environmentId, const QString& projectId) const;
  // The project the list is scoped to, if any.
  const sidebar::Nullable& scope() const { return m_scope; }
  // The rows' keys in the order they render.
  const QStringList& orderedKeys() const { return m_view.orderedKeys; }

  // Tests pin the clock and locale; the app uses the system's.
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }
  void setLocale(const QLocale& locale) { m_locale = locale; }

  void refresh();
  // The ShellBridge interceptor: true when the action was handled here.
  bool handle(const QString& action, const QVariant& payload);

  // Runs `command`, which takes the thread `key` out of the list (settle,
  // snooze, archive, delete); the window moves on to the next card when it
  // showed the thread, once the command lands. Failures toast `failureTitle`.
  void park(const QString& key, QJsonObject command, const QString& failureTitle,
            std::function<void()> onSuccess = {});
  // The snooze choices now, and snoozing the thread `key` until one's time,
  // with an Undo toast.
  QList<sidebar::SnoozePreset> snoozePresets() const;
  static QString snoozeLabel(const sidebar::SnoozePreset& preset);
  void snooze(const QString& key, const QString& snoozedUntil);

signals:
  // The logical projects were grouped differently: one came, went, or took
  // other folders (a checkout, or a change of grouping).
  void grouped();

private:
  void command(const QString& environmentId, QJsonObject command, const QString& failureTitle,
               std::function<void()> onSuccess = {});
  void openSnoozeMenu(const QString& key, double x, double y);
  ToastController* toasts() const;
  // The client settings grouping, ordering and time labels read, from this
  // device's preferences (SettingsController), else their defaults.
  void readSettings();
  // The open thread, from the shell's route.
  QString activeThreadKey() const;

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTime(); };
  QLocale m_locale;
  QTimer m_minute;
  bool m_active = false;
  sidebar::GroupingSettings m_grouping;
  QString m_timestampFormat = QStringLiteral("locale");
  QList<sidebar::ProjectGroup> m_groups;
  sidebar::Nullable m_scope;
  sidebar::View m_view;
  QSet<QString> m_pending;
};
