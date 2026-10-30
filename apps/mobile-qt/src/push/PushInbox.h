#pragma once

#include <QByteArray>
#include <QJsonObject>
#include <QList>
#include <QString>

#include <utility>

#include "PushCrypto.h"

// What the phone does with an MC's push (the contract is the MC's
// HalC2.Push): open it, drop it when it is stale, from the future, already
// shown or not allowed, and say what the system's notifications should
// become. It is Qt Core and OpenSSL alone, with no app object, because on
// Android the push receiver calls it while the app may not be running
// (android/src/.../PushReceiver.java, through PushJni.cpp); the app and that
// receiver share its file, <data>/push.json, under one lock.
//
// Every call answers with effects, which the platform renders as they are:
//   {channels: [{id, name, importance}],
//    alert?: {tag, id, channel, title, body, link, visibility, publicTitle, publicText},
//    card?: {id, channel, title, text, lines, subtext, chip, action, dismissAction,
//            ongoing, promoted, link, timeoutMs, silent, showWhen, visibility,
//            publicTitle, publicText},
//    cancelCard?: true}
namespace push {

// What the phone is like as a message arrives.
struct Device {
  // Wall clock, ms since the epoch.
  qint64 now = 0;
  // The app is on screen: its own views show what an alert would.
  bool foreground = false;
  // The system lets HAL-C2 post notifications.
  bool permitted = false;
  // Android's API level; 0 off Android.
  int sdk = 0;
};

// Whether the app is on screen, for a receiver in the same process.
void setForeground(bool foreground);
bool foreground();

constexpr int kCardId = 73001;
constexpr const char* kAlertChannel = "agent-alerts";
constexpr const char* kActivityChannel = "agent-activity";

class Inbox {
public:
  explicit Inbox(const QString& dataDir);

  // This phone's push keys, made the first time they are asked for.
  Keys keys();
  bool liveActivity();
  // Turning live activity off takes the card down; turning it on lets the
  // next one show even if the user had dismissed the last.
  QJsonObject setLiveActivity(bool on);
  // An encrypted message from the distributor.
  QJsonObject receive(const QByteArray& body, const Device& device);
  // A message in the clear: a decrypted one, or the activity the app works
  // out itself from what it shows.
  QJsonObject deliver(const QJsonObject& message, const Device& device);
  // The user swiped the card away, or tapped its dismiss action: it stays
  // away until a run starts again.
  QJsonObject dismiss();
  bool dismissed();
  // The app's own choices kept beside the inbox's: the distributor, the
  // endpoint it gave (which Android's receiver writes) and quiet hours.
  QJsonValue value(const QString& key);
  void setValue(const QString& key, const QJsonValue& value);

private:
  QString m_path;
};

// One thread of an activity message: its phase as the contract names it
// (starting, running, waiting_for_approval, waiting_for_input, stale,
// completed, failed) and when it last changed, or finished.
struct ActivityRow {
  QString phase;
  QString title;
  QString project;
  QString environmentId;
  QString threadId;
  qint64 at = 0;
};

// The activity of a message for these threads as of `now`, as the MC builds
// it: those that need the user first, then failed, working and done ones,
// newest first in each, five at most; finished ones only for 15 minutes.
QJsonObject activity(QList<ActivityRow> rows, qint64 now);

// The two notification channels, so they can be silenced apart.
QJsonObject channels();
// The card for an activity, as of `now`.
QJsonObject card(const QJsonObject& activity, qint64 remainingMs, int sdk);
// `hal-c2://threads/<environment>/<thread>` for a message's alert or
// activity, from its link when that is one and otherwise from the ids it
// names; empty when it names no thread.
QString threadLink(const QJsonObject& item);
// The environment and thread of a thread link; empty when it is not one.
std::pair<QString, QString> parseThreadLink(const QString& link);

}  // namespace push
