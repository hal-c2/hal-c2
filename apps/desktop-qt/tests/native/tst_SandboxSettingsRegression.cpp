// What tests/prop/tst_SandboxSettingsProp.cpp found in SandboxSettingsController.

#include <QtTest>

#include <optional>
#include <utility>

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
  // The next run is held, unanswered, in `heldRun`.
  bool holdRun = false;
  std::optional<FakeMc::Rpc> heldRun;
  int runs = 0;
  int reads = 0;
  QJsonObject operation{{QStringLiteral("operation"), QJsonValue()},
                        {QStringLiteral("run"), 0},
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
      ++reads;
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
      if (std::exchange(holdRun, false)) {
        heldRun = rpc;
        return;
      }
      if (operation.value(QLatin1String("running")).toBool()) {
        return mc.refuse(rpc, QStringLiteral("OpenShell's uninstall is already running on this MC. Try uninstall again once it finishes."));
      }
      operation = {{QStringLiteral("operation"), QStringLiteral("uninstall")},
                   {QStringLiteral("run"), runs},
                   {QStringLiteral("running"), true},
                   {QStringLiteral("steps"), QJsonArray()},
                   {QStringLiteral("result"), QJsonValue()}};
      mc.reply(rpc, operation);
      emitAll();
      if (finishAtOnce) finish();
    });
  }

  void finish() {
    end();
    emitAll();
  }

  // The run ends, and nobody is told.
  void end() {
    operation[QStringLiteral("running")] = false;
    operation[QStringLiteral("result")] = QJsonObject{{QStringLiteral("ok"), false},
                                                      {QStringLiteral("code"), QStringLiteral("sandboxes-running")},
                                                      {QStringLiteral("message"), QStringLiteral("1 of this MC's review sandboxes is on the gateway.")},
                                                      {QStringLiteral("sandboxes"), 1},
                                                      {QStringLiteral("drain"), QJsonArray{QStringLiteral("review-1")}}};
  }

  void emitTo(int id) { sendTo(id, operation); }
  void emitAll() {
    for (const int id : mc.subscribers(QStringLiteral("openShell"))) emitTo(id);
  }

  // The MC restarts and loses what it ran: no operation, numbered when it
  // started, above every run before, or below them with its clock gone back.
  void restart(bool back = false) {
    operation = {{QStringLiteral("operation"), QJsonValue()},
                 {QStringLiteral("run"), back ? 0 : runs + 1000},
                 {QStringLiteral("running"), false},
                 {QStringLiteral("steps"), QJsonArray()},
                 {QStringLiteral("result"), QJsonValue()}};
  }

  // Sends `frame` to every follower at once: one it had sent before the run.
  void stale(const QJsonObject& frame) {
    for (const int id : mc.subscribers(QStringLiteral("openShell"))) send(id, frame);
  }

  // Holds the openShell frames from here on, until `releaseFrames`.
  void holdFrames() { holding = true; }
  void releaseFrames() {
    holding = false;
    for (const auto& [id, frame] : std::exchange(held, {})) send(id, frame);
  }
  // The frames held are lost with the connection.
  void dropFrames() {
    holding = false;
    held.clear();
  }

private:
  bool holding = false;
  QList<std::pair<int, QJsonObject>> held;

  void sendTo(int id, const QJsonObject& frame) {
    if (holding) held.append({id, frame});
    else send(id, frame);
  }
  void send(int id, const QJsonObject& frame) {
    mc.send({{QStringLiteral("t"), QStringLiteral("openShell")}, {QStringLiteral("id"), id}, {QStringLiteral("operation"), frame}});
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

  // Waits for what the MC has sent so far: it answers in order.
  void barrier(FakeMc& mc) {
    bool done = false;
    native.client()->call(&native, mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                          [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    QTRY_VERIFY(done);
  }
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

  // A frame from before the run (another device's last uninstall, or the
  // shape's first frame) cleared what kept the actions off: a second press then
  // sent a second run, the MC refused it as busy, and the first run's outcome
  // asked nothing before stopping the review. The stale frame's own outcome
  // was also taken for this run's.
  void aFrameFromBeforeTheRunKeepsTheActionsOff() {
    QTemporaryDir home;
    Mc mc;
    mc.finishAtOnce = false;
    Shell shell(home, mc.mc);
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->synchronized());

    shell.go(kSandboxes);
    QTRY_COMPARE(shell.section().value(QStringLiteral("state")).toString(), QStringLiteral("ready"));
    const QVariantMap uninstall{{QStringLiteral("operation"), QStringLiteral("uninstall")}};
    mc.holdFrames();
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), uninstall);
    QTRY_COMPARE(mc.runs, 1);
    mc.stale(QJsonObject{{QStringLiteral("operation"), QStringLiteral("uninstall")},
                         {QStringLiteral("running"), false},
                         {QStringLiteral("steps"), QJsonArray()},
                         {QStringLiteral("result"), QJsonObject{{QStringLiteral("ok"), false},
                                                                {QStringLiteral("code"), QStringLiteral("sandboxes-running")},
                                                                {QStringLiteral("message"), QStringLiteral("1 of this MC's review sandboxes is on the gateway.")},
                                                                {QStringLiteral("sandboxes"), 1},
                                                      {QStringLiteral("drain"), QJsonArray{QStringLiteral("review-1")}}}}});
    QTRY_VERIFY(!shell.section().value(QStringLiteral("operation")).toMap().value(QStringLiteral("result")).isNull());
    QVERIFY(shell.section().value(QStringLiteral("confirm")).isNull());
    QVERIFY(shell.section().value(QStringLiteral("busy")).toBool());
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), uninstall);

    mc.releaseFrames();
    QTRY_VERIFY(shell.section().value(QStringLiteral("operation")).toMap().value(QStringLiteral("running")).toBool());
    mc.finish();
    QTRY_VERIFY(!shell.section().value(QStringLiteral("confirm")).isNull());
    QCOMPARE(mc.runs, 1);
    QVERIFY(shell.section().value(QStringLiteral("refusal")).isNull());
  }

  // The connection dropped after the run's reply and before its first frame,
  // and the run ended before the page followed the shape again: the first
  // frame after reconnecting, the run ended, was taken for one from before the
  // run, so the page stayed busy and its outcome asked nothing until reopened.
  void aRunThatEndedWhileTheConnectionWasDownSettles() {
    QTemporaryDir home;
    Mc mc;
    mc.finishAtOnce = false;
    Shell shell(home, mc.mc);
    shell.native.client()->setRetryDelays({20});
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->synchronized());

    shell.go(kSandboxes);
    QTRY_COMPARE(shell.section().value(QStringLiteral("state")).toString(), QStringLiteral("ready"));
    mc.holdFrames();
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), QVariantMap{{QStringLiteral("operation"), QStringLiteral("uninstall")}});
    shell.barrier(mc.mc);
    QCOMPARE(mc.runs, 1);
    mc.dropFrames();
    mc.mc.drop();
    mc.end();

    QTRY_VERIFY(!shell.section().value(QStringLiteral("confirm")).isNull());
    QVERIFY(!shell.section().value(QStringLiteral("busy")).toBool());
    QVERIFY(!shell.section().value(QStringLiteral("operation")).toMap().value(QStringLiteral("running")).toBool());
    QCOMPARE(mc.runs, 1);
  }

  // A refusal of a press made before the page was left landed after it was
  // opened again and pressed again: it took the new press for its own, and
  // forgot the page had asked, so the new run's outcome asked nothing before
  // stopping the review.
  void aRefusalFromBeforeThePageClosedLeavesTheNewPressAlone() {
    QTemporaryDir home;
    Mc mc;
    mc.finishAtOnce = false;
    Shell shell(home, mc.mc);
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->synchronized());

    shell.go(kSandboxes);
    QTRY_COMPARE(shell.section().value(QStringLiteral("state")).toString(), QStringLiteral("ready"));
    const QVariantMap uninstall{{QStringLiteral("operation"), QStringLiteral("uninstall")}};
    mc.holdRun = true;
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), uninstall);
    shell.barrier(mc.mc);
    QVERIFY(mc.heldRun.has_value());

    shell.go(kGeneral);
    shell.go(kSandboxes);
    shell.barrier(mc.mc);
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), uninstall);
    QTRY_VERIFY(shell.section().value(QStringLiteral("operation")).toMap().value(QStringLiteral("running")).toBool());
    QCOMPARE(mc.runs, 2);

    mc.mc.refuse(*mc.heldRun, QStringLiteral("OpenShell's status did not answer in time."));
    shell.barrier(mc.mc);
    QVERIFY(shell.section().value(QStringLiteral("refusal")).isNull());
    mc.finish();
    QTRY_VERIFY(!shell.section().value(QStringLiteral("confirm")).isNull());
  }

  // The MC restarted during a run, before its first frame or after: the frames
  // after it never carried the run's number, so the page stayed busy until
  // another run started. With its clock gone back, the restarted MC numbers
  // below the run.
  void anMcThatRestartedDuringTheRunSettlesIt_data() {
    QTest::addColumn<bool>("seen");
    QTest::addColumn<bool>("back");
    QTest::newRow("before its first frame") << false << false;
    QTest::newRow("while it runs") << true << false;
    QTest::newRow("while it runs, its clock back") << true << true;
  }
  void anMcThatRestartedDuringTheRunSettlesIt() {
    QFETCH(bool, seen);
    QFETCH(bool, back);
    QTemporaryDir home;
    Mc mc;
    mc.finishAtOnce = false;
    Shell shell(home, mc.mc);
    shell.native.client()->setRetryDelays({20});
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->synchronized());

    shell.go(kSandboxes);
    QTRY_COMPARE(shell.section().value(QStringLiteral("state")).toString(), QStringLiteral("ready"));
    if (!seen) mc.holdFrames();
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), QVariantMap{{QStringLiteral("operation"), QStringLiteral("uninstall")}});
    shell.barrier(mc.mc);
    QCOMPARE(mc.runs, 1);
    if (!seen) {
      // A frame from before the run, with no operation, keeps the page waiting.
      mc.stale(QJsonObject{{QStringLiteral("operation"), QJsonValue()},
                           {QStringLiteral("run"), 0},
                           {QStringLiteral("running"), false},
                           {QStringLiteral("steps"), QJsonArray()},
                           {QStringLiteral("result"), QJsonValue()}});
      shell.barrier(mc.mc);
      QVERIFY(shell.section().value(QStringLiteral("busy")).toBool());
      QVERIFY(shell.section().value(QStringLiteral("refusal")).isNull());
      mc.dropFrames();
    } else {
      QVERIFY(shell.section().value(QStringLiteral("operation")).toMap().value(QStringLiteral("running")).toBool());
    }
    mc.restart(back);
    mc.mc.drop();

    QTRY_COMPARE(shell.section().value(QStringLiteral("refusal")).toString(),
                 QStringLiteral("The MC lost track of the run; check the status before trying again."));
    QVERIFY(!shell.section().value(QStringLiteral("busy")).toBool());
    QVERIFY(shell.section().value(QStringLiteral("operation")).isNull());
    QTRY_COMPARE(mc.reads, 2);
  }

  // Another device installed while the connection was down, and the first
  // frame after reconnecting showed its run ended: the outcome showed, but the
  // status still offered what it had before, as only a run the page saw going
  // read it again.
  void aRunAnotherDeviceEndedWhileTheConnectionWasDownReadsTheStatus() {
    QTemporaryDir home;
    Mc mc;
    mc.runs = 5;
    mc.operation = {{QStringLiteral("operation"), QStringLiteral("uninstall")},
                    {QStringLiteral("run"), mc.runs},
                    {QStringLiteral("running"), false},
                    {QStringLiteral("steps"), QJsonArray()},
                    {QStringLiteral("result"), QJsonObject{{QStringLiteral("ok"), true},
                                                           {QStringLiteral("code"), QJsonValue()},
                                                           {QStringLiteral("message"), QStringLiteral("OpenShell removed.")},
                                                           {QStringLiteral("sandboxes"), QJsonValue()}}}};
    Shell shell(home, mc.mc);
    shell.native.client()->setRetryDelays({20});
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->synchronized());

    // The read the page opens with covers the run its first frame shows.
    shell.go(kSandboxes);
    QTRY_COMPARE(shell.section().value(QStringLiteral("state")).toString(), QStringLiteral("ready"));
    shell.barrier(mc.mc);
    QCOMPARE(mc.reads, 1);

    mc.mc.drop();
    mc.operation[QStringLiteral("operation")] = QStringLiteral("install");
    mc.operation[QStringLiteral("run")] = ++mc.runs;
    QTRY_COMPARE(shell.section().value(QStringLiteral("operation")).toMap().value(QStringLiteral("operation")).toString(), QStringLiteral("install"));
    QTRY_COMPARE(mc.reads, 2);

    // The same run again reads nothing more: the first barrier lands after the
    // frame, the second after any read the frame sent.
    mc.emitAll();
    shell.barrier(mc.mc);
    shell.barrier(mc.mc);
    QCOMPARE(mc.reads, 2);
  }

  // The question about stopping reviews was open when another device's
  // operation started: a yes then sent the run anyway, the MC refused it as
  // busy, and the question was gone. The yes waits, and the question stays.
  void confirmingWhileAnotherRunsKeepsTheQuestion() {
    QTemporaryDir home;
    Mc mc;
    Shell shell(home, mc.mc);
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->synchronized());

    shell.go(kSandboxes);
    QTRY_COMPARE(shell.section().value(QStringLiteral("state")).toString(), QStringLiteral("ready"));
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), QVariantMap{{QStringLiteral("operation"), QStringLiteral("uninstall")}});
    QTRY_VERIFY(!shell.section().value(QStringLiteral("confirm")).isNull());

    mc.operation = {{QStringLiteral("operation"), QStringLiteral("check")},
                    {QStringLiteral("run"), 2},
                    {QStringLiteral("running"), true},
                    {QStringLiteral("steps"), QJsonArray()},
                    {QStringLiteral("result"), QJsonValue()}};
    mc.emitAll();
    QTRY_VERIFY(shell.section().value(QStringLiteral("busy")).toBool());
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.confirm"), {});
    shell.barrier(mc.mc);
    QCOMPARE(mc.runs, 1);
    QVERIFY(!shell.section().value(QStringLiteral("confirm")).isNull());
    QVERIFY(shell.section().value(QStringLiteral("refusal")).isNull());

    mc.operation[QStringLiteral("running")] = false;
    mc.operation[QStringLiteral("result")] = QJsonObject{{QStringLiteral("ok"), true}, {QStringLiteral("message"), QStringLiteral("Done.")}};
    mc.emitAll();
    QTRY_VERIFY(!shell.section().value(QStringLiteral("busy")).toBool());
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.confirm"), {});
    QTRY_COMPARE(mc.runs, 2);
  }

  // The MC restarted with its clock gone back while nothing ran and no run
  // had been seen going: its idle frame's number below the last frame's told
  // the restart, but the status the old MC read stood until a refresh.
  void aRestartWithTheClockBackWhileIdleReadsTheStatus() {
    QTemporaryDir home;
    Mc mc;
    mc.runs = 5;
    mc.operation = {{QStringLiteral("operation"), QStringLiteral("install")},
                    {QStringLiteral("run"), mc.runs},
                    {QStringLiteral("running"), false},
                    {QStringLiteral("steps"), QJsonArray()},
                    {QStringLiteral("result"), QJsonObject{{QStringLiteral("ok"), true}, {QStringLiteral("message"), QStringLiteral("Done.")}}}};
    Shell shell(home, mc.mc);
    shell.native.client()->setRetryDelays({20});
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->synchronized());

    shell.go(kSandboxes);
    QTRY_COMPARE(shell.section().value(QStringLiteral("state")).toString(), QStringLiteral("ready"));
    shell.barrier(mc.mc);
    QCOMPARE(mc.reads, 1);

    mc.restart(true);
    mc.mc.drop();
    QTRY_COMPARE(mc.reads, 2);
  }

  // This page's run ended while the connection was down and another device's
  // followed it: the first frame after reconnecting was the later run's, and
  // the page said nothing of its own, whose outcome it never saw.
  void aLaterRunReplacingTheRequestedOneSaysItsOutcomeIsUnknown() {
    QTemporaryDir home;
    Mc mc;
    mc.finishAtOnce = false;
    Shell shell(home, mc.mc);
    shell.native.client()->setRetryDelays({20});
    QTRY_VERIFY(shell.native.isActive() && shell.native.store()->synchronized());

    shell.go(kSandboxes);
    QTRY_COMPARE(shell.section().value(QStringLiteral("state")).toString(), QStringLiteral("ready"));
    mc.holdFrames();
    shell.bridge.dispatch(QStringLiteral("sandboxSettings.run"), QVariantMap{{QStringLiteral("operation"), QStringLiteral("uninstall")}});
    shell.barrier(mc.mc);
    QCOMPARE(mc.runs, 1);
    mc.dropFrames();
    mc.mc.drop();
    mc.operation = {{QStringLiteral("operation"), QStringLiteral("check")},
                    {QStringLiteral("run"), 2},
                    {QStringLiteral("running"), false},
                    {QStringLiteral("steps"), QJsonArray()},
                    {QStringLiteral("result"), QJsonObject{{QStringLiteral("ok"), true}, {QStringLiteral("message"), QStringLiteral("Done.")}}}};

    QTRY_COMPARE(shell.section().value(QStringLiteral("refusal")).toString(),
                 QStringLiteral("The MC lost track of the run; check the status before trying again."));
    QVERIFY(!shell.section().value(QStringLiteral("busy")).toBool());
    QVERIFY(shell.section().value(QStringLiteral("confirm")).isNull());
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
