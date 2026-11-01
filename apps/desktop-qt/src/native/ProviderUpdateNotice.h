#pragma once

#include <QDateTime>
#include <QHash>
#include <QJsonArray>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QString>
#include <QTimer>

#include <functional>
#include <optional>

#include "NativeController.h"
#include "ProviderUpdates.h"

class EnvironmentSettings;
class NativeWindow;
class McClient;
class SettingsController;
class ShellBridge;
class ShellStore;
class ToastController;

// Provider updates, as the shell tells of them.
//
// At launch, the enabled providers that are behind a latest release they can
// use are offered in one "Update Available" toast, one per driver. With one
// environment, Update runs `server.updateProvider` for each the MC can update
// itself, a loading toast standing in until the MC says how it went; Settings
// opens the Providers section. With several environments (the cluster's, as
// the MC labels them: a Windows machine and its WSL backend, say) the toast
// lists one row per environment with what it can update, each with its own
// Update, held back up to 30 s while an online environment's providers have
// not arrived. Closing the toast dismisses that set of versions for good
// (this device's `dismissedProviderUpdateNotificationKeys`); a set is offered
// once per run either way.
//
// Publishes `providerUpdates`: {notice}, the sidebar's notice of this
// environment's updates ({key, tone, title, description, dismissible}, or
// null); `providerUpdates.dismissNotice` dismisses it and
// `providerUpdates.openNotice` opens the Providers settings.
//
// One per process: the toast shows in the window in use.
class ProviderUpdateNotice : public QObject, public NativeController {
  Q_OBJECT

public:
  // How long an offer waits for an environment still connecting.
  static constexpr qint64 kSettlingMs = 30'000;

  ProviderUpdateNotice(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;
  void attach(NativeWindow*) override { evaluate(); }

  // Tests pin the clock; the app uses the system's.
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }
  // Acts on the deadlines passed: a success's notice, an update unanswered,
  // the wait for an environment; the timer calls it at the next one.
  void expire();

private:
  void evaluate();
  // One environment: the toast and its updates.
  void evaluateSingle(const QJsonArray& providers);
  // Several: the toast's rows.
  void evaluateRows(const QStringList& environments, const QJsonArray& local);
  QList<providerUpdates::Group> groups(const QStringList& environments, const QJsonArray& local) const;
  void showRows();
  void startRow(const QString& environmentId);
  void closePrompt();
  void runUpdates(const QJsonArray& providers);
  // Reports the update once no provider is still updating; false while one is.
  bool report(const QJsonArray& providers);
  void openSettings();
  void dismissKey(const QString& key);
  QStringList dismissedKeys() const;
  void publish();
  void schedule();
  ToastController* toasts() const;
  SettingsController* settings() const;

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  EnvironmentSettings* m_scope;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  QTimer m_timer;
  bool m_active = false;
  // The version sets offered this run.
  QSet<QString> m_seen;
  // The prompt on screen, where, and the versions it offers.
  QPointer<ToastController> m_toasts;
  QString m_promptId;
  QString m_promptKey;
  QMetaObject::Connection m_closed;
  // The update the user started: which instances, until it is reported, and
  // the toast saying it runs.
  struct Update {
    QSet<QString> instanceIds;
    int count = 0;
    QString toastId;
  };
  std::optional<Update> m_update;

  // Other environments' providers, by environment, once they arrived.
  QHash<QString, QJsonArray> m_remote;
  // The rows' prompt: the set it was opened for still the live one, whether
  // the user started an update from it (it then stays as the set changes),
  // when it opened, and how each environment's update went.
  bool m_rowsMode = false;
  QString m_liveKey;
  bool m_interacted = false;
  QString m_openedAt;
  providerUpdates::Rows m_rows;
  QList<providerUpdates::Group> m_groups;
  // Since when an environment has been connecting.
  std::optional<QDateTime> m_settlingSince;

  providerUpdates::Sidebar m_sidebar;
};
