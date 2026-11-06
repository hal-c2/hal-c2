#pragma once
// What the phone's connection did, watched from the scenario's first step
// (ConnectionHealthSteps.cpp), for the connection steps of any file to read:
// connection-health.feature's steps are split between files.

#include <QList>
#include <QPointer>

class McClient;
class World;

struct ConnectionWatch {
  // The delay of each retry the client scheduled, in order.
  QList<int> retryDelays;
  // What each foreground check of the connection found: true when it answered.
  QList<bool> checks;
  // The MC's connections when the step that acts on the connection began.
  qsizetype connectionsBefore = 0;
  QPointer<McClient> watched;
};

// The phone's watch on its client, started on first use and moved to a new
// client when the app is opened again.
ConnectionWatch& watch(World& world);
