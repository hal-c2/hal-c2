// What tst_ScannerProp found of the scanner, kept as plain cases: a frame read
// off a camera that stopped while it was read pairs with nothing, though the
// camera runs again by the time the reading is done.

#include <QGuiApplication>
#include <QStandardPaths>
#include <QTest>
#include <QThreadPool>
#include <QVideoSink>
#include <qpa/qwindowsysteminterface.h>

#include <memory>

#include "FakeCamera.h"
#include "Scanner.h"
#include "ShellBridge.h"

namespace {

const QString kLink = QStringLiteral("https://devbox.tailnet.ts.net/pair#token=Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MA");

void appState(Qt::ApplicationState state) {
  QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(state);
}

// A device at the pairing screen with its camera running.
struct Device {
  Device() : camera(std::make_shared<FakeCamera>()), sink(std::make_unique<QVideoSink>()) {
    camera->held = ScanCamera::Access::Granted;
    bridge.addInterceptor([this](const QString& action, const QVariant& payload) {
      if (action != QLatin1String("pairing.pair")) return false;
      paired.append(payload.toMap().value(QStringLiteral("link")).toString());
      return true;
    });
    scanner = std::make_unique<Scanner>(&bridge, camera);
    dispatch(QStringLiteral("scanner.open"));
    dispatch(QStringLiteral("scanner.preview"), {{QStringLiteral("sink"), QVariant::fromValue<QObject*>(sink.get())}});
  }
  ~Device() {
    scanner.reset();
    QThreadPool::globalInstance()->waitForDone();
  }

  bool open() const { return bridge.state()->value(QStringLiteral("scanner")).toMap().value(QStringLiteral("open")).toBool(); }
  void dispatch(const QString& action, const QVariantMap& payload = {}) { bridge.dispatch(action, payload); }
  // The reading is done, and what it found handed over.
  void read() {
    QThreadPool::globalInstance()->waitForDone();
    QCoreApplication::sendPostedEvents();
    QCoreApplication::processEvents();
  }

  ShellBridge bridge;
  std::shared_ptr<FakeCamera> camera;
  std::unique_ptr<QVideoSink> sink;
  QStringList paired;
  std::unique_ptr<Scanner> scanner;
};

const QImage& pairingCode() {
  static const QImage picture = camera::sees(kLink, QSize(640, 480), 300, 9);
  return picture;
}

}  // namespace

class tst_ScannerRegression : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() { QStandardPaths::setTestModeEnabled(true); }
  void init() { appState(Qt::ApplicationActive); }
  void cleanup() { appState(Qt::ApplicationActive); }

  // Shrunk: Open, Preview(sink), Answer(granted), Frames(pairing code x1,
  // backgrounded meanwhile).
  void aFrameReadAcrossTheAppGoingBehindPairsWithNothing() {
    Device device;
    QVERIFY(device.camera->running());
    device.camera->show(pairingCode());
    appState(Qt::ApplicationInactive);
    appState(Qt::ApplicationActive);
    QVERIFY(device.camera->running());
    device.read();
    QVERIFY(device.paired.isEmpty());
    QVERIFY(device.open());
  }

  void aFrameReadAcrossTheScannerReopeningPairsWithNothing() {
    Device device;
    device.camera->show(pairingCode());
    device.dispatch(QStringLiteral("scanner.close"));
    device.dispatch(QStringLiteral("scanner.open"));
    QVERIFY(device.camera->running());
    device.read();
    QVERIFY(device.paired.isEmpty());
    QVERIFY(device.open());
  }

  void aFrameReadAcrossACameraFailureAndRetryPairsWithNothing() {
    Device device;
    device.camera->show(pairingCode());
    device.camera->fail();
    device.dispatch(QStringLiteral("scanner.retry"));
    QVERIFY(device.camera->running());
    device.read();
    QVERIFY(device.paired.isEmpty());
    QVERIFY(device.open());
  }

  // What the camera shows once it runs again is paired with.
  void aFrameFromTheNewRunStillPairs() {
    Device device;
    device.camera->show(pairingCode());
    device.dispatch(QStringLiteral("scanner.close"));
    device.dispatch(QStringLiteral("scanner.open"));
    device.read();
    device.camera->show(pairingCode());
    device.read();
    QCOMPARE(device.paired, QStringList{kLink});
    QVERIFY(!device.open());
  }
};

QTEST_MAIN(tst_ScannerRegression)
#include "tst_ScannerRegression.moc"
