#pragma once
// The MC's side of a thread on the phone's screen (ComposerSteps.cpp serves
// it): the thread's `stream` shape, entity by entity, and the models its
// `config` offers. The frames are the ones apps/server-ex sends, as the
// desktop harness's Stream.h and SettingsSteps.cpp fake them for its World.

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QMap>
#include <QString>

class FakeMc;
class World;

struct FakeStreams {
  // The entities of each thread, by "kind\nid".
  QHash<QString, QMap<QString, QJsonObject>> threads;
  int seq = 0;
  int ordinal = 0;
};

// Sets fields of an entity of the thread's stream and tells whoever follows it.
void setEntity(FakeMc& mc, const QString& thread, const QString& kind, const QString& id, const QJsonObject& fields);
// Changes the thread's row in the shell and sends it.
void updateRow(FakeMc& mc, const QString& thread, const QJsonObject& fields);
// The providers the MC's config lists.
void offerProviders(FakeMc& mc, const QJsonArray& providers);
