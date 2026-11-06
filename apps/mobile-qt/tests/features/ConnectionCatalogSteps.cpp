// The phone's build of the saved-environment steps both surfaces share
// (ConnectionCatalogSteps.h): a second environment on a connection of its
// own, a record or credential that has gone, and renewing a credential.

#include "Harness.h"
#include "World.h"

#include "ConnectionCatalogSteps.h"

bool savedEnvironmentBlocked(World &world) {
  return connection_catalog::savedEnvironmentBlocked(world);
}
