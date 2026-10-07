#pragma once

#include <functional>
#include <memory>

class QObject;
class QVideoSink;

// The device's camera as the scanner (Scanner.h) uses it: whether the app
// may use it, asking for that, and frames into a sink while it runs. The
// scenarios put one of their own here, which is how they hand the scanner a
// picture as a camera frame.
class ScanCamera {
public:
  enum class Access { Undetermined, Granted, Denied };

  virtual ~ScanCamera() = default;

  virtual Access access() = 0;
  // Asks the user, where the system still does: one that has been told no
  // for good answers Denied at once. `answered` is called once, unless
  // `context` goes first.
  virtual void requestAccess(QObject* context, std::function<void(Access)> answered) = 0;
  // Frames go to `sink` from now until stop(). False when no camera started.
  virtual bool start(QVideoSink* sink) = 0;
  virtual void stop() = 0;
  // The app's page in the system's settings, where access is given back.
  virtual void openSettings() = 0;
};

// This device's camera, through Qt Multimedia and Qt's permissions: the one
// on its back when it has one.
std::shared_ptr<ScanCamera> deviceCamera();
