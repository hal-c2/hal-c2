// What the review of hal-c2/hal-c2#1210 found in the thread's error banner.

#include <QtTest>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadErrorController.h"

class ThreadErrorRegression : public QObject {
  Q_OBJECT

private slots:
  // A dismissal hid the message for the rest of the run, so a stop the MC
  // refused again in the same run said nothing the second time.
  void anErrorReportedAgainShowsAfterADismissal() {
    QTemporaryDir home;
    FakeMc mc;
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("p1")},
                                                         {QStringLiteral("title"), QStringLiteral("Shop")},
                                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                         {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                         {QStringLiteral("scripts"), QJsonArray()}});
    mc.threads.insert(QStringLiteral("t1"), QJsonObject{{QStringLiteral("id"), QStringLiteral("t1")},
                                                        {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                        {QStringLiteral("title"), QStringLiteral("Thread 1")},
                                                        {QStringLiteral("latestRunId"), QStringLiteral("run-1")},
                                                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")}});
    ShellBridge bridge;
    NativeShell native(&bridge);
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    const QString key = QStringLiteral("env-a:t1");
    QTRY_VERIFY(native.isActive() && native.store()->threadOnline(key));
    native.controller<NavigationController>()->open(NavigationController::Route::thread(key));

    const QString refused = QStringLiteral("The provider session has already exited.");
    const auto shown = [&] { return bridge.state()->value(QStringLiteral("threadError")).toMap().value(QStringLiteral("message")).toString(); };
    auto* errors = native.controller<ThreadErrorController>();
    errors->report(key, refused);
    QTRY_COMPARE(shown(), refused);
    bridge.dispatch(QStringLiteral("threadError.dismiss"), {});
    QTRY_COMPARE(shown(), QString());
    errors->report(key, refused);
    QTRY_COMPARE(shown(), refused);
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/thread-error-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  ThreadErrorRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_ThreadErrorRegression.moc"
