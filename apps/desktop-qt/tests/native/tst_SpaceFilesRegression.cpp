// What tests/prop/tst_SpaceFilesProp.cpp found in SpaceController's project files.

#include <QtTest>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "SpaceController.h"

namespace {

struct Shell {
  QTemporaryDir home;
  FakeMc mc;
  ShellBridge bridge;
  NativeShell native{&bridge};
  QList<FakeMc::Rpc> held;

  Shell() {
    mc.onRpc(QStringLiteral("space.files.list"), [this](const FakeMc::Rpc& rpc) { held.append(rpc); });
    native.client()->setRetryDelays({20});
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
  }

  SpaceController* space() { return native.controller<SpaceController>(); }
  bool list(const QString& project) { return space()->handle(QStringLiteral("space.files.list"), QVariantMap{{QStringLiteral("projectId"), project}}); }
  void answer(const FakeMc::Rpc& rpc, const QString& path) {
    const QJsonObject file{{QStringLiteral("relativePath"), path}, {QStringLiteral("kind"), QStringLiteral("markdown")}, {QStringLiteral("page"), QJsonValue::Null}};
    mc.reply(rpc, QJsonObject{{QStringLiteral("config"), QStringLiteral("default")}, {QStringLiteral("files"), QJsonArray{file}}});
  }
  QStringList paths(const QString& project) const {
    return bridge.state()->value(QStringLiteral("space")).toMap().value(QStringLiteral("files")).toMap().value(project).toMap().value(QStringLiteral("paths")).toMap().keys();
  }
};

}  // namespace

class SpaceFilesRegression : public QObject {
  Q_OBJECT

private slots:
  // ListFiles(alpha), Answer(0), ListFiles(alpha), GoOffline: the second list,
  // answered "disconnected" by the drop, wiped the files the first had brought.
  void aDropWhileListingKeepsTheFiles() {
    Shell shell;
    QTRY_VERIFY(shell.native.isActive() && shell.native.client()->isReady());

    QVERIFY(shell.list(QStringLiteral("alpha")));
    QTRY_COMPARE(shell.held.size(), 1);
    shell.answer(shell.held.takeFirst(), QStringLiteral("alpha-1.md"));
    QTRY_COMPARE(shell.paths(QStringLiteral("alpha")), QStringList{QStringLiteral("alpha-1.md")});

    QVERIFY(shell.list(QStringLiteral("alpha")));
    QTRY_COMPARE(shell.held.size(), 1);
    shell.mc.stopAccepting();
    shell.mc.drop();
    shell.held.clear();
    QTRY_VERIFY(!shell.native.client()->isReady());
    QCOMPARE(shell.paths(QStringLiteral("alpha")), QStringList{QStringLiteral("alpha-1.md")});

    // On connecting it asks again, and that answer stands.
    shell.mc.startAccepting();
    QTRY_COMPARE(shell.held.size(), 1);
    shell.answer(shell.held.takeFirst(), QStringLiteral("alpha-2.md"));
    QTRY_COMPARE(shell.paths(QStringLiteral("alpha")), QStringList{QStringLiteral("alpha-2.md")});
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/space-files-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  SpaceFilesRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_SpaceFilesRegression.moc"
