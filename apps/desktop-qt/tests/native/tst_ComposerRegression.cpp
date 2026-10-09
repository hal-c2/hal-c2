// What tests/prop/tst_ComposerProp.cpp and tst_ComposerPureProp.cpp found in
// the composer.

#include <QtTest>

#include "ComposerController.h"
#include "ComposerModel.h"
#include "DraftController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "ToastController.h"
#include "TestTime.h"

namespace {

// The app on a fake MC with one thread, its stores in `home`. The MC outlives
// the app, which can quit and start again.
struct Shell {
  explicit Shell(const QString& home) : home(home) {
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{
                                                 {QStringLiteral("id"), QStringLiteral("p1")},
                                                 {QStringLiteral("title"), QStringLiteral("Shop")},
                                                 {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                 {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("scripts"), QJsonArray()},
                                             });
    mc.threads.insert(QStringLiteral("t1"), QJsonObject{
                                                {QStringLiteral("id"), QStringLiteral("t1")},
                                                {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                {QStringLiteral("title"), QStringLiteral("t1")},
                                                {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                                {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                            });
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      const QJsonObject provider{
          {QStringLiteral("instanceId"), QStringLiteral("codex")},
          {QStringLiteral("driver"), QStringLiteral("codex")},
          {QStringLiteral("enabled"), true},
          {QStringLiteral("status"), QStringLiteral("ready")},
          {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), QStringLiteral("gpt-a")}}}},
      };
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("providers"), QJsonArray{provider}},
                                                     {QStringLiteral("settings"), QJsonObject()}}}});
    });
    // The thread's user messages, whole on each subscription, then as they come.
    mc.onShape(QStringLiteral("stream"), [this](int id, const QJsonObject& shape) {
      QJsonArray rows;
      for (const QJsonObject& message : messages.value(shape.value(QLatin1String("stream")).toString())) {
        rows.append(QJsonArray{QStringLiteral("message"), message.value(QLatin1String("id")), message});
      }
      mc.send({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("id"), id}, {QStringLiteral("part"), 0},
               {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("offset"), 0},
               {QStringLiteral("floor"), QJsonValue::Null}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
      mc.send({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("id"), id}, {QStringLiteral("offset"), 0},
               {QStringLiteral("handle"), QStringLiteral("log-1")}});
    });
    mc.effects.append([this](const QJsonObject& command) {
      if (losing || command.value(QLatin1String("type")) != QLatin1String("message.dispatch")) return;
      addMessage(command.value(QLatin1String("threadId")).toString(), command.value(QLatin1String("messageId")).toString());
    });
    start();
  }

  ~Shell() {
    native.reset();
    bridge.reset();
  }

  void start() {
    bridge = std::make_unique<ShellBridge>();
    native = std::make_unique<NativeShell>(bridge.get());
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home + QStringLiteral("/state"), home + QStringLiteral("/data"), home + QStringLiteral("/cache"));
    native->controller<SettingsController>()->setDevicePath(home + QStringLiteral("/config/preferences.json"));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
  }

  // The app quits with the MC holding its last send; the MC gets it once the
  // app is gone (`received`), or never did.
  bool restart(bool received) {
    native.reset();
    bridge.reset();
    if (!halc2::test::waitFor([this] { return !mc.connected(); })) return false;
    losing = !received;
    mc.answerHeld();
    losing = false;
    start();
    return halc2::test::waitFor([this] { return native->isActive() && native->store()->threadOnline(key); });
  }

  // A user message reaches the thread (this app's send, or another device's).
  void addMessage(const QString& thread, const QString& id) {
    const QJsonObject message{{QStringLiteral("id"), id}, {QStringLiteral("role"), QStringLiteral("user")},
                              {QStringLiteral("createdBy"), QStringLiteral("user")},
                              {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:%1.000Z").arg(messages[thread].size(), 2, 10, QLatin1Char('0'))}};
    messages[thread].append(message);
    if (!mc.connected()) return;
    for (const int sub : mc.subscribers(QStringLiteral("stream"))) {
      if (mc.shapeOf(sub).value(QLatin1String("stream")).toString() != thread) continue;
      mc.send({{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("id"), sub}, {QStringLiteral("offset"), 0},
               {QStringLiteral("events"), QJsonArray{QJsonArray{0, QStringLiteral("message"), id,
                                                                QJsonObject{{QStringLiteral("s"), message}},
                                                                message.value(QLatin1String("createdAt"))}}}});
    }
  }

  // Opens the thread and waits for its messages.
  bool open() {
    bridge->dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), key}});
    return halc2::test::waitFor([this] {
      const auto* timeline = native->controller<ThreadStore>()->timeline(key);
      return timeline && timeline->status() == QLatin1String("live") &&
             bridge->state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")).toString() == key;
    });
  }

  ComposerController* composer() const { return native->controller<ComposerController>(); }

  QVariantMap edit() { return {{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), ++revision}}; }

  void type(const QString& text) {
    bridge->dispatch(QStringLiteral("composer.text.set"), QVariantMap{{QStringLiteral("target"), key},
                                                                    {QStringLiteral("edit"), edit()},
                                                                    {QStringLiteral("text"), text},
                                                                    {QStringLiteral("cursor"), text.size()}});
  }

  void submit(const QString& text) {
    bridge->dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("edit"), edit()},
                                                                  {QStringLiteral("text"), text},
                                                                  {QStringLiteral("intent"), QStringLiteral("foreground")}});
  }

  int dispatched() const {
    return int(std::count_if(mc.commands.cbegin(), mc.commands.cend(), [](const QJsonObject& command) {
      return command.value(QLatin1String("type")) == QLatin1String("message.dispatch");
    }));
  }

  bool offersRestore() const {
    for (const QVariant& toast : bridge->state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      for (const QVariant& action : toast.toMap().value(QStringLiteral("actions")).toList()) {
        if (action.toMap().value(QStringLiteral("label")) == QLatin1String("Restore prompt")) return true;
      }
    }
    return false;
  }

  QString home;
  FakeMc mc;
  std::unique_ptr<ShellBridge> bridge;
  std::unique_ptr<NativeShell> native;
  QString key = QStringLiteral("env-a:t1");
  int revision = 0;
  QHash<QString, QList<QJsonObject>> messages;
  // While set, what the MC answers never reached it.
  bool losing = false;
};

}  // namespace

class ComposerRegression : public QObject {
  Q_OBJECT

private slots:
  // With the caret at the very start of a draft whose first line is empty and
  // whose second starts with "/", the slash menu opened for a command that
  // started after the caret: start 1, end 0.
  void noTriggerAfterTheCaret() {
    QCOMPARE(composer::trigger(QStringLiteral("\n/"), 0).has_value(), false);
    QCOMPARE(composer::trigger(QStringLiteral("\n/model"), 0).has_value(), false);
    const auto slash = composer::trigger(QStringLiteral("\n/mo"), 3);
    QVERIFY(slash);
    QCOMPARE(slash->start, 1);
    QCOMPARE(slash->end, 3);
  }

  // A send the MC refused came back only into an empty draft: when the user
  // had typed something newer meanwhile, the refused prompt was gone. It is
  // now kept behind the toast's "Restore prompt".
  void aRefusedPromptBehindNewerTypingCanBeRestored() {
    QTemporaryDir home;
    Shell shell(home.path());
    HAL_C2_TRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());

    shell.mc.hold(QStringLiteral("answers"));
    shell.mc.refusals.insert(QStringLiteral("message.dispatch"), QStringLiteral("The thread is busy."));
    shell.type(QStringLiteral("first prompt"));
    shell.submit(QStringLiteral("first prompt"));
    HAL_C2_TRY_COMPARE(shell.dispatched(), 1);
    QCOMPARE(shell.composer()->draft(shell.key), QString());
    shell.type(QStringLiteral("newer"));
    shell.mc.answerHeld();

    auto* toasts = shell.native->controller<ToastController>();
    HAL_C2_TRY_VERIFY(shell.offersRestore());
    QCOMPARE(shell.composer()->draft(shell.key), QStringLiteral("newer"));
    shell.type(QString());
    QVERIFY(toasts->runAction(QStringLiteral("Restore prompt")));
    QCOMPARE(shell.composer()->draft(shell.key), QStringLiteral("first prompt"));
    QVERIFY(!shell.offersRestore());
  }

  // A prompt still on its way when the app quit was lost: the draft was
  // cleared on submit and the send was kept nowhere. It now comes back as the
  // draft once the thread's messages show the MC never got it.
  void aPromptCutOffByAQuitComesBackAsTheDraft() {
    QTemporaryDir home;
    Shell shell(home.path());
    HAL_C2_TRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    shell.mc.hold(QStringLiteral("answers"));
    shell.type(QStringLiteral("first prompt"));
    shell.submit(QStringLiteral("first prompt"));
    HAL_C2_TRY_COMPARE(shell.dispatched(), 1);
    QCOMPARE(shell.composer()->draft(shell.key), QString());

    QVERIFY(shell.restart(false));
    QVERIFY(shell.open());
    QCOMPARE(shell.composer()->draft(shell.key), QStringLiteral("first prompt"));
    QVERIFY(!shell.offersRestore());
    QCOMPARE(shell.dispatched(), 1);
  }

  // One the MC did get is in the thread, and is not given back to send twice.
  void aPromptTheMcGotBeforeTheQuitIsNotRestored() {
    QTemporaryDir home;
    Shell shell(home.path());
    HAL_C2_TRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    shell.mc.hold(QStringLiteral("answers"));
    shell.type(QStringLiteral("first prompt"));
    shell.submit(QStringLiteral("first prompt"));
    HAL_C2_TRY_COMPARE(shell.dispatched(), 1);

    QVERIFY(shell.restart(true));
    QVERIFY(shell.open());
    QCOMPARE(shell.composer()->draft(shell.key), QString());
    QVERIFY(!shell.offersRestore());
    // Nor after the next restart: it is no longer kept.
    QVERIFY(shell.restart(true));
    QVERIFY(shell.open());
    QCOMPARE(shell.composer()->draft(shell.key), QString());
  }

  // Newer typing in the draft stays; the cut-off prompt waits behind the toast.
  void aCutOffPromptBehindNewerTypingWaitsBehindTheToast() {
    QTemporaryDir home;
    Shell shell(home.path());
    HAL_C2_TRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    shell.mc.hold(QStringLiteral("answers"));
    shell.type(QStringLiteral("first prompt"));
    shell.submit(QStringLiteral("first prompt"));
    HAL_C2_TRY_COMPARE(shell.dispatched(), 1);
    shell.type(QStringLiteral("newer"));

    QVERIFY(shell.restart(false));
    QVERIFY(shell.open());
    QCOMPARE(shell.composer()->draft(shell.key), QStringLiteral("newer"));
    QVERIFY(shell.offersRestore());
    shell.type(QString());
    QVERIFY(shell.native->controller<ToastController>()->runAction(QStringLiteral("Restore prompt")));
    QCOMPARE(shell.composer()->draft(shell.key), QStringLiteral("first prompt"));
  }

  // A newer user message in the thread (another device's) means the user
  // moved on: the cut-off prompt is not brought back.
  void aCutOffPromptBehindANewerMessageIsDropped() {
    QTemporaryDir home;
    Shell shell(home.path());
    HAL_C2_TRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    shell.mc.hold(QStringLiteral("answers"));
    shell.type(QStringLiteral("first prompt"));
    shell.submit(QStringLiteral("first prompt"));
    HAL_C2_TRY_COMPARE(shell.dispatched(), 1);
    shell.addMessage(QStringLiteral("t1"), QStringLiteral("from-the-phone"));

    QVERIFY(shell.restart(false));
    QVERIFY(shell.open());
    QCOMPARE(shell.composer()->draft(shell.key), QString());
    QVERIFY(!shell.offersRestore());
  }

  // A new thread's first prompt, its launch unanswered when the app quit,
  // comes back to the draft when the thread was never made.
  void aNewThreadsCutOffFirstPromptComesBackToItsDraft() {
    QTemporaryDir home;
    Shell shell(home.path());
    QList<FakeMc::Rpc> launches;
    shell.mc.onRpc(QStringLiteral("orchestration.launchThread"), [&launches](const FakeMc::Rpc& rpc) { launches.append(rpc); });
    HAL_C2_TRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    const QString draftId = shell.native->controller<DraftController>()->start(shell.mc.environmentId, QStringLiteral("p1"));
    QVERIFY(!draftId.isEmpty());
    shell.bridge->dispatch(QStringLiteral("draft.open"), QVariantMap{{QStringLiteral("draftId"), draftId}});
    HAL_C2_TRY_COMPARE(shell.bridge->state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")).toString(), draftId);
    shell.bridge->dispatch(QStringLiteral("composer.text.set"), QVariantMap{{QStringLiteral("target"), draftId},
                                                                           {QStringLiteral("edit"), shell.edit()},
                                                                           {QStringLiteral("text"), QStringLiteral("start here")},
                                                                           {QStringLiteral("cursor"), 10}});
    shell.submit(QStringLiteral("start here"));
    HAL_C2_TRY_COMPARE(launches.size(), 1);
    QCOMPARE(shell.composer()->draft(draftId), QString());

    QVERIFY(shell.restart(false));
    HAL_C2_TRY_COMPARE(shell.composer()->draft(draftId), QStringLiteral("start here"));
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/composer-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  ComposerRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_ComposerRegression.moc"
