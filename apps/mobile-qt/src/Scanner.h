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
// Publishes `scanner`:
//   {open:    the scanner is up,
//    access:  unknown | asking | granted | denied, the app's use of the camera,
//    message: a sentence for the user, "" when none}
//
// Actions: `scanner.open`, which asks for the camera when the app does not
// have it, `scanner.close`, `scanner.preview {sink}` from the screen, and
// `scanner.settings`, the system's page where a refused camera is allowed.
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
  // The camera did not start: not tried again until the scanner is reopened.
  bool m_failed = false;
  QString m_message;
  QVariantMap m_published;
};
