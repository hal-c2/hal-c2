#pragma once
// What another steps file needs from PreviewSteps.cpp: the fake MC's browser
// tabs and the thread's Previews.

#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QString>

#include "FakeMc.h"

class ThreadPreviews;
class World;

// The MC's browser tabs of the thread, oldest change first, and how it
// answers a close.
struct FakePreviews {
  QString epoch = QStringLiteral("epoch-1");
  qint64 revision = 0;
  QList<QJsonObject> tabs;
  bool refuseClose = false;
  bool holdClose = false;
  bool holdList = false;
  int lists = 0;
  // The web servers listening on the MC's machine (DiscoveredLocalServer).
  QJsonArray servers;
  // Every preview.open and preview.navigate payload.
  QList<QJsonObject> opens;
  QList<QJsonObject> navigations;
  bool looking = false;
  // The port the connected MC forwards a dev server to, and every
  // preview.forward with the environment it was sent to.
  int forwardPort = 0;
  QList<FakeMc::Rpc> forwards;
  // The address in the agent's reply.
  QString link;
};

namespace preview {

// The MC's tab `tab-<n>` of the thread, loaded at `url`.
QJsonObject tabAt(const QString& url, int n);
// A PreviewEvent to every watcher, as preview.ex emit/4.
void emitEvent(FakeMc& mc, const QJsonObject& tab, const QString& type, const QJsonObject& fields = {});
ThreadPreviews& model(World& world);
// The thread's tabs as the Previews tab lists them, for a failed step.
QString describe(World& world);
// Looks at the thread with its Previews tab showing, as mod+shift+j does.
void showPreviews(World& world);
// Looks at the thread on the second MC.
void lookAtPeerThread(World& world);

}  // namespace preview
