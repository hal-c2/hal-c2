#include "ScanCamera.h"

#include <QCamera>
#include <QCameraDevice>
#include <QCameraFormat>
#include <QGuiApplication>
#include <QMediaCaptureSession>
#include <QMediaDevices>
#include <QPermissions>
#include <QPointer>
#include <QVideoSink>
#include <QtLogging>

#ifdef Q_OS_ANDROID
#include <QJniEnvironment>
#include <QJniObject>
#endif

namespace {

ScanCamera::Access accessFor(Qt::PermissionStatus status) {
  switch (status) {
    case Qt::PermissionStatus::Granted:
      return ScanCamera::Access::Granted;
    case Qt::PermissionStatus::Denied:
      return ScanCamera::Access::Denied;
    case Qt::PermissionStatus::Undetermined:
      break;
  }
  return ScanCamera::Access::Undetermined;
}

// Only for an app that may use the camera: Qt's backend over Android's
// camera opens each one to list its formats, and keeps the list it made, so
// one made before the user allowed the camera has no formats for good.
QCameraDevice cameraToScanWith() {
  const QList<QCameraDevice> cameras = QMediaDevices::videoInputs();
  for (const QCameraDevice& camera : cameras) {
    if (camera.position() == QCameraDevice::BackFace) return camera;
  }
  return QMediaDevices::defaultVideoInput();
}

// A code on a screen at arm's length reads well from 720 lines, and every
// line more is time spent on each frame: the smallest format with that many,
// or the camera's own choice when it lists none.
QCameraFormat formatToScanWith(const QCameraDevice& camera) {
  QCameraFormat chosen;
  const QList<QCameraFormat> formats = camera.videoFormats();
  for (const QCameraFormat& format : formats) {
    const QSize size = format.resolution();
    if (qMin(size.width(), size.height()) < 720) continue;
    if (chosen.isNull() || size.width() * size.height() < chosen.resolution().width() * chosen.resolution().height()) chosen = format;
  }
  return chosen;
}

class DeviceCamera : public ScanCamera {
public:
  Access access() override { return accessFor(qApp->checkPermission(QCameraPermission{})); }

  void requestAccess(QObject* context, std::function<void(Access)> answered) override {
    qApp->requestPermission(QCameraPermission{}, context, [answered = std::move(answered)](const QPermission& permission) {
      answered(accessFor(permission.status()));
    });
  }

  void start(QVideoSink* sink, QObject* context, std::function<void(Failure)> failed) override {
    stop();
    // Passed on through the event loop, and dropped when the camera was
    // stopped or started again meanwhile. Qt's backend over Android's camera
    // reports one it cannot open before QCamera::start() has returned, and
    // whoever is told stops the camera, which is not to be done from inside
    // its own signal.
    const auto fail = [this, run = m_run, context = QPointer<QObject>(context), failed = std::move(failed)](Failure why) {
      if (!context) return;
      QMetaObject::invokeMethod(
          context,
          [this, run, why, failed] {
            if (run != m_run) return;
            ++m_run;
            failed(why);
          },
          Qt::QueuedConnection);
    };
    const QCameraDevice device = cameraToScanWith();
    if (device.isNull()) return fail(Failure::NoCamera);
    // Made when first wanted: the session loads Qt Multimedia's backend.
    m_session = std::make_unique<QMediaCaptureSession>();
    m_camera = std::make_unique<QCamera>(device);
    // QCamera::start() returns nothing and isActive() holds for a camera
    // that could not be opened: this signal is all that tells of one.
    QObject::connect(m_camera.get(), &QCamera::errorOccurred, m_camera.get(), [fail](QCamera::Error error, const QString& said) {
      if (error == QCamera::NoError) return;
      qWarning("[scanner] camera: %s", qPrintable(said));
      fail(Failure::Stopped);
    });
    const QCameraFormat format = formatToScanWith(device);
    if (!format.isNull()) m_camera->setCameraFormat(format);
    m_session->setCamera(m_camera.get());
    m_session->setVideoSink(sink);
    m_camera->start();
  }

  void stop() override {
    ++m_run;
    if (!m_camera) return;
    m_camera->stop();
    m_session.reset();
    m_camera.reset();
  }

  void openSettings() override {
#ifdef Q_OS_ANDROID
    const QJniObject context = QNativeInterface::QAndroidApplication::context();
    const QJniObject package = context.callObjectMethod("getPackageName", "()Ljava/lang/String;");
    const QJniObject page = QJniObject::callStaticObjectMethod(
        "android/net/Uri", "parse", "(Ljava/lang/String;)Landroid/net/Uri;",
        QJniObject::fromString(QStringLiteral("package:") + package.toString()).object<jstring>());
    const QJniObject intent("android/content/Intent", "(Ljava/lang/String;Landroid/net/Uri;)V",
                            QJniObject::fromString(QStringLiteral("android.settings.APPLICATION_DETAILS_SETTINGS")).object<jstring>(), page.object());
    context.callMethod<void>("startActivity", "(Landroid/content/Intent;)V", intent.object());
    QJniEnvironment().checkAndClearExceptions();
#endif
  }

private:
  std::unique_ptr<QMediaCaptureSession> m_session;
  std::unique_ptr<QCamera> m_camera;
  // Moves on with each stop and each failure told: a failure from before
  // either is nobody's.
  quint64 m_run = 0;
};

}  // namespace

std::shared_ptr<ScanCamera> deviceCamera() {
  return std::make_shared<DeviceCamera>();
}
