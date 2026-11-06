// The phone's watch on its client (ConnectionWatch.h). Its twin is defined in
// connection-health/mobile's ConnectionHealthSteps.cpp: keep that one and drop
// this file when the branches meet.

#include "ConnectionWatch.h"

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "World.h"

ConnectionWatch& watch(World& world) {
  ConnectionWatch& watched = world.mc.part<ConnectionWatch>();
  McClient* client = world.native().client();
  if (watched.watched == client) return watched;
  watched.watched = client;
  QObject::connect(client, &McClient::phaseChanged, client, [client, &watched] {
    if (client->phase() == McClient::Phase::Retrying) watched.retryDelays.append(client->retryDelay());
  });
  QObject::connect(client, &McClient::checked, client, [&watched](bool alive) { watched.checks.append(alive); });
  return watched;
}
