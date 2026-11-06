#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QPair>
#include <QString>

// This machine's cluster as apps/server-ex lib/hal_c2/rpc.ex answers
// `cluster.*` (ClusterSteps fakes it): the other members, whether the MC
// listens only on loopback, and why it refuses to read the cluster or join
// (when it does). Reads are held while the MC holds `cluster.status`. A
// member switched off is kept, with the MC that served it.
struct FakeCluster {
  QJsonArray members;
  bool loopbackOnly = false;
  QString statusRefusal;
  QString joinRefusal;
  // The version this machine runs, and why a member cannot take it, by label.
  QString version;
  QHash<QString, QString> updateRefusals;
  QList<QPair<QString, QJsonObject>> calls;
  // The MC of each member switched off, by environment.
  QHash<QString, QString> switchedOff;
};
