#include <QFile>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>

#include "BackendProcess.h"

class BackendProcessTest : public QObject {
  Q_OBJECT

  QTemporaryDir directory;

  BackendProcess::Options host(const QByteArray& script) {
    QFile entry(directory.filePath("host.sh"));
    entry.open(QIODevice::WriteOnly | QIODevice::Truncate);
    entry.write(script);
    entry.close();
    return {QStringLiteral("/bin/sh"), entry.fileName(), {}};
  }

private slots:
  void initTestCase() {
#ifdef Q_OS_WIN
    QSKIP("The fake host is a POSIX shell script.");
#endif
    QVERIFY(directory.isValid());
  }

  // The window shows the last failure it hears of; the host's own reason
  // (e.g. "Cannot reach the node at ...") must not be replaced by the exit
  // that follows it.
  void aHostThatReportsWhyItFailedIsNotReplacedByItsExit() {
    BackendProcess backend(host(
        "echo '{\"type\":\"error\",\"message\":\"Cannot reach the node at http://127.0.0.1:1\"}'\n"
        "exit 1\n"));
    QSignalSpy failed(&backend, &BackendProcess::failed);
    backend.start();
    QTRY_VERIFY(!failed.isEmpty());
    // No event marks "no second failure"; give the exit time to arrive.
    QTest::qWait(500);
    QCOMPARE(failed.size(), 1);
    QCOMPARE(failed.first().first().toString(),
             QStringLiteral("Cannot reach the node at http://127.0.0.1:1"));
  }

  void theNodeTheHostStartedReachesTheShellsOwnClient() {
    BackendProcess backend(host(
        "echo '{\"type\":\"ready\",\"url\":\"http://127.0.0.1:5/pair\",\"node\":{\"origin\":\"http://127.0.0.1:6\",\"token\":\"secret\"}}'\n"
        "sleep 5\n"));
    QSignalSpy node(&backend, &BackendProcess::nodeAvailable);
    QSignalSpy ready(&backend, &BackendProcess::ready);
    backend.start();
    QTRY_COMPARE(ready.size(), 1);
    QCOMPARE(node.size(), 1);
    QCOMPARE(node.first().at(0).toUrl(), QUrl(QStringLiteral("http://127.0.0.1:6")));
    QCOMPARE(node.first().at(1).toString(), QStringLiteral("secret"));
    backend.stop();
  }

  // features/desktop/shell-host.feature: An address that is not a node is refused.
  void anAddressThatIsNotANodeIsRefused() {
    BackendProcess backend(host(
        "echo '{\"type\":\"ready\",\"url\":\"http://127.0.0.1:5/some/page?token=abc\"}'\n"
        "sleep 5\n"));
    QSignalSpy node(&backend, &BackendProcess::nodeAvailable);
    QSignalSpy ready(&backend, &BackendProcess::ready);
    QSignalSpy failed(&backend, &BackendProcess::failed);
    backend.start();
    QTRY_COMPARE(failed.size(), 1);
    QCOMPARE(failed.first().first().toString(),
             QStringLiteral("http://127.0.0.1:5/some/page is not a HAL-C2 node. "
                            "Start the desktop app with a node's pairing link to attach to it."));
    QCOMPARE(node.size(), 0);
    QCOMPARE(ready.size(), 0);
    backend.stop();
    QCOMPARE(failed.size(), 1);
  }

  void aHostThatExitsSilentlySaysSo() {
    BackendProcess backend(host("exit 3\n"));
    QSignalSpy failed(&backend, &BackendProcess::failed);
    backend.start();
    QTRY_COMPARE(failed.size(), 1);
    QCOMPARE(failed.first().first().toString(),
             QStringLiteral("Desktop host exited before it was ready (code 3, normal exit)."));
  }
};

QTEST_GUILESS_MAIN(BackendProcessTest)

#include "tst_BackendProcess.moc"
