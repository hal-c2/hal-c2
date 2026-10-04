#pragma once
// What another steps file needs from LaunchSteps.cpp: every
// `orchestration.launchThread` the fake MC was asked, and of which machine.

#include <QJsonObject>
#include <QList>
#include <QStringList>

struct FakeLaunches {
  QList<QJsonObject> calls;
  // The machine each of `calls` was asked of, by environment id.
  QStringList machines;
};
