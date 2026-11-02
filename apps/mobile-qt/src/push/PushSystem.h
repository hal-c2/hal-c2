#pragma once

#include <QJsonObject>
#include <QList>
#include <QString>

#include <functional>
#include <memory>

class QObject;

// The device's side of notifications as the app (Notifications.h) uses it:
// whether HAL-C2 may post them, asking for that, the UnifiedPush distributors
// installed and an endpoint from one, and putting up what the push inbox
// (PushInbox.h) says to. The endpoint itself is kept in the inbox's file,
// where Android's receiver writes it while the app may not be running. The
// scenarios put one of their own here (tests/FakePushSystem.h).
class PushSystem {
public:
  enum class Permission { Granted, Denied, Ask };
  struct Distributor {
    QString id;     // its package
    QString label;  // what the user knows it as
  };

  virtual ~PushSystem() = default;

  // Whether this build can receive pushes at all.
  virtual bool supported() = 0;
  // Android's API level; 0 off Android.
  virtual int sdk() = 0;
  virtual Permission permission() = 0;
  // Asks the user, where the system still does. `answered` is called once,
  // unless `context` goes first.
  virtual void requestPermission(QObject* context, std::function<void(Permission)> answered) = 0;
  // HAL-C2's page of notification settings in the system's settings.
  virtual void openSettings() = 0;
  // Android 16's page for live updates.
  virtual void openLiveUpdateSettings() = 0;
  virtual QList<Distributor> distributors() = 0;
  // Asks `distributor` for an endpoint for this phone, which reaches the
  // inbox later; `changed` follows.
  virtual void subscribe(const QString& distributor) = 0;
  virtual void unsubscribe() = 0;
  // Puts up, replaces or takes down notifications as the inbox's effects say.
  virtual void show(const QJsonObject& effects) = 0;
  // Wall clock, ms since the epoch.
  virtual qint64 now() = 0;

  // The endpoint changed, or went: on the app's thread.
  std::function<void()> changed;
};

// This device's: Android's notifications and UnifiedPush, or a system that
// supports none of it.
std::shared_ptr<PushSystem> devicePushSystem(const QString& dataDir);
