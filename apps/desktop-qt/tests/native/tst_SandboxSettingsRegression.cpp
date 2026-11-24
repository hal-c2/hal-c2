// What tests/prop/tst_SandboxSettingsProp.cpp found in SandboxSettingsController.

#include <QtTest>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

const QString kSandboxes = QStringLiteral("/settings/sandboxes");
const QString kGeneral = QStringLiteral("/settings/general");

// A fake MC with a gateway it runs and one of its reviews on it: an uninstall
// without drain answers that it would stop that review, at once or on
// `finish()`, and a second run while one runs is refused as busy.
struct Mc {
  FakeMc mc;
  bool finishAtOnce = true;
  int runs = 0;
  QJsonObject operation{{QStringLiteral("operation"), QJsonValue()},
                        {QStringLiteral("running"), false},
                        {QStringLiteral("steps"), QJsonArray()},
                        {QStringLiteral("result"), QJsonValue()}};

  Mc() {
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onShape(QStringLiteral("openShell"), [this](int id, const QJsonObject&) { emitTo(id); });
    mc.onRpc(QStringLiteral("server.getOpenShellStatus"), [this](const FakeMc::Rpc& rpc) {
      mc.reply(rpc, QJsonObject{{QStringLiteral("supported"), true},
                                {QStringLiteral("ready"), true},
                                {QStringLiteral("mode"), QStringLiteral("managed")},
                                {QStringLiteral("version"), QStringLiteral("0.1.7")},
                                {QStringLiteral("pinnedVersion"), QStringLiteral("0.1.7")},
                                {QStringLiteral("problems"), QJsonArray()},
                                {QStringLiteral("actions"), QJsonArray{QJsonObject{{QStringLiteral("operation"), QStringLiteral("uninstall")},
                                                                                   {QStringLiteral("label"), QStringLiteral("Uninstall")}}}},
                                {QStringLiteral("canManage"), true},
                                {QStringLiteral("manageReason"), QJsonValue()}});
    });
    mc.onRpc(QStringLiteral("server.runOpenShellOperation"), [this](const FakeMc::Rpc& rpc) {
      ++runs;
      if (operation.value(QLatin1String("running")).toBool()) {
        return mc.refuse(rpc, QStringLiteral("OpenShell's uninstall is already running on this MC. Try uninstall again once it finishes."));
      }
      operation = {{QStringLiteral("operation"), QStringLiteral("uninstall")},
                   {QStringLiteral("running"), true},
                   {QStringLiteral("steps"), QJsonArray()},
                   {QStringLiteral("result"), QJsonValue()}};
      mc.reply(rpc, operation);
      emitAll();
      if (finishAtOnce) finish();
    });
  }

  void finish() {
    operation[QStringLiteral("running")] = false;
    operation[QStringLiteral("result")] = QJsonObject{{QStringLiteral("ok"), false},
                                                      {QStringLiteral("code"), QStringLiteral("sandboxes-running")},
                                                      {QStringLiteral("message"), QStringLiteral("1 of this MC's review sandboxes is on the gateway.")},
                                                      {QStringLiteral("sandboxes"), 1}};
    emitAll();
  }

  void emitTo(int id) {
    mc.send({{QStringLiteral("t"), QStringLiteral("openShell")}, {QStringLiteral("id"), id}, {QStringLiteral("operation"), operation}});
  }
  void emitAll() {
    for (const int id : mc.subscribers(QStringLiteral("openShell"))) emitTo(id);
  }
};

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

  QVariantMap section() const { return bridge.state()->value(QStringLiteral("sandboxSettings")).toMap(); }
  void go(const QString& path) { native.controller<NavigationController>()->open(NavigationController::Route::settings(path)); }
};

}  // namespace

class SandboxSettingsRegression : public QObject {
  Q_OBJECT

private slots:
  // Leaving the page forgot the question about stopping reviews but did not
  // say so: the section kept showing it until something else published.
  void leavingThePageTakesItsQuestionAway() {
    QTemporaryDir home;
    Mc mc;
    Shell shell(home, mc.mc);
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->synchronized());

    shell.go(kSandboxes);
    QTRY_COMPARE(shell.section().value(QStringLiteral("state")).toString(), QStringLiteral("ready"));
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), QVariantMap{{QStringLiteral("operation"), QStringLiteral("uninstall")}});
    QTRY_VERIFY(!shell.section().value(QStringLiteral("confirm")).isNull());

    shell.go(kGeneral);
    QVERIFY(shell.section().value(QStringLiteral("confirm")).isNull());
  }

  // A second press before the first run's frame sent a second run, the MC
  // refused it as busy, and that refusal forgot the page had asked: the first
  // run's outcome then asked nothing before stopping the review.
  void aSecondPressBeforeTheFirstFrameKeepsTheQuestion() {
    QTemporaryDir home;
    Mc mc;
    mc.finishAtOnce = false;
    Shell shell(home, mc.mc);
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->synchronized());

    shell.go(kSandboxes);
    QTRY_COMPARE(shell.section().value(QStringLiteral("state")).toString(), QStringLiteral("ready"));
    const QVariantMap uninstall{{QStringLiteral("operation"), QStringLiteral("uninstall")}};
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), uninstall);
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), uninstall);
    QTRY_VERIFY(shell.section().value(QStringLiteral("operation")).toMap().value(QStringLiteral("running")).toBool());

    mc.finish();
    QTRY_VERIFY(!shell.section().value(QStringLiteral("confirm")).isNull());
    QCOMPARE(mc.runs, 1);
    QVERIFY(shell.section().value(QStringLiteral("refusal")).isNull());
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/sandbox-settings-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  SandboxSettingsRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_SandboxSettingsRegression.moc"
