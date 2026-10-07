#include "ScanCamera.h"

#include <QCamera>
#include <QCameraDevice>
#include <QCameraFormat>
#include <QGuiApplication>
#include <QMediaCaptureSession>
#include <QMediaDevices>
#include <QPermissions>
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

  bool start(QVideoSink* sink) override {
    stop();
    const QCameraDevice device = cameraToScanWith();
    if (device.isNull()) return false;
    // Made when first wanted: the session loads Qt Multimedia's backend.
    m_session = std::make_unique<QMediaCaptureSession>();
    m_camera = std::make_unique<QCamera>(device);
    QObject::connect(m_camera.get(), &QCamera::errorOccurred, m_camera.get(), [](QCamera::Error, const QString& said) {
      qWarning("[scanner] camera: %s", qPrintable(said));
    });
    const QCameraFormat format = formatToScanWith(device);
    if (!format.isNull()) m_camera->setCameraFormat(format);
    m_session->setCamera(m_camera.get());
    m_session->setVideoSink(sink);
    m_camera->start();
    return true;
  }

  void stop() override {
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
};

}  // namespace

std::shared_ptr<ScanCamera> deviceCamera() {
  return std::make_shared<DeviceCamera>();
}
