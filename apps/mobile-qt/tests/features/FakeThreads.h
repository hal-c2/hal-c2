#pragma once
// The MC's side of a thread on the phone's screen (ComposerSteps.cpp serves
// it): the thread's `stream` shape, entity by entity, and the models its
// `config` offers. The frames are the ones apps/server-ex sends, as the
// desktop harness's Stream.h and SettingsSteps.cpp fake them for its World.

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QMap>
#include <QSet>
#include <QString>

class FakeMc;
class World;

struct FakeStreams {
  struct Change {
    int seq = 0;
    QString kind;
    QString id;
    QJsonObject patch;
  };
  // The entities of each thread, by "kind\nid", and the log of the changes
  // to it, which a follower's offset counts.
  QHash<QString, QMap<QString, QJsonObject>> threads;
  QHash<QString, QList<Change>> log;
  int seq = 0;
  int ordinal = 0;
  // Names the MC's log: a `sub` that comes back with it and an offset is sent
  // the changes since. Empty, the MC offers none, and every `sub` is sent the
  // thread whole.
  QString handle;
  // Every `sub` to a stream as it was answered: its frame, how many frames
  // had been sent before it, and how many changes were made to the thread
  // while nobody followed it.
  struct Asked {
    QString thread;
    QJsonObject sub;
    qsizetype sent = 0;
    int lacked = 0;
  };
  QList<Asked> asked;
  QHash<QString, int> unfollowed;
  // Every frame sent to a follower of a stream, in order.
  QList<QJsonObject> sent;
  // The next catch-up is sent in two parts, and the connection drops after
  // the first.
  bool cutCatchUp = false;
  // Environments that are down (a cluster member that left): a stream on one
  // is refused.
  QSet<QString> offline;
};

// Sets fields of an entity of the thread's stream and tells whoever follows it.
void setEntity(FakeMc& mc, const QString& thread, const QString& kind, const QString& id, const QJsonObject& fields);
// One change to an entity of the thread's stream, as an `events` frame
// carries it ({"s": set, "a": append}). A `quiet` one changes only the MC's
// copy, as if its frame were lost.
void changeEntity(FakeMc& mc, const QString& thread, const QString& kind, const QString& id, const QJsonObject& patch, bool quiet = false);
// Changes the thread's row in the shell and sends it.
void updateRow(FakeMc& mc, const QString& thread, const QJsonObject& fields);
// The providers the MC's config lists.
void offerProviders(FakeMc& mc, const QJsonArray& providers);
// Another environment's settings document (a cluster member's), created on
// first use: its `config` shape and hal-c2.readSettings / writeSettings serve
// it, refusing a write over a stale version as the MC does.
struct SettingsDocument {
  QJsonObject settings;
  int version = 0;
  QJsonObject capabilities;  // what its `config` says the environment can do
};
SettingsDocument& settingsOf(FakeMc& mc, const QString& environment);
// The MC's own settings document; its `config` carries the MC's capabilities.
QJsonObject ownSettings(FakeMc& mc);
// A setting the MC's own document takes, as another client saves it, announced
// as `config.settings`.
void saveOwnSetting(FakeMc& mc, const QString& key, const QJsonValue& value);
