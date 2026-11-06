#pragma once

#include <QString>

// The reason the user is to be told with a failure ("the user is told \"…\"
// with the reason", DesktopUpdateSteps), for steps whose fake is not the
// desktop updater's: kept as the FakeMc part `world.mc.part<ToldReason>()`.
struct ToldReason {
  QString reason;
};
