// A scripted screenshot of a start that fails (features/desktop/
// shell-host.feature): the capture and the exit code are main.cpp's, so this
// runs the built app itself, offscreen, with a home of its own and a pairing
// link nothing listens behind. The app is HAL_C2_DESKTOP_BINARY, else the
// one `mise run desktop:build` leaves in build/release or build/debug.

#include <QDir>
#include <QFileInfo>
#include <QImage>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSet>
#include <QTcpServer>
#include <QTemporaryDir>

#include <memory>

#include "Harness.h"
#include "World.h"

namespace {

struct FailedStart {
  std::unique_ptr<QTemporaryDir> home;
  QString origin;
  QString log;
  int exitCode = -1;
  bool exited = false;
  QString shot;
};

QString desktopBinary() {
  const QString appDir = QDir(QStringLiteral(HAL_C2_QML_DIR)).absoluteFilePath(QStringLiteral(".."));
  QStringList candidates{qEnvironmentVariable("HAL_C2_DESKTOP_BINARY")};
  for (const QString& build : {QStringLiteral("release"), QStringLiteral("debug")}) {
    for (const QString& binary : {QStringLiteral("hal-c2-qt.app/Contents/MacOS/hal-c2-qt"), QStringLiteral("hal-c2-qt"), QStringLiteral("hal-c2-qt.exe")}) {
      candidates.append(QDir(appDir).absoluteFilePath(QStringLiteral("build/%1/%2").arg(build, binary)));
    }
  }
  for (const QString& candidate : std::as_const(candidates)) {
    if (!candidate.isEmpty() && QFileInfo(candidate).isFile()) return QDir::cleanPath(candidate);
  }
  fail(QStringLiteral("the desktop app is not built: run `mise run desktop:build`, or set HAL_C2_DESKTOP_BINARY"));
}

const Steps steps([] {
  step(QStringLiteral("the user starts the desktop app asking for a screenshot, with a pairing link for an MC that is not running"),
       [](World& world, const Captures&, const Table&) {
         FailedStart& start = world.mc.part<FailedStart>();
         start.home = std::make_unique<QTemporaryDir>();
         // A port nothing listens on: taken, then let go.
         QTcpServer probe;
         expect(probe.listen(QHostAddress::LocalHost), probe.errorString());
         start.origin = QStringLiteral("http://127.0.0.1:%1").arg(probe.serverPort());
         probe.close();
         start.shot = start.home->filePath(QStringLiteral("shot.png"));
         const QString appDir = QDir(QStringLiteral(HAL_C2_QML_DIR)).absoluteFilePath(QStringLiteral(".."));
         QProcess app;
         QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
         environment.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("offscreen"));
         // Every file it keeps goes under the scratch home, never the user's.
         environment.insert(QStringLiteral("HAL_C2_HOME"), start.home->path());
         app.setProcessEnvironment(environment);
         app.setProcessChannelMode(QProcess::MergedChannels);
         app.start(desktopBinary(), {QStringLiteral("--home-dir"), start.home->path(),
                                     QStringLiteral("--config-dir"), start.home->filePath(QStringLiteral("shell")),
                                     // The source tree's host on the PATH's Node: a release build names installed ones.
                                     QStringLiteral("--host-entry"), QDir(appDir).absoluteFilePath(QStringLiteral("host/main.ts")),
                                     QStringLiteral("--node"), QStringLiteral("node"),
                                     QStringLiteral("--url"), start.origin + QStringLiteral("/#token=spent"),
                                     QStringLiteral("--screenshot"), start.shot});
         expect(app.waitForStarted(), QStringLiteral("the desktop app did not start: %1").arg(app.errorString()));
         start.exited = app.waitForFinished(60000);
         start.log = QString::fromUtf8(app.readAll());
         if (!start.exited) {
           app.kill();
           app.waitForFinished();
           fail(QStringLiteral("the desktop app did not quit; it said:\n%1").arg(start.log));
         }
         expect(app.exitStatus() == QProcess::NormalExit, QStringLiteral("the desktop app crashed; it said:\n%1").arg(start.log));
         start.exitCode = app.exitCode();
       });
  step(QStringLiteral("the screenshot shows the desktop app saying it cannot reach the MC"), [](World& world, const Captures&, const Table&) {
    const FailedStart& start = world.mc.part<FailedStart>();
    // What the window was told, then the capture of it.
    const qsizetype told = start.log.indexOf(QStringLiteral("[shell] Cannot reach the MC at %1").arg(start.origin));
    const qsizetype captured = start.log.indexOf(QStringLiteral("[shell] screenshot written: %1").arg(start.shot));
    expect(told >= 0 && captured > told, QStringLiteral("the desktop app said:\n%1").arg(start.log));
    const QImage shot(start.shot);
    expect(!shot.isNull() && shot.width() > 200 && shot.height() > 200, QStringLiteral("no screenshot at %1").arg(start.shot));
    // The error is drawn over the window: more than its background.
    QSet<QRgb> colours;
    for (int y = 0; y < shot.height() && colours.size() < 3; y += 2) {
      for (int x = 0; x < shot.width() && colours.size() < 3; x += 2) colours.insert(shot.pixel(x, y));
    }
    expect(colours.size() >= 3, QStringLiteral("the screenshot is one flat colour"));
  });
  step(QStringLiteral("the desktop app quits with a failure code"), [](World& world, const Captures&, const Table&) {
    const FailedStart& start = world.mc.part<FailedStart>();
    expect(start.exited && start.exitCode == 2, QStringLiteral("the desktop app quit with %1").arg(start.exitCode));
  });
});

}  // namespace
