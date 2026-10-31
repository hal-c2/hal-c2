// A capture ended from inside its own socket's or timer's signal.

#include <QtTest>

#ifdef HAL_C2_HAS_DBUS
#include "NiriSnapShot.h"
#endif

class NiriSnapShotRegression : public QObject {
  Q_OBJECT

private slots:
  // A stale $NIRI_SOCKET fails inside connectToServer, which used to return
  // into the socket the failure had just deleted.
  void aMissingSocketFailsTheCapture() {
#ifdef HAL_C2_HAS_DBUS
    NiriSnapShot backend({false, QStringLiteral("niri"), {}}, QStringLiteral("/nonexistent/hal-c2-niri.sock"));
    QSignalSpy failed(&backend, &SnapShotBackend::failed);
    backend.capture();
    QTRY_COMPARE(failed.size(), 1);
    QCoreApplication::sendPostedEvents();
    QCoreApplication::processEvents();
    // The capture is over: another may start.
    backend.capture();
    QTRY_COMPARE(failed.size(), 2);
#else
    QSKIP("Niri needs D-Bus");
#endif
  }
};

QTEST_GUILESS_MAIN(NiriSnapShotRegression)
#include "tst_NiriSnapShotRegression.moc"
