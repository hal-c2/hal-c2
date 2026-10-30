#pragma once

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QString>
#include <QVariantMap>

#include "DeviceStream.h"
#include "DeviceTools.h"

class McClient;

// The Device tabs of a thread's right panel: the
// picker (`device`) lists the thread's environment's simulators and
// emulators, and a device tab (`device:<host>:<device>`, both percent-encoded)
// streams one the thread has open. The environment's DeviceServiceState is
// followed through the MC's `devices` shape when a cluster MC serves it,
// and read with `device.list` otherwise (and each time a Device tab shows).
//
// open() is `device.open` for the thread; once it answers, opened() asks the
// panel for the device's tab in place of the picker. powerOff() is
// `device.close` with shutdown, then closed() asks the panel to close the
// tab in the thread it was asked from; closing a tab only stops its stream, the device stays open. A device
// tab whose session ended shows the picker again.
//
// While following, a session the thread gains (an agent's device.open) asks
// for its tab with `automatic` set: the panel skips tabs the user closed.
//
// Publishes `view` for the DevicePanel brick:
//   {loaded, setup (the hub is off or never set up: Settings → Integrations),
//    loading ("" or what the picker waits on: "Opening device…", "Starting
//    device…", the hub installing, "Finding devices…"), empty ("" or why the
//    list is empty), hostDetail, starting ("Starting <names>… This can take a
//    minute." or ""), noAndroid (no Android virtual device and none missing),
//    error ("" or why the last open or power off failed), pendingKey,
//    groups: [{title, devices: [{key, hostId, id, name, platform, detail,
//    action ("Open" | "Start")}]}],
//    banners: [{hostId, label, failed, message, advice, canRetry, retrying}]
//    (each machine installing, starting or failed; none while support is off),
//    wizard: null, or the first-use setup's state {hubOn, hubReady, busy,
//    pending, hubStatus, agentOn, agentStatus, platforms: [{platform, ready,
//    message}], error, canContinue},
//    screen: null, or the shown tab's device {hostId, id, name, platform, description}}.
class ThreadDevices : public QObject {
  Q_OBJECT
  Q_PROPERTY(QVariantMap view READ view NOTIFY viewChanged)
  Q_PROPERTY(DeviceStream* stream READ stream CONSTANT)
  Q_PROPERTY(DeviceTools* tools READ tools CONSTANT)

public:
  // A device tab's id, and the host and device of one ({} when not a device tab).
  static QString tabIdOf(const QString& hostId, const QString& deviceId);
  static std::pair<QString, QString> targetOf(const QString& tabId);

  explicit ThreadDevices(McClient* client, QObject* parent = nullptr);
  ~ThreadDevices() override;

  // The thread shown, and the MC whose events carry its environment's
  // devices (empty when none does).
  void setThread(const QString& environmentId, const QString& threadId, const QString& mc);
  // The panel's active tab while it shows a Device tab (`device` or a
  // device tab), else empty: a device tab streams only while shown.
  void setTab(const QString& tabId);

  QVariantMap view() const { return m_view; }
  DeviceStream* stream() { return &m_stream; }
  DeviceTools* tools() { return &m_tools; }
  // A device tab's title: its device's name, else "Device".
  QString titleOf(const QString& tabId) const;

  // Opens a listed device for the thread.
  Q_INVOKABLE void open(const QString& hostId, const QString& deviceId);
  // Shuts the shown tab's device down and closes the tab.
  Q_INVOKABLE void powerOff();
  // Closes the shown device tab; the device stays open for the thread.
  Q_INVOKABLE void close();
  Q_INVOKABLE void refresh();
  Q_INVOKABLE void dismissError();
  // Retry one machine whose tools failed (`device.list` with its host id).
  Q_INVOKABLE void retryHost(const QString& hostId);
  // Float the shown device over the chat; the panel closes (floated()).
  Q_INVOKABLE void floatDevice();
  // The setup wizard's switches and buttons (`device.configure`, `device.list`).
  Q_INVOKABLE void wizardSetHub(bool on);
  Q_INVOKABLE void wizardSetAgent(bool on);
  Q_INVOKABLE void wizardCheck();
  Q_INVOKABLE void wizardDone();
  Q_INVOKABLE void wizardCancel();

signals:
  void viewChanged();
  // The panel shows `tabId` (replacing the picker); `automatic`: an agent
  // opened it, and a tab the user closed stays closed.
  void opened(const QString& tabId, bool automatic);
  // `threadKey` (`<environment>:<thread>`) closes `tabId`: the thread it was
  // asked in, which may no longer be the one shown.
  void closed(const QString& threadKey, const QString& tabId);
  // A device's name became known or changed: tab titles follow.
  void namesChanged();
  // The panel floats `tabId`'s device over the chat and closes.
  void floated(const QString& tabId);

private:
  void follow();
  void unfollow();
  void take(const QJsonObject& state);
  void list(const QJsonObject& input = {});
  QJsonObject deviceOf(const QString& hostId, const QString& deviceId) const;
  bool hasSession(const QString& hostId, const QString& deviceId) const;
  void watchSessions();
  void retarget();
  void publish();

  void configure(const QString& pending, const QJsonObject& change);
  QVariantMap wizardView() const;
  QVariantList banners() const;

  McClient* m_client;
  DeviceStream m_stream;
  DeviceTools m_tools;
  QString m_environment;
  QString m_thread;
  QString m_mc;
  QString m_tab;
  int m_subscription = -1;
  // Replies for another environment are dropped.
  int m_generation = 0;
  bool m_loaded = false;
  QJsonObject m_state;
  QString m_names;
  // The key ("<host>\0<device>") of the device being opened, and its name.
  QString m_pending;
  QString m_error;
  // The host being retried, while its answer is out.
  QString m_retrying;
  // The wizard's request in flight ("hub", "check", "agent", "complete"),
  // and whether the user put it away for this showing of the tab.
  QString m_wizardPending;
  bool m_wizardDismissed = false;
  // Each thread's sessions (with a known device) as last seen: a session
  // missing there is new. Absent until the first state, the baseline.
  QHash<QString, QSet<QString>> m_sessionsSeen;
  QVariantMap m_view;
};
