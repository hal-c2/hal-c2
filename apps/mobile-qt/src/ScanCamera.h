#pragma once

#include <functional>
#include <memory>

class QObject;
class QVideoSink;

// The device's camera as the scanner (Scanner.h) uses it: whether the app
// may use it, asking for that, frames into a sink while it runs, and word of
// it when it does not. The scenarios put one of their own here, which is how
// they hand the scanner a picture as a camera frame.
class ScanCamera {
public:
  enum class Access { Undetermined, Granted, Denied };
  // Why a camera that was started gives no frames.
  enum class Failure {
    NoCamera,  // the device has none
    Stopped,   // it did not start, or stopped by itself: another app has it, it was unplugged
  };

  virtual ~ScanCamera() = default;

  virtual Access access() = 0;
  // Asks the user, where the system still does: one that has been told no
  // for good answers Denied at once. `answered` is called once, unless
  // `context` goes first.
  virtual void requestAccess(QObject* context, std::function<void(Access)> answered) = 0;
  // Frames go to `sink` from now until stop(). A camera says only later
  // whether it started, and may stop by itself at any time after: `failed` is
  // called then, once, on a later turn of the event loop than this call, and
  // never after stop() or once `context` is gone. A camera that failed is
  // still held until stop().
  virtual void start(QVideoSink* sink, QObject* context, std::function<void(Failure)> failed) = 0;
  // Lets go of the camera; nothing when it was not started.
  virtual void stop() = 0;
  // The app's page in the system's settings, where access is given back.
  virtual void openSettings() = 0;
};

// This device's camera, through Qt Multimedia and Qt's permissions: the one
// on its back when it has one.
std::shared_ptr<ScanCamera> deviceCamera();
