// What tests/prop/tst_ComposerProp.cpp and tst_ComposerPureProp.cpp found in
// the composer.

#include <QtTest>

#include "ComposerController.h"
#include "ComposerModel.h"
#include "DraftController.h"
#include "FakeFiles.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "ToastController.h"

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
    if (!QTest::qWaitFor([this] { return !mc.connected(); })) return false;
    losing = !received;
    mc.answerHeld();
    losing = false;
    start();
    return QTest::qWaitFor([this] { return native->isActive() && native->store()->threadOnline(key); });
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
    return QTest::qWaitFor([this] {
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

  // A bare `@` opened no menu. It is never searched, so the menu opens at
  // once and says nothing matches, as the web's did; a word after it waits for
  // its search to answer before saying so.
  void aBareAtOpensTheMenuSayingNothingMatches() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    const auto shown = [&shell] { return shell.bridge->state()->value(QStringLiteral("composer")).toMap(); };
    // The workspace has no files, and its search answers when the test says.
    fakeFiles(shell.mc);
    shell.mc.hold(QStringLiteral("search"));

    shell.type(QStringLiteral("@"));
    QTRY_COMPARE(shown().value(QStringLiteral("text")).toString(), QStringLiteral("@"));
    QCOMPARE(shown().value(QStringLiteral("triggerKind")).toString(), QStringLiteral("path"));
    QCOMPARE(shown().value(QStringLiteral("suggestionsEmptyText")).toString(), QStringLiteral("No matching files or folders."));

    shell.type(QStringLiteral("@src"));
    QTRY_COMPARE(shown().value(QStringLiteral("text")).toString(), QStringLiteral("@src"));
    QCOMPARE(shown().value(QStringLiteral("triggerKind")).toString(), QStringLiteral("path"));
    QVERIFY(shown().value(QStringLiteral("suggestionsEmptyText")).isNull());
    shell.mc.answerHeld();
    QTRY_COMPARE(shown().value(QStringLiteral("suggestionsEmptyText")).toString(), QStringLiteral("No matching files or folders."));
  }

  // A queued run that arrived before its message was listed as a blank row;
  // it now waits off the list until the message is here.
  void aQueuedRunWithoutItsMessageIsNotListed() {
    const QJsonObject run{{QStringLiteral("id"), QStringLiteral("run-a")},
                          {QStringLiteral("status"), QStringLiteral("queued")},
                          {QStringLiteral("queueHeld"), true},
                          {QStringLiteral("queuePosition"), 0},
                          {QStringLiteral("userMessageId"), QStringLiteral("message:a")}};
    const composer::Queued early = composer::queued({run}, {});
    QVERIFY(early.queue.isEmpty());
    QVERIFY(early.waiting.isEmpty());
    // The queue is held all the same; the turn shows it only with a run listed.
    QVERIFY(early.held);

    const composer::Queued later = composer::queued(
        {run}, {{QStringLiteral("message:a"),
                 {{QStringLiteral("id"), QStringLiteral("message:a")}, {QStringLiteral("text"), QStringLiteral("also update docs")}}}});
    QCOMPARE(later.queue.size(), 1);
    QCOMPARE(later.queue.first().toMap().value(QStringLiteral("text")).toString(), QStringLiteral("also update docs"));
    QVERIFY(later.held);
  }

  // A held run whose message has not landed yet, beside a listed run that is
  // not held: the queue is held, so the card offers "Resume" at once.
  void aHeldRunWithoutItsMessageHoldsTheListedQueue() {
    const QJsonObject early{{QStringLiteral("id"), QStringLiteral("run-a")}, {QStringLiteral("status"), QStringLiteral("queued")},
                            {QStringLiteral("queueHeld"), true}, {QStringLiteral("queuePosition"), 0},
                            {QStringLiteral("userMessageId"), QStringLiteral("message:a")}};
    const QJsonObject listed{{QStringLiteral("id"), QStringLiteral("run-b")}, {QStringLiteral("status"), QStringLiteral("queued")},
                             {QStringLiteral("queueHeld"), false}, {QStringLiteral("queuePosition"), 1},
                             {QStringLiteral("userMessageId"), QStringLiteral("message:b")}};
    const composer::Queued queued = composer::queued(
        {early, listed}, {{QStringLiteral("message:b"),
                           {{QStringLiteral("id"), QStringLiteral("message:b")}, {QStringLiteral("text"), QStringLiteral("then this")}}}});
    QCOMPARE(queued.queue.size(), 1);
    QVERIFY(queued.held);
  }

  // A held queue whose only listed runs wait on a notification or a provider
  // wake (no user message) is held all the same: those runs have no other way
  // on, so `queued()` lists them as waiting and turnState offers the resume.
  void aHeldWaitingOnlyQueueIsHeld() {
    const QJsonObject wake{{QStringLiteral("id"), QStringLiteral("run-a")}, {QStringLiteral("status"), QStringLiteral("queued")},
                           {QStringLiteral("queueHeld"), true}, {QStringLiteral("queuePosition"), 0},
                           {QStringLiteral("userMessageId"), QStringLiteral("message:a")}};
    const composer::Queued woken = composer::queued(
        {wake}, {{QStringLiteral("message:a"),
                  {{QStringLiteral("id"), QStringLiteral("message:a")}, {QStringLiteral("providerWake"), true}}}});
    QVERIFY(woken.queue.isEmpty());
    QCOMPARE(woken.waiting.size(), 1);
    QVERIFY(woken.held);

    const QJsonObject note{{QStringLiteral("id"), QStringLiteral("run-b")}, {QStringLiteral("status"), QStringLiteral("queued")},
                           {QStringLiteral("queueHeld"), true}, {QStringLiteral("queuePosition"), 0},
                           {QStringLiteral("userMessageId"), QStringLiteral("message:b")}};
    const composer::Queued notified = composer::queued(
        {note}, {{QStringLiteral("message:b"),
                  {{QStringLiteral("id"), QStringLiteral("message:b")},
                   {QStringLiteral("notification"),
                    QJsonObject{{QStringLiteral("summary"), QStringLiteral("Task done")}, {QStringLiteral("outcome"), QStringLiteral("success")}}}}}});
    QVERIFY(notified.queue.isEmpty());
    QCOMPARE(notified.waiting.size(), 1);
    QVERIFY(notified.held);
  }

  // A send the MC refused came back only into an empty draft: when the user
  // had typed something newer meanwhile, the refused prompt was gone. It is
  // now kept behind the toast's "Restore prompt".
  void aRefusedPromptBehindNewerTypingCanBeRestored() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());

    shell.mc.hold(QStringLiteral("answers"));
    shell.mc.refusals.insert(QStringLiteral("message.dispatch"), QStringLiteral("The thread is busy."));
    shell.type(QStringLiteral("first prompt"));
    shell.submit(QStringLiteral("first prompt"));
    QTRY_COMPARE(shell.dispatched(), 1);
    QCOMPARE(shell.composer()->draft(shell.key), QString());
    shell.type(QStringLiteral("newer"));
    shell.mc.answerHeld();

    auto* toasts = shell.native->controller<ToastController>();
    QTRY_VERIFY(shell.offersRestore());
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
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    shell.mc.hold(QStringLiteral("answers"));
    shell.type(QStringLiteral("first prompt"));
    shell.submit(QStringLiteral("first prompt"));
    QTRY_COMPARE(shell.dispatched(), 1);
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
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    shell.mc.hold(QStringLiteral("answers"));
    shell.type(QStringLiteral("first prompt"));
    shell.submit(QStringLiteral("first prompt"));
    QTRY_COMPARE(shell.dispatched(), 1);

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
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    shell.mc.hold(QStringLiteral("answers"));
    shell.type(QStringLiteral("first prompt"));
    shell.submit(QStringLiteral("first prompt"));
    QTRY_COMPARE(shell.dispatched(), 1);
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
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    shell.mc.hold(QStringLiteral("answers"));
    shell.type(QStringLiteral("first prompt"));
    shell.submit(QStringLiteral("first prompt"));
    QTRY_COMPARE(shell.dispatched(), 1);
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
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    const QString draftId = shell.native->controller<DraftController>()->start(shell.mc.environmentId, QStringLiteral("p1"));
    QVERIFY(!draftId.isEmpty());
    shell.bridge->dispatch(QStringLiteral("draft.open"), QVariantMap{{QStringLiteral("draftId"), draftId}});
    QTRY_COMPARE(shell.bridge->state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")).toString(), draftId);
    shell.bridge->dispatch(QStringLiteral("composer.text.set"), QVariantMap{{QStringLiteral("target"), draftId},
                                                                           {QStringLiteral("edit"), shell.edit()},
                                                                           {QStringLiteral("text"), QStringLiteral("start here")},
                                                                           {QStringLiteral("cursor"), 10}});
    shell.submit(QStringLiteral("start here"));
    QTRY_COMPARE(launches.size(), 1);
    QCOMPARE(shell.composer()->draft(draftId), QString());

    QVERIFY(shell.restart(false));
    QTRY_COMPARE(shell.composer()->draft(draftId), QStringLiteral("start here"));
  }

  // A pick back to the thread's access while another change is on its way goes
  // too: else that change lands after it and the composer shows the pick back.
  void aPickBackWhileAnAccessChangeIsOnItsWayStillGoes() {
    QTemporaryDir home;
    Shell shell(home.path());
    shell.mc.effects.append([&shell](const QJsonObject& command) {
      if (command.value(QLatin1String("type")) != QLatin1String("thread.runtime-mode.set")) return;
      QJsonObject row = shell.mc.threads.value(QStringLiteral("t1"));
      row.insert(QStringLiteral("runtimeMode"), command.value(QLatin1String("runtimeMode")));
      shell.mc.threads.insert(QStringLiteral("t1"), row);
      shell.mc.sendRow(QStringLiteral("t1"), row);
    });
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    const auto pick = [&shell](const QString& mode) {
      shell.bridge->dispatch(QStringLiteral("composer.runtimeMode.set"), QVariantMap{{QStringLiteral("mode"), mode}});
    };
    const auto shown = [&shell] {
      return shell.bridge->state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("runtimeMode")).toString();
    };
    pick(QStringLiteral("approval-required"));
    QTRY_COMPARE(shell.native->store()->thread(shell.key)->runtimeMode, QStringLiteral("approval-required"));

    shell.mc.hold(QStringLiteral("answers"));
    pick(QStringLiteral("full-access"));
    pick(QStringLiteral("approval-required"));
    QTRY_COMPARE(shell.mc.commands.size(), 3);
    shell.mc.answerHeld();

    QTRY_COMPARE(shell.native->store()->thread(shell.key)->runtimeMode, QStringLiteral("approval-required"));
    QCOMPARE(shown(), QStringLiteral("approval-required"));
  }

  // An access change the MC took settles when the row shows another client's
  // change that came right after it: the composer shows what the thread has.
  void anAccessChangeOverwrittenElsewhereSettles() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    const auto shown = [&shell] {
      return shell.bridge->state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("runtimeMode")).toString();
    };
    shell.mc.hold(QStringLiteral("answers"));
    shell.bridge->dispatch(QStringLiteral("composer.runtimeMode.set"), QVariantMap{{QStringLiteral("mode"), QStringLiteral("approval-required")}});
    QTRY_COMPARE(shell.mc.commands.size(), 1);
    QCOMPARE(shown(), QStringLiteral("approval-required"));

    // Ours and the phone's reach the row as one update: only the phone's shows.
    QJsonObject row = shell.mc.threads.value(QStringLiteral("t1"));
    row.insert(QStringLiteral("runtimeMode"), QStringLiteral("auto-accept-edits"));
    shell.mc.threads.insert(QStringLiteral("t1"), row);
    shell.mc.sendRow(QStringLiteral("t1"), row);
    QTRY_COMPARE(shell.native->store()->thread(shell.key)->runtimeMode, QStringLiteral("auto-accept-edits"));
    QCOMPARE(shown(), QStringLiteral("approval-required"));
    shell.mc.answerHeld();

    QTRY_COMPARE(shown(), QStringLiteral("auto-accept-edits"));
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
