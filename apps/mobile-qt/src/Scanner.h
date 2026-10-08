#pragma once

#include <QFutureWatcher>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QStringList>
#include <QVariant>
#include <QVariantMap>

#include <memory>

#include "ScanCamera.h"

class QVideoFrame;
class QVideoSink;
class ShellBridge;

// Pairing by pointing the camera at an environment's QR code. The user opens
// it from the pairing screen, so a pairing code it reads is paired with at
// once (`pairing.pair`), unlike a link that came from outside the app. Any
// other code is said not to be one, and the camera keeps looking.
//
// The camera (ScanCamera) runs only while all of these hold: the scanner is
// open, the app may use the camera, the screen has given it a sink to draw
// the preview from (ScanScreen.qml's VideoOutput), and the app is at the
// front. Frames are taken where they arrive, at that sink, one at a time:
// a frame's brightness is copied out as it comes (QrReader's luminance) and
// searched for codes off the thread that draws, and a frame that comes
// while one is being searched is left out.
//
// A camera says only later whether it started, and can stop by itself while
// it runs (ScanCamera's `failed`), and a device may have none. The scanner
// then lets go of the camera and says so (`failed`), in the place of a
// preview with nothing in it, until the user asks it to try again or leaves.
//
// Publishes `scanner`:
//   {open:    the scanner is up,
//    access:  unknown | asking | granted | denied, the app's use of the camera,
//    failed:  the camera gives no picture, and `message` says why,
//    message: a sentence for the user, "" when none}
//
// Actions: `scanner.open`, which asks for the camera when the app does not
// have it, `scanner.close`, `scanner.preview {sink}` from the screen,
// `scanner.settings`, the system's page where a refused camera is allowed,
// and `scanner.retry`, which starts a camera that failed again.
class Scanner : public QObject {
  Q_OBJECT

public:
  Scanner(ShellBridge* bridge, std::shared_ptr<ScanCamera> camera, QObject* parent = nullptr);
  ~Scanner() override;

private:
  bool handle(const QString& action, const QVariant& payload);
  void open();
  void close();
  void preview(QVideoSink* sink);
  void retry();
  // The camera that was started gives no frames, or no more of them.
  void failed(ScanCamera::Failure why);
  // Starts or stops the camera for what holds now, and publishes.
  void update();
  void frame(const QVideoFrame& frame);
  void found(const QStringList& codes);
  void publish();

  ShellBridge* m_bridge;
  std::shared_ptr<ScanCamera> m_camera;
  QPointer<QVideoSink> m_sink;
  QFutureWatcher<QStringList> m_reading;
  ScanCamera::Access m_access = ScanCamera::Access::Undetermined;
  bool m_open = false;
  bool m_asking = false;
  bool m_running = false;
  // Counts the camera's runs: a code read off a frame of an earlier run is
  // not this one's (m_readOf is the run the read in flight began in).
  quint64 m_run = 0;
  quint64 m_readOf = 0;
  // The camera failed: not started again until the user asks, here
  // (`scanner.retry`) or by opening the scanner again.
  bool m_failed = false;
  QString m_message;
  QVariantMap m_published;
};
