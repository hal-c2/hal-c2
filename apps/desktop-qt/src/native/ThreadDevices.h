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

// The Device tabs of a thread's panel and stage: the
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
//    message}], error, canContinue}}.
//
// Each device tab the thread's panel has is a DeviceTab (`tabs`, by tab id):
// its own stream, tools and view choices, so several devices show at once
// (the panel, the stage's panes, the floating device). A tab streams only
// while it is shown somewhere (setShown) and its device is open for the
// thread; a hidden tab holds no connection and decodes nothing.
class DeviceTab;
class ThreadDevices : public QObject {
  Q_OBJECT
  Q_PROPERTY(QVariantMap view READ view NOTIFY viewChanged)
  // Tab id → DeviceTab, for every device tab the thread's panel has.
  Q_PROPERTY(QVariantMap tabs READ tabsView NOTIFY tabsChanged)

public:
  // A device tab's id, and the host and device of one ({} when not a device tab).
  static QString tabIdOf(const QString& hostId, const QString& deviceId);
  static std::pair<QString, QString> targetOf(const QString& tabId);

  explicit ThreadDevices(McClient* client, QObject* parent = nullptr);
  ~ThreadDevices() override;

  // The thread shown, and the MC whose events carry its environment's
  // devices (empty when none does).
  void setThread(const QString& environmentId, const QString& threadId, const QString& mc);
  // The thread's device tabs: each has a DeviceTab while it is listed.
  void setTabs(const QStringList& tabIds);
  // The Device tabs shown anywhere (`device` and device tabs): a device tab
  // streams only while shown, and showing the picker lists again.
  void setShown(const QStringList& tabIds);

  QVariantMap view() const { return m_view; }
  QVariantMap tabsView() const;
  // The tab's DeviceTab, or null when the panel has no such device tab.
  DeviceTab* tab(const QString& tabId) const { return m_tabs.value(tabId); }
  // A device tab's title: its device's name, else "Device".
  QString titleOf(const QString& tabId) const;

  // Opens a listed device for the thread.
  Q_INVOKABLE void open(const QString& hostId, const QString& deviceId);
  // Shuts the tab's device down and closes the tab.
  Q_INVOKABLE void powerOff(const QString& tabId);
  // Closes the device tab; the device stays open for the thread.
  Q_INVOKABLE void close(const QString& tabId);
  Q_INVOKABLE void refresh();
  Q_INVOKABLE void dismissError();
  // Retry one machine whose tools failed (`device.list` with its host id).
  Q_INVOKABLE void retryHost(const QString& hostId);
  // Float the tab's device over the chat; the panel closes (floated()).
  Q_INVOKABLE void floatDevice(const QString& tabId);
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
  void tabsChanged();

private:
  void follow();
  void unfollow();
  void take(const QJsonObject& state);
  void list(const QJsonObject& input = {});
  QJsonObject deviceOf(const QString& hostId, const QString& deviceId) const;
  bool hasSession(const QString& hostId, const QString& deviceId) const;
  void watchSessions();
  void retarget();
  void retarget(DeviceTab* tab);
  void publish();

  void configure(const QString& pending, const QJsonObject& change);
  QVariantMap wizardView() const;
  QVariantList banners() const;

  McClient* m_client;
  QHash<QString, DeviceTab*> m_tabs;
  QString m_environment;
  QString m_thread;
  QString m_mc;
  QSet<QString> m_shown;
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
  QString m_wizardError;
  bool m_wizardDismissed = false;
  // Each thread's sessions (with a known device) as last seen: a session
  // missing there is new. Absent until the first state, the baseline.
  QHash<QString, QSet<QString>> m_sessionsSeen;
  QVariantMap m_view;
};

// One device tab (ThreadDevices' `tabs`): the device's stream and Tools
// drawer, and the tab's own view choices, which survive the tab moving
// between the panel and the stage. Its body (DevicePanel) binds to it.
class DeviceTab : public QObject {
  Q_OBJECT
  Q_PROPERTY(QString tabId READ tabId CONSTANT)
  // null, or the device while the thread has it open
  // {hostId, id, name, platform, description}: null shows the picker.
  Q_PROPERTY(QVariant screen READ screen NOTIFY screenChanged)
  // Shown somewhere: the panel, a stage pane or floating.
  Q_PROPERTY(bool shown READ shown NOTIFY screenChanged)
  Q_PROPERTY(DeviceStream* stream READ stream CONSTANT)
  Q_PROPERTY(DeviceTools* tools READ tools CONSTANT)
  // The 3D body view, and an iPad's Magic Keyboard.
  Q_PROPERTY(bool show3d READ show3d WRITE setShow3d NOTIFY choicesChanged)
  Q_PROPERTY(bool keyboardAttached READ keyboardAttached WRITE setKeyboardAttached NOTIFY choicesChanged)

public:
  DeviceTab(McClient* client, const QString& tabId, QObject* parent = nullptr);

  QString tabId() const { return m_tabId; }
  QVariant screen() const { return m_screen; }
  bool shown() const { return m_shown; }
  DeviceStream* stream() { return &m_stream; }
  DeviceTools* tools() { return &m_tools; }
  bool show3d() const { return m_show3d; }
  void setShow3d(bool on);
  bool keyboardAttached() const { return m_keyboardAttached; }
  void setKeyboardAttached(bool on);
  // A Magic Keyboard is a landscape thing: attaching one this way turns a portrait iPad.
  Q_INVOKABLE void toggleKeyboard();

signals:
  void screenChanged();
  void choicesChanged();

private:
  friend class ThreadDevices;
  void setScreen(const QVariant& screen, bool shown);

  QString m_tabId;
  DeviceStream m_stream;
  DeviceTools m_tools;
  QVariant m_screen;
  bool m_shown = false;
  bool m_show3d = false;
  bool m_keyboardAttached = false;
};
