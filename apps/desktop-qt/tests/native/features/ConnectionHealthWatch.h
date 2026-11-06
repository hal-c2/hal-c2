#pragma once

#include <QList>

class World;

// What a connection scenario watches of the desktop's client, from the first
// call on (the Background's paired client): every retry's delay, every check's
// outcome, and how many sockets the MC had taken before the step acting. The
// phone's twin is apps/mobile-qt/tests/features/ConnectionWatch.h; the steps
// both surfaces share (ConnectionClientSteps.h) use whichever is built.
struct ConnectionWatch {
  QList<int> retryDelays;
  QList<bool> checks;
  qsizetype connectionsBefore = 0;
  // The client's own foreground check timeout, before a step shortens it.
  int probeTimeout = 0;
  bool hooked = false;
};

ConnectionWatch& watch(World& world);
