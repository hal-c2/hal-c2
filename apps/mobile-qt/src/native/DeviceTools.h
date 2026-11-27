#pragma once

#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QVariantMap>

class McClient;
class QNetworkReply;

// The Tools drawer of a device tab (ThreadDevices' `tools`): the shown
// device's own settings and one-shot actions, through the MC's
// `device.detail` and `device.action` (never the hub's shell channel; see
// docs/internals/devices.md), plus the read-only hub feeds the proxy
// allowlists: the foreground app and the simulator's event log over
// server-sent events, and the accessibility tree the overlay draws.
//
// Every change is one `device.action`; the detail it returns replaces what
// the controls show, so a refused change never reads as applied. While a
// change runs (or the first detail is read) every control is disabled.
//
// Publishes `view` for the DevicePanel brick:
//   {open, platform, loaded, pending, error,
//    foreground (the app in front's id, or "—"), hasForeground,
//    settings: the DeviceDetail's settings as read (absent = the device
//    does not report it, and its control cannot be changed),
//    location: {latitude, longitude} as typed, eventLog: {offered, open,
//    entries: [{time, summary}]}, axOverlay, axOffered (device access),
//    axElements: [{label, x, y, width, height}] normalized to the screen}.
class DeviceTools : public QObject {
  Q_OBJECT
  Q_PROPERTY(QVariantMap view READ view NOTIFY viewChanged)

public:
  explicit DeviceTools(McClient* client, QObject* parent = nullptr);
  ~DeviceTools() override;

  // The device whose tab shows ({}: none). A different device starts fresh.
  void setTarget(const QString& environment, const QString& hubBase, const QString& hostId, const QString& deviceId,
                 const QString& platform);

  QVariantMap view() const { return m_view; }

  Q_INVOKABLE void setOpen(bool open);
  // A choice control (Appearance, Text size, Liquid Glass, Color filter,
  // Orientation) picked `choice`, its label as the drawer shows it.
  Q_INVOKABLE void choose(const QString& control, const QString& choice);
  Q_INVOKABLE void setSwitch(const QString& setting, bool on);
  // The Open (a URL) and Launch (an app id) rows.
  Q_INVOKABLE void submit(const QString& field, const QString& value);
  Q_INVOKABLE void terminate();
  Q_INVOKABLE void relaunch();
  Q_INVOKABLE void setLocationText(const QString& latitude, const QString& longitude);
  Q_INVOKABLE void applyLocation();
  Q_INVOKABLE void applyPreset(const QString& city);
  Q_INVOKABLE void clearLocation();
  Q_INVOKABLE void decide(const QString& appId, const QString& permission, const QString& decision);
  Q_INVOKABLE void sendPush(const QString& text);
  Q_INVOKABLE void setEventLogOpen(bool open);
  Q_INVOKABLE void setAxOverlay(bool on);

signals:
  void viewChanged();

private:
  void read();
  void act(const QJsonObject& action);
  // `fromAction` ends the change that was out; a plain read landing while
  // one is out must not.
  void take(const QJsonObject& detail, bool fromAction);
  QString vendorPath(const QString& path) const;
  // A server-sent-events feed on one hub route, while `wanted`.
  struct Feed {
    QPointer<QNetworkReply> reply;
    QByteArray buffer;
  };
  void follow(Feed& feed, const QString& path, const std::function<void(const QJsonObject&)>& onEvent,
              const std::function<void()>& onEnd = {});
  void unfollow(Feed& feed);
  void followForeground();
  void followEventLog();
  void fetchAx();
  void dropAx();
  void publish();

  McClient* m_client;
  QNetworkAccessManager* m_http;
  QString m_environment;
  QString m_hubBase;
  QString m_hostId;
  QString m_deviceId;
  QString m_platform;
  int m_generation = 0;

  bool m_open = false;
  bool m_loaded = false;
  bool m_pending = false;
  QString m_error;
  QJsonObject m_settings;
  // The foreground app: the detail's, until the feed says another (or none).
  QString m_foreground;
  // The last app seen in front: Relaunch after Terminate names it.
  QString m_lastForeground;
  bool m_foregroundKnown = false;
  bool m_foregroundLive = false;
  QTimer m_foregroundRetry{this};
  // How long the next retry waits: it doubles while the feed keeps ending.
  int m_foregroundWait = 2000;

  QString m_latitude;
  QString m_longitude;

  Feed m_foregroundFeed;
  Feed m_eventFeed;
  bool m_eventLogOpen = false;
  QVariantList m_events;

  bool m_axOverlay = false;
  QTimer m_axTimer;
  QPointer<QNetworkReply> m_axReply;
  QVariantList m_axElements;

  QVariantMap m_view;
};
