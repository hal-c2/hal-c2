// The pairing-code scanner by itself: codes read off pictures as a camera
// delivers them, made with the encoder the desktop draws its codes with, and
// the scanner's use of the camera (Scanner) against one a test scripts.

#include <QEventLoop>
#include <QGuiApplication>
#include <QStandardPaths>
#include <QTest>
#include <QThreadPool>
#include <QTimer>
#include <QVideoSink>
#include <qpa/qwindowsysteminterface.h>

#include <memory>

#include "FakeCamera.h"
#include "QrReader.h"
#include "Scanner.h"
#include "ShellBridge.h"

namespace {

const QString kLink = QStringLiteral("https://devbox.tailnet.ts.net/pair#token=Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MA");

// What the scanner says of a camera that did not start, or stopped.
const QString kCameraStopped =
    QStringLiteral("The camera cannot be used right now. Another app may be using it: close that app and try again, or go back and enter the pairing link.");

void appState(Qt::ApplicationState state) {
  QWindowSystemInterface::handleApplicationStateChanged<QWindowSystemInterface::SynchronousDelivery>(state);
}

// A device at the pairing screen: the scanner, the camera the test scripts,
// the preview's sink, and what the scanner asked the app to pair with.
class Device : public QObject {
  Q_OBJECT

public:
  Device() : camera(std::make_shared<FakeCamera>()), sink(std::make_unique<QVideoSink>()), scanner(&bridge, camera) {
    bridge.addInterceptor([this](const QString& action, const QVariant& payload) {
      if (action != QLatin1String("pairing.pair")) return false;
      paired.append(payload.toMap().value(QStringLiteral("link")).toString());
      emit changed();
      return true;
    });
    connect(&bridge, &ShellBridge::stateEntryChanged, this, &Device::changed);
  }

  QVariantMap state() const { return bridge.state()->value(QStringLiteral("scanner")).toMap(); }
  QString access() const { return state().value(QStringLiteral("access")).toString(); }
  QString message() const { return state().value(QStringLiteral("message")).toString(); }
  bool open() const { return state().value(QStringLiteral("open")).toBool(); }
  bool failed() const { return state().value(QStringLiteral("failed")).toBool(); }
  void dispatch(const QString& action, const QVariantMap& payload = {}) { bridge.dispatch(action, payload); }
  // The screen comes up with its preview, as ScanScreen.qml does.
  void showPreview() { dispatch(QStringLiteral("scanner.preview"), {{QStringLiteral("sink"), QVariant::fromValue<QObject*>(sink.get())}}); }
  // Runs the event loop until `met`, asked again whenever the scanner
  // publishes or asks to pair. The timeout only ends a wait that has failed.
  bool waitUntil(const std::function<bool()>& met) {
    QEventLoop loop;
    QTimer failed;
    failed.setSingleShot(true);
    failed.start(10000);
    connect(&failed, &QTimer::timeout, &loop, &QEventLoop::quit);
    const auto watching = connect(this, &Device::changed, &loop, [&] {
      if (met()) loop.quit();
    });
    while (!met() && failed.isActive()) loop.exec();
    disconnect(watching);
    return met();
  }

  ShellBridge bridge;
  std::shared_ptr<FakeCamera> camera;
  std::unique_ptr<QVideoSink> sink;
  QStringList paired;
  Scanner scanner;

signals:
  void changed();
};

}  // namespace

class tst_Scanner : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() { QStandardPaths::setTestModeEnabled(true); }
  void init() { appState(Qt::ApplicationActive); }

  // The round trip: a pairing link, the code the desktop draws for it, a
  // camera's frame of that code, and the link read back.
  void codesAreReadOffCameraFrames_data() {
    QTest::addColumn<QString>("text");
    QTest::addColumn<QSize>("size");
    QTest::addColumn<int>("side");
    QTest::addColumn<qreal>("degrees");
    const QSize wide(1280, 720);
    QTest::newRow("held straight") << kLink << wide << 420 << 0.0;
    QTest::newRow("a quarter turn, as a phone's sensor sits") << kLink << wide << 420 << 90.0;
    QTest::newRow("upside down") << kLink << wide << 420 << 180.0;
    QTest::newRow("three quarter turns") << kLink << wide << 420 << 270.0;
    QTest::newRow("tilted") << kLink << wide << 360 << 17.0;
    QTest::newRow("on its corner") << kLink << wide << 360 << 45.0;
    QTest::newRow("small in a large frame") << kLink << QSize(1920, 1080) << 190 << 8.0;
    QTest::newRow("an upright frame") << kLink << QSize(720, 1280) << 300 << 96.0;
    QTest::newRow("a low-resolution camera") << kLink << QSize(640, 480) << 230 << 3.0;
    QTest::newRow("the app's own link") << QStringLiteral("hal-c2://pair?pairingUrl=") + QString::fromUtf8(QUrl::toPercentEncoding(kLink)) << wide << 420 << 12.0;
    QTest::newRow("a link from mix hal_c2.pair") << QStringLiteral("http://127.0.0.1:3797/?token=q8Jm2sT4vX6zB1dF3hK5nP7rW9yC0eG") << wide << 360 << 200.0;
  }
  void codesAreReadOffCameraFrames() {
    QFETCH(QString, text);
    QFETCH(QSize, size);
    QFETCH(int, side);
    QFETCH(qreal, degrees);
    const QVideoFrame frame = camera::nv12(camera::sees(text, size, side, degrees));
    QCOMPARE(frame.pixelFormat(), QVideoFrameFormat::Format_NV12);
    const QImage seen = qr::luminance(frame);
    QCOMPARE(seen.size(), size);
    QCOMPARE(seen.format(), QImage::Format_Grayscale8);
    QCOMPARE(qr::read(seen), QStringList{text});
  }

  // A frame in a format that is not brightness first is converted.
  void aFrameOfAnotherFormatIsRead() {
    const QVideoFrame frame(camera::sees(kLink).convertToFormat(QImage::Format_RGBA8888));
    QVERIFY(frame.pixelFormat() != QVideoFrameFormat::Format_NV12);
    QCOMPARE(qr::read(qr::luminance(frame)), QStringList{kLink});
  }

  void aPictureWithoutACodeReadsNothing() {
    QCOMPARE(qr::read(camera::desk()), QStringList());
    QCOMPARE(qr::read(QImage()), QStringList());
    QVERIFY(qr::luminance(QVideoFrame()).isNull());
  }

  // Scanning asks for camera access the first time.
  void openingAsksForTheCamera() {
    Device device;
    QCOMPARE(device.open(), false);
    device.dispatch(QStringLiteral("scanner.open"));
    device.showPreview();
    QCOMPARE(device.camera->asked, 1);
    QCOMPARE(device.open(), true);
    QCOMPARE(device.access(), QStringLiteral("asking"));
    QVERIFY(!device.camera->running());

    device.camera->reply(ScanCamera::Access::Granted);
    QVERIFY(device.waitUntil([&] { return device.access() == QLatin1String("granted"); }));
    QVERIFY(device.camera->running());

    // Allowed once, it is not asked again.
    device.dispatch(QStringLiteral("scanner.close"));
    device.dispatch(QStringLiteral("scanner.open"));
    QCOMPARE(device.camera->asked, 1);
    QVERIFY(device.camera->running());
  }

  // Denied camera access explains how to recover.
  void deniedAccessOffersTheSystemSettings() {
    Device device;
    device.camera->held = ScanCamera::Access::Denied;
    device.camera->answer = ScanCamera::Access::Denied;
    device.dispatch(QStringLiteral("scanner.open"));
    device.showPreview();
    QVERIFY(device.waitUntil([&] { return device.access() == QLatin1String("denied"); }));
    QVERIFY(!device.camera->running());
    device.dispatch(QStringLiteral("scanner.settings"));
    QCOMPARE(device.camera->settingsOpened, 1);

    // The user allows it there and comes back.
    appState(Qt::ApplicationInactive);
    device.camera->held = ScanCamera::Access::Granted;
    appState(Qt::ApplicationActive);
    QCOMPARE(device.access(), QStringLiteral("granted"));
    QVERIFY(device.camera->running());
  }

  // Scanning a pairing code adds the environment.
  void aPairingCodeIsPairedWith_data() {
    QTest::addColumn<QString>("code");
    QTest::addColumn<QString>("link");
    QTest::newRow("a pairing link") << kLink << kLink;
    QTest::newRow("the app's link to one") << QStringLiteral("hal-c2://pair?pairingUrl=") + QString::fromUtf8(QUrl::toPercentEncoding(kLink)) << kLink;
  }
  void aPairingCodeIsPairedWith() {
    QFETCH(QString, code);
    QFETCH(QString, link);
    Device device;
    device.camera->held = ScanCamera::Access::Granted;
    device.dispatch(QStringLiteral("scanner.open"));
    device.showPreview();
    QVERIFY(device.camera->running());
    device.camera->show(camera::sees(code, QSize(1280, 720), 300, 33));
    QVERIFY(device.waitUntil([&] { return !device.paired.isEmpty(); }));
    QCOMPARE(device.paired, QStringList{link});
    // And the camera is off.
    QCOMPARE(device.open(), false);
    QVERIFY(!device.camera->running());
  }

  // A code that is not a pairing code is rejected.
  void anotherCodeIsRefusedAndTheCameraKeepsLooking_data() {
    QTest::addColumn<QString>("code");
    QTest::newRow("a web page") << QStringLiteral("https://example.com/menu");
    QTest::newRow("words") << QStringLiteral("WIFI:T:WPA;S:cafe;P:espresso;;");
    QTest::newRow("an address with no scheme") << QStringLiteral("devbox.tailnet.ts.net/pair#token=abc");
    QTest::newRow("an app link that carries a script") << QStringLiteral("hal-c2://pair?pairingUrl=javascript%3Aalert(1)%23token%3Dabc");
  }
  void anotherCodeIsRefusedAndTheCameraKeepsLooking() {
    QFETCH(QString, code);
    Device device;
    device.camera->held = ScanCamera::Access::Granted;
    device.dispatch(QStringLiteral("scanner.open"));
    device.showPreview();
    device.camera->show(camera::sees(code));
    QVERIFY(device.waitUntil([&] { return !device.message().isEmpty(); }));
    QVERIFY2(device.message().startsWith(QStringLiteral("That is not a HAL-C2 pairing code.")), qPrintable(device.message()));
    QCOMPARE(device.paired, QStringList());
    QCOMPARE(device.open(), true);
    QVERIFY(device.camera->running());

    // The right code after it is taken.
    device.camera->show(camera::sees(kLink));
    QVERIFY(device.waitUntil([&] { return !device.paired.isEmpty(); }));
    QCOMPARE(device.paired, QStringList{kLink});
  }

  // Of two codes in one frame, the pairing code is the one taken.
  void thePairingCodeAmongOthersIsTaken() {
    Device device;
    device.camera->held = ScanCamera::Access::Granted;
    device.dispatch(QStringLiteral("scanner.open"));
    device.showPreview();
    QImage both = camera::sees(kLink, QSize(1280, 720), 300);
    QPainter painter(&both);
    painter.drawImage(QRect(60, 200, 300, 300), qr::image(qr::encode(QStringLiteral("https://example.com/menu")), 8));
    painter.end();
    device.camera->show(both);
    QVERIFY(device.waitUntil([&] { return !device.paired.isEmpty(); }));
    QCOMPARE(device.paired, QStringList{kLink});
  }

  // The camera never runs with the scanner closed, the app behind another,
  // or nothing to show its picture.
  void theCameraRunsOnlyWhileTheScannerShows() {
    Device device;
    device.camera->held = ScanCamera::Access::Granted;
    device.dispatch(QStringLiteral("scanner.open"));
    // Open, with no screen yet.
    QVERIFY(!device.camera->running());
    device.showPreview();
    QVERIFY(device.camera->running());

    appState(Qt::ApplicationInactive);
    QVERIFY(!device.camera->running());
    appState(Qt::ApplicationActive);
    QVERIFY(device.camera->running());
    appState(Qt::ApplicationSuspended);
    QVERIFY(!device.camera->running());
    appState(Qt::ApplicationActive);
    QVERIFY(device.camera->running());

    device.dispatch(QStringLiteral("scanner.close"));
    QVERIFY(!device.camera->running());
    // Coming back to the front does not start a closed scanner's camera.
    appState(Qt::ApplicationInactive);
    appState(Qt::ApplicationActive);
    QVERIFY(!device.camera->running());

    device.dispatch(QStringLiteral("scanner.open"));
    QVERIFY(device.camera->running());
    // The screen goes without the scanner being closed.
    device.sink.reset();
    QVERIFY(!device.camera->running());
    QCOMPARE(device.camera->starts, 4);
  }

  // A frame that was being read when the scanner closed pairs with nothing.
  void aFrameReadAfterClosingIsDropped() {
    Device device;
    device.camera->held = ScanCamera::Access::Granted;
    device.dispatch(QStringLiteral("scanner.open"));
    device.showPreview();
    device.camera->show(camera::sees(kLink));
    device.dispatch(QStringLiteral("scanner.close"));
    // The reading ends, and what it found is handed over.
    QVERIFY(QThreadPool::globalInstance()->waitForDone(10000));
    QCoreApplication::processEvents();
    QCOMPARE(device.paired, QStringList());
  }

  // A camera says only later that it did not start: the scanner then lets
  // go of it and says so, in the place of a preview with nothing in it.
  // A code read off a frame of the scanner's last showing is not taken by the
  // next one: the user closed it, and opened it again for another code.
  void aFrameReadForAnEarlierShowingIsDropped() {
    Device device;
    device.camera->held = ScanCamera::Access::Granted;
    device.dispatch(QStringLiteral("scanner.open"));
    device.showPreview();
    device.camera->show(camera::sees(kLink));
    // Closed and opened again before that frame is read.
    device.dispatch(QStringLiteral("scanner.close"));
    device.dispatch(QStringLiteral("scanner.open"));
    device.showPreview();
    QVERIFY(device.camera->running());
    QVERIFY(QThreadPool::globalInstance()->waitForDone(10000));
    QCoreApplication::processEvents();
    QCOMPARE(device.paired, QStringList());
    QCOMPARE(device.open(), true);
    QVERIFY(device.camera->running());
  }

  void aCameraThatDoesNotStartSaysSo() {
    Device device;
    device.camera->held = ScanCamera::Access::Granted;
    device.camera->fault = ScanCamera::Failure::Stopped;
    device.dispatch(QStringLiteral("scanner.open"));
    device.showPreview();
    // The camera has been started, and has yet to say how that went.
    QVERIFY(device.camera->inUse());
    QCOMPARE(device.failed(), false);
    QVERIFY(device.waitUntil([&] { return device.failed(); }));
    QCOMPARE(device.message(), kCameraStopped);
    QCOMPARE(device.open(), true);
    QVERIFY(!device.camera->inUse());
    QCOMPARE(device.camera->attempts, 1);
    // Not tried over and over.
    appState(Qt::ApplicationInactive);
    appState(Qt::ApplicationActive);
    QCOMPARE(device.camera->attempts, 1);

    // The user's own try is one, and says the same of a camera that still does not start.
    device.dispatch(QStringLiteral("scanner.retry"));
    QCOMPARE(device.camera->attempts, 2);
    QCOMPARE(device.failed(), false);
    QCOMPARE(device.message(), QString());
    QVERIFY(device.waitUntil([&] { return device.failed(); }));
    QCOMPARE(device.message(), kCameraStopped);
    QVERIFY(!device.camera->inUse());

    // The other app lets go of it: the next try scans.
    device.camera->fault.reset();
    device.dispatch(QStringLiteral("scanner.retry"));
    QVERIFY(device.camera->running());
    QCOMPARE(device.failed(), false);
    QCOMPARE(device.message(), QString());
    device.camera->show(camera::sees(kLink));
    QVERIFY(device.waitUntil([&] { return !device.paired.isEmpty(); }));
    QCOMPARE(device.paired, QStringList{kLink});
  }

  // Leaving the scanner and opening it again is a try as well.
  void reopeningTriesACameraThatFailedAgain() {
    Device device;
    device.camera->held = ScanCamera::Access::Granted;
    device.camera->fault = ScanCamera::Failure::Stopped;
    device.dispatch(QStringLiteral("scanner.open"));
    device.showPreview();
    QVERIFY(device.waitUntil([&] { return device.failed(); }));
    device.dispatch(QStringLiteral("scanner.close"));
    QCOMPARE(device.failed(), false);
    QCOMPARE(device.message(), QString());
    // Nothing to try again with the scanner closed.
    device.dispatch(QStringLiteral("scanner.retry"));
    QCOMPARE(device.camera->attempts, 1);

    device.camera->fault.reset();
    device.dispatch(QStringLiteral("scanner.open"));
    QVERIFY(device.camera->running());
    QCOMPARE(device.failed(), false);
  }

  // A camera that stops while it scans (another app takes it, it is
  // unplugged) is let go of and said to have stopped.
  void aCameraThatStopsWhileScanningSaysSo() {
    Device device;
    device.camera->held = ScanCamera::Access::Granted;
    device.dispatch(QStringLiteral("scanner.open"));
    device.showPreview();
    QVERIFY(device.camera->running());
    // A frame of a pairing code is being read as it stops.
    device.camera->show(camera::sees(kLink));
    device.camera->fail();
    QCOMPARE(device.failed(), true);
    QCOMPARE(device.message(), kCameraStopped);
    QCOMPARE(device.open(), true);
    QVERIFY(!device.camera->inUse());
    // What that frame held pairs with nothing: the user is reading why the camera stopped.
    QVERIFY(QThreadPool::globalInstance()->waitForDone(10000));
    QCoreApplication::processEvents();
    QCOMPARE(device.paired, QStringList());
    QCOMPARE(device.failed(), true);

    device.dispatch(QStringLiteral("scanner.retry"));
    QVERIFY(device.camera->running());
    QCOMPARE(device.failed(), false);
    QCOMPARE(device.message(), QString());
    QCOMPARE(device.camera->starts, 2);
  }

  // A failure on its way when the scanner closed is not said of the next camera.
  void aFailureFromBeforeClosingIsDropped() {
    Device device;
    device.camera->held = ScanCamera::Access::Granted;
    device.camera->fault = ScanCamera::Failure::Stopped;
    device.dispatch(QStringLiteral("scanner.open"));
    device.showPreview();
    device.dispatch(QStringLiteral("scanner.close"));
    device.camera->fault.reset();
    device.dispatch(QStringLiteral("scanner.open"));
    QVERIFY(device.camera->running());
    QCoreApplication::processEvents();
    QCOMPARE(device.failed(), false);
    QVERIFY(device.camera->running());
  }

  // A device with no camera says that, and not that one failed.
  void aDeviceWithNoCameraSaysSo() {
    Device device;
    device.camera->held = ScanCamera::Access::Granted;
    device.camera->fault = ScanCamera::Failure::NoCamera;
    device.dispatch(QStringLiteral("scanner.open"));
    device.showPreview();
    QVERIFY(device.waitUntil([&] { return device.failed(); }));
    QCOMPARE(device.message(), QStringLiteral("This device has no camera. Go back and enter the pairing link instead."));
    QVERIFY(!device.camera->inUse());
    QCOMPARE(device.camera->attempts, 1);
  }
};

int main(int argc, char** argv) {
  QGuiApplication app(argc, argv);
  tst_Scanner test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_Scanner.moc"
