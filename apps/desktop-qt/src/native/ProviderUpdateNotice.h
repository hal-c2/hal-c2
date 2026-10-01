#pragma once

#include <QJsonArray>
#include <QObject>
#include <QPointer>
#include <QSet>
#include <QString>

#include <optional>

#include "NativeController.h"

class NativeWindow;
class McClient;
class SettingsController;
class ShellBridge;
class ToastController;

// The toast that offers provider updates when the app starts, as the web's
// ProviderUpdatePrimaryNotification does: the enabled providers of this
// machine's environment that are behind their latest release, one per driver,
// in one "Update Available" toast. Update runs `server.updateProvider` for
// each one the MC can update itself and reports how it went; Settings opens
// the Providers section. Closing the toast dismisses that set of versions for
// good (this device's `dismissedProviderUpdateNotificationKeys`); a set is
// offered once per run either way. One per process, as in the web app: the
// toast shows in the window in use.
class ProviderUpdateNotice : public QObject, public NativeController {
  Q_OBJECT

public:
  ProviderUpdateNotice(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString&, const QVariant&) override { return false; }
  void attach(NativeWindow*) override { evaluate(); }

private:
  void evaluate();
  void runUpdates(const QJsonArray& providers);
  // Reports the update once no provider is still updating; false while one is.
  bool report(const QJsonArray& providers);
  void openSettings();
  QStringList dismissedKeys() const;
  ToastController* toasts() const;
  SettingsController* settings() const;

  McClient* m_client;
  bool m_active = false;
  // The version sets offered this run.
  QSet<QString> m_seen;
  // The prompt on screen, where, and the versions it offers.
  QPointer<ToastController> m_toasts;
  QString m_promptId;
  QString m_promptKey;
  QMetaObject::Connection m_closed;
  // The update the user started: which instances, until it is reported.
  struct Update {
    QSet<QString> instanceIds;
    int count = 0;
  };
  std::optional<Update> m_update;
};
