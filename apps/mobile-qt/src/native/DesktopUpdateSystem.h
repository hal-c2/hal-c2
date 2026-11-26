#pragma once

#include <QString>
#include <QUrl>

#include <functional>
#include <memory>
#include <optional>

#include "DesktopUpdater.h"

// What DesktopUpdateController updates this process with: unset parts are
// the system's (DesktopUpdater::system(), the feed over the network, the
// wall clock, QDesktopServices). main() hands it the MC it runs; tests
// replace the rest before the shell starts.
struct DesktopUpdatePlatform {
  std::optional<DesktopUpdater::Environment> environment;
  std::shared_ptr<DesktopUpdater::Backend> backend;
  std::shared_ptr<DesktopUpdater::Clock> clock;
  // Stops and starts the MC this app runs (BackendProcess).
  std::function<void()> stopMc;
  std::function<void()> startMc;
  // Ends this process once the new version is running.
  std::function<void()> quit;
  // Opens a release's notes; false when the system could not.
  std::function<bool(const QUrl&)> openUrl;
  // Stores the chosen track instead of this device's settings; says why it
  // could not.
  std::function<std::optional<QString>(const QString& channel)> persistTrack;
};

DesktopUpdatePlatform& desktopUpdatePlatform();
std::shared_ptr<DesktopUpdater::Backend> desktopUpdateSystemBackend();
