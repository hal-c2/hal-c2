#pragma once
// What another steps file needs from LoadBalancingSteps.cpp: the fake MC's
// `hal-c2.placeThread`, and the project it places new threads in.

#include <QList>
#include <QString>

#include "FakeMc.h"

class World;

// What the scenario says of the machines, and what the MC was asked.
struct FakePlacement {
  // The project every machine has a checkout of, by its name.
  QString project;
  // The machine the MC starts a new thread on in place of the user's pick:
  // the one the scenario gives more room, while balancing is on and that
  // machine is up and has a checkout.
  QString elsewhere;
  // The draft is tied to its machine, so the MC is not to be asked.
  bool tied = false;
  // Every `hal-c2.placeThread`, in order.
  QList<FakeMc::Rpc> asked;
};

// The project `name` on every machine of the cluster, as checkouts of one
// repository: the MC's own under the id `name`, each member's under an id of
// its own, so a launch says which checkout it is for.
void shareProject(FakeMc& mc, const QString& name);
// A cluster of `machine` (the MC's own) and another with more room, both
// with a checkout of the project this answers.
QString clusterWithRoomElsewhere(World& world, const QString& machine);
