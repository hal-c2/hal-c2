// What tests/prop/tst_SettingsRoutesProp.cpp is about: a window restored on a
// settings page showed it empty until the user left and came back, because
// the page's controller only watched the route change and the route was
// restored before the controller activated.

#include <QtTest>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

// The app on `mc`, its stores in `home`.
struct Shell {
  ShellBridge bridge;
  NativeShell native{&bridge};

  Shell(const QTemporaryDir& home, FakeMc& mc) {
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")),
                        home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
  }

  bool shows(const QString& key) const { return bridge.state()->value(key).toMap().value(QStringLiteral("open")).toBool(); }
};

}  // namespace

class SettingsRoutesRegression : public QObject {
  Q_OBJECT

private slots:
  void aWindowRestoredOnASettingsPageShowsIt_data() {
    QTest::addColumn<QString>("route");
    QTest::addColumn<QString>("key");
    QTest::newRow("integrations") << "/settings/integrations" << "deviceSettings";
    QTest::newRow("projects") << "/settings/projects" << "projectSettings";
    QTest::newRow("source control") << "/settings/source-control" << "sourceControlSettings";
    QTest::newRow("scheduled tasks") << "/settings/scheduled-tasks" << "scheduledTasks";
  }

  void aWindowRestoredOnASettingsPageShowsIt() {
    QFETCH(QString, route);
    QFETCH(QString, key);
    QTemporaryDir home;
    FakeMc mc;
    mc.onShape(QStringLiteral("config"), [&mc](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()}}}});
    });
    {
      Shell first(home, mc);
      QTRY_VERIFY(first.native.isActive() && first.native.store()->synchronized());
      first.native.controller<NavigationController>()->open(NavigationController::Route::settings(route));
      QTRY_VERIFY(first.shows(key));
    }
    Shell again(home, mc);
    QTRY_VERIFY(again.native.isActive() && again.native.store()->synchronized());
    QVERIFY(again.shows(key));
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/settings-routes-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  SettingsRoutesRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_SettingsRoutesRegression.moc"
