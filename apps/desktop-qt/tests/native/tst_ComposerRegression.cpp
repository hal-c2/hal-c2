// What tests/prop/tst_ComposerProp.cpp and tst_ComposerPureProp.cpp found in
// the composer.

#include <QtTest>

#include "ComposerController.h"
#include "ComposerModel.h"
#include "DraftController.h"
#include "FakeFiles.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NavigationController.h"
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
          {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), QStringLiteral("gpt-a")}},
                                            QJsonObject{{QStringLiteral("slug"), QStringLiteral("gpt-b")}}}},
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
      for (const QJsonObject& session : sessions) {
        rows.append(QJsonArray{QStringLiteral("provider-session"), session.value(QLatin1String("id")), session});
      }
      for (const QJsonObject& run : runs.value(shape.value(QLatin1String("stream")).toString())) {
        rows.append(QJsonArray{QStringLiteral("run"), run.value(QLatin1String("id")), run});
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

  QVariantMap composerState() const { return bridge->state()->value(QStringLiteral("composer")).toMap(); }

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
  // The thread's provider sessions, as its stream sends them.
  QList<QJsonObject> sessions;
  // Each thread's runs, as its stream's snapshot sends them.
  QHash<QString, QList<QJsonObject>> runs;
  // While set, what the MC answers never reached it.
  bool losing = false;
};

}  // namespace

class ComposerRegression : public QObject {
  Q_OBJECT

private slots:
  // Prompt recall skipped only a message with a scheduledTaskId, so an older
  // MC's or a T3 import's scheduled-task message (the task in the item's id and
  // a "[Triggered by schedule task: ...]" prefix, sent by "user") was recalled.
  void anOlderMcsScheduledTaskMessageIsSentByAutomation() {
    const QJsonObject legacy{{QStringLiteral("id"), QStringLiteral("scheduled-task-message:task-1:2:scheduled")},
                             {QStringLiteral("createdBy"), QStringLiteral("user")},
                             {QStringLiteral("text"), QStringLiteral("[Triggered by schedule task: Nightly]\n\nRun it")}};
    QVERIFY(TimelineModel::sentByScheduledTask(legacy));
    QVERIFY(TimelineModel::sentByScheduledTask(QJsonObject{{QStringLiteral("scheduledTaskId"), QStringLiteral("task-1")}}));
    // A user who typed the prefix themselves wrote it.
    QVERIFY(!TimelineModel::sentByScheduledTask(
        QJsonObject{{QStringLiteral("id"), QStringLiteral("message:run-1")}, {QStringLiteral("text"), legacy.value(QStringLiteral("text"))}}));
  }

  // The picker's "Ultrathink:" prefix was stripped whatever its case, so a
  // typed "ultrathink: design the cache" neither showed Ultrathink nor locked
  // the effort, though Claude still read the word. Only the picker's own
  // capitalised prefix is its; any other is the user's word.
  void aTypedLowercaseUltrathinkPrefixIsTheUsersWord() {
    QVERIFY(composer::ultrathinkInWords(QStringLiteral("ultrathink: design the cache")));
    QVERIFY(!composer::ultrathinkInWords(QStringLiteral("Ultrathink:\ndesign the cache")));
    QVERIFY(composer::ultrathinkInWords(QStringLiteral("Ultrathink:\nplease ultrathink about it")));
  }

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

  // A slash after other text opened the menu for any word, matched fuzzily and
  // against descriptions, so Enter after "summarise /thread" took /model (its
  // description says "this thread") and the message was not sent. Mid-line a
  // word must start a name, and one that starts none opens no menu; spaces
  // before a line's slash still make it the line's command.
  void aSlashWordInASentenceThatStartsNoNameIsProse() {
    const composer::Trigger thread{QStringLiteral("slash-command"), QStringLiteral("thread"), 10, 17, true};
    QVERIFY(composer::slashItems(nullptr, thread, true, true, false).isEmpty());
    QVERIFY(!composer::slashItems(nullptr, {thread.kind, thread.query, 0, 7, false}, true, true, false).isEmpty());
    QCOMPARE(composer::slashItems(nullptr, {thread.kind, QStringLiteral("pl"), 4, 7, true}, true, true, false).size(), 1);

    const auto spaced = composer::trigger(QStringLiteral("  /compact"), 10);
    QVERIFY(spaced);
    QCOMPARE(spaced->start, 0);
    QCOMPARE(spaced->midLine, false);

    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    const auto shown = [&shell] { return shell.bridge->state()->value(QStringLiteral("composer")).toMap(); };
    shell.type(QStringLiteral("summarise /thread"));
    QTRY_COMPARE(shown().value(QStringLiteral("text")).toString(), QStringLiteral("summarise /thread"));
    QVERIFY(shown().value(QStringLiteral("triggerKind")).toString().isEmpty());
    QVERIFY(shown().value(QStringLiteral("suggestions")).toList().isEmpty());
    shell.type(QStringLiteral("summarise /mo"));
    QTRY_COMPARE(shown().value(QStringLiteral("text")).toString(), QStringLiteral("summarise /mo"));
    QCOMPARE(shown().value(QStringLiteral("triggerKind")).toString(), QStringLiteral("slash-command"));
    QCOMPARE(shown().value(QStringLiteral("suggestions")).toList().value(0).toMap().value(QStringLiteral("id")).toString(),
             QStringLiteral("slash:model"));
  }

  // The menu labels skills "/skill:<name>", so a word typed toward that label
  // keeps the mid-line menu open rather than closing it mid-word.
  void aSlashWordTypedTowardTheSkillLabelKeepsTheMenuOpen() {
    const QJsonObject review{{QStringLiteral("name"), QStringLiteral("review")}, {QStringLiteral("enabled"), true}};
    composer::Instance instance;
    instance.driver = QStringLiteral("claudeAgent");
    instance.skills = QJsonArray{review};
    for (const char* word : {"ski", "skill", "skill:", "skill:rev"}) {
      const composer::Trigger t{QStringLiteral("slash-command"), QString::fromLatin1(word), 10, 10 + 1 + int(strlen(word)), true};
      bool offersReview = false;
      for (const auto& s : composer::slashItems(&instance, t, true, true, false)) offersReview |= s.label == QLatin1String("/skill:review");
      QVERIFY2(offersReview, word);
    }
    // Too short to be heading for the label: "/s" ends a sentence.
    for (const char* word : {"s", "sk"}) {
      const composer::Trigger t{QStringLiteral("slash-command"), QString::fromLatin1(word), 10, 10 + 1 + int(strlen(word)), true};
      QVERIFY2(composer::slashItems(&instance, t, true, true, false).isEmpty(), word);
    }
    const composer::Trigger other{QStringLiteral("slash-command"), QStringLiteral("skx"), 10, 14, true};
    QVERIFY(composer::slashItems(&instance, other, true, true, false).isEmpty());
  }

  // A bare `@` opened no menu. It is never searched, so the menu opens at
  // once and says nothing matches, as the web's did; a word after it says it
  // is searching until its search answers.
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
    QCOMPARE(shown().value(QStringLiteral("suggestionsEmptyText")).toString(), QStringLiteral("Searching workspace files..."));
    shell.mc.answerHeld();
    QTRY_COMPARE(shown().value(QStringLiteral("suggestionsEmptyText")).toString(), QStringLiteral("No matching files or folders."));
  }

  // The @ menu said nothing at all for a word it could not search, and never
  // asked again when the environment returned.
  void theAtMenuSaysItCannotSearchAndAsksAgainOnReturn() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    const auto emptyText = [&shell] {
      return shell.bridge->state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("suggestionsEmptyText"));
    };
    FakeFiles& files = fakeFiles(shell.mc);
    const QString environment = shell.mc.environmentId;

    shell.mc.setOnline(environment, false);
    QTRY_VERIFY(!shell.native->store()->environmentOnline(environment));
    shell.type(QStringLiteral("@src"));
    QTRY_COMPARE(emptyText().toString(), QStringLiteral("Can't search files right now."));
    QCOMPARE(files.searches, 0);

    shell.mc.setOnline(environment, true);
    QTRY_COMPARE(files.searches, 1);
    QTRY_COMPARE(emptyText().toString(), QStringLiteral("No matching files or folders."));
  }

  // A dropped connection failed the search, which then claimed nothing matched
  // and was not asked again after the reconnect.
  void aSearchLostWithTheConnectionIsAskedAgain() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    const auto emptyText = [&shell] {
      return shell.bridge->state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("suggestionsEmptyText"));
    };
    FakeFiles& files = fakeFiles(shell.mc);
    shell.mc.hold(QStringLiteral("search"));
    shell.type(QStringLiteral("@src"));
    QTRY_COMPARE(files.searches, 1);
    shell.mc.dropHeld();

    shell.mc.drop();
    QTRY_COMPARE(files.searches, 2);
    QTRY_COMPARE(emptyText().toString(), QStringLiteral("No matching files or folders."));
  }

  // A search the MC refuses says so rather than that nothing matched, though
  // the connection and the environment stayed up.
  void aRefusedSearchSaysItCannotSearch() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    shell.mc.onRpc(QStringLiteral("projects.searchEntries"), [&shell](const FakeMc::Rpc& rpc) {
      shell.mc.refuse(rpc, QStringLiteral("no such folder"));
    });
    shell.type(QStringLiteral("@src"));
    QTRY_COMPARE(shell.composerState().value(QStringLiteral("suggestionsEmptyText")).toString(),
                 QStringLiteral("Can't search files right now."));
  }

  // A route with no workspace says it cannot search, and answers once the
  // project's folder is known.
  void aRouteWithNoWorkspaceSaysItCannotSearch() {
    QTemporaryDir home;
    Shell shell(home.path());
    QJsonObject project = shell.mc.projects.value(QStringLiteral("p1"));
    shell.mc.projects[QStringLiteral("p1")].remove(QStringLiteral("workspaceRoot"));
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    FakeFiles& files = fakeFiles(shell.mc);
    shell.type(QStringLiteral("@src"));
    QTRY_COMPARE(shell.composerState().value(QStringLiteral("suggestionsEmptyText")).toString(),
                 QStringLiteral("Can't search files right now."));
    QCOMPARE(files.searches, 0);

    shell.mc.sendRow(QStringLiteral("p1"), project, QStringLiteral("project"));
    QTRY_COMPARE(files.searches, 1);
    QTRY_COMPARE(shell.composerState().value(QStringLiteral("suggestionsEmptyText")).toString(),
                 QStringLiteral("No matching files or folders."));
  }

  // The same word stayed on the checkout it was first searched in after the
  // route moved to another.
  void aMovedCheckoutAsksTheSameWordAgain() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    FakeFiles& files = fakeFiles(shell.mc);
    shell.type(QStringLiteral("@src"));
    QTRY_COMPARE(files.searches, 1);

    QJsonObject row = shell.mc.threads.value(QStringLiteral("t1"));
    row.insert(QStringLiteral("worktreePath"), QStringLiteral("/work/worktrees/other"));
    shell.mc.sendRow(QStringLiteral("t1"), row);
    QTRY_COMPARE(files.searches, 2);
  }

  // Moving a thread while one of its queued messages was being edited carried
  // the queued message's text to the other machine as the thread's draft, and
  // the draft the user had set aside for the edit was lost. The edit now ends
  // first, so the set-aside draft is what moves.
  void aMovedThreadTakesTheDraftSetAsideForItsQueuedEdit() {
    QTemporaryDir home;
    Shell shell(home.path());
    shell.messages[QStringLiteral("t1")].append(QJsonObject{{QStringLiteral("id"), QStringLiteral("message:q")},
                                                            {QStringLiteral("role"), QStringLiteral("user")},
                                                            {QStringLiteral("createdBy"), QStringLiteral("user")},
                                                            {QStringLiteral("text"), QStringLiteral("queued text")},
                                                            {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T10:00:00.000Z")}});
    shell.runs[QStringLiteral("t1")].append(QJsonObject{{QStringLiteral("id"), QStringLiteral("run-q")},
                                                        {QStringLiteral("status"), QStringLiteral("queued")},
                                                        {QStringLiteral("queuePosition"), 0},
                                                        {QStringLiteral("userMessageId"), QStringLiteral("message:q")}});
    QVERIFY(QTest::qWaitFor([&] { return shell.native->store()->threadOnline(shell.key); }));
    QVERIFY(shell.open());
    shell.type(QStringLiteral("my own draft"));
    QVERIFY(QTest::qWaitFor([&] { return shell.composer()->draft(shell.key) == QLatin1String("my own draft"); }));
    shell.bridge->dispatch(QStringLiteral("composer.queue.edit"), QVariantMap{{QStringLiteral("runId"), QStringLiteral("run-q")}});
    QVERIFY(QTest::qWaitFor([&] { return shell.composerState().value(QStringLiteral("text")).toString() == QLatin1String("queued text"); }));

    QJsonObject row = shell.mc.threads.value(QStringLiteral("t1"));
    row.insert(QStringLiteral("movedTo"), QJsonObject{{QStringLiteral("environmentId"), QStringLiteral("env-b")}, {QStringLiteral("mc"), QStringLiteral("mc-b")}});
    shell.mc.threads.insert(QStringLiteral("t1"), row);
    shell.mc.sendRow(QStringLiteral("t1"), row);
    const QString there = QStringLiteral("env-b:t1");
    QVERIFY(QTest::qWaitFor([&] { return shell.composer()->draft(there) == QLatin1String("my own draft"); }));
    QVERIFY(shell.composerState().value(QStringLiteral("editingQueuedRunId")).isNull());
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

  // A queued message with attachments listed only its text, so the card
  // showed none of them; each row now carries its message and attachments.
  void aQueuedRowCarriesItsAttachments() {
    const QJsonObject run{{QStringLiteral("id"), QStringLiteral("run-a")}, {QStringLiteral("status"), QStringLiteral("queued")},
                          {QStringLiteral("queuePosition"), 0}, {QStringLiteral("userMessageId"), QStringLiteral("message:a")}};
    const QJsonArray attachments{
        QJsonObject{{QStringLiteral("id"), QStringLiteral("shot")}, {QStringLiteral("type"), QStringLiteral("image")},
                    {QStringLiteral("name"), QStringLiteral("shot.png")}, {QStringLiteral("mimeType"), QStringLiteral("image/png")}},
        QJsonObject{{QStringLiteral("id"), QStringLiteral("notes")}, {QStringLiteral("type"), QStringLiteral("file")},
                    {QStringLiteral("name"), QStringLiteral("notes.md")}, {QStringLiteral("mimeType"), QStringLiteral("text/markdown")}}};
    const composer::Queued queued = composer::queued(
        {run}, {{QStringLiteral("message:a"),
                 {{QStringLiteral("id"), QStringLiteral("message:a")}, {QStringLiteral("text"), QString()},
                  {QStringLiteral("attachments"), attachments}}}});
    QCOMPARE(queued.queue.size(), 1);
    const QVariantMap row = queued.queue.first().toMap();
    QCOMPARE(row.value(QStringLiteral("messageId")).toString(), QStringLiteral("message:a"));
    const QVariantList shown = row.value(QStringLiteral("attachments")).toList();
    QCOMPARE(shown.size(), 2);
    QCOMPARE(shown.at(0).toMap().value(QStringLiteral("kind")).toString(), QStringLiteral("image"));
    QCOMPARE(shown.at(1).toMap().value(QStringLiteral("kind")).toString(), QStringLiteral("file"));
    QCOMPARE(shown.at(1).toMap().value(QStringLiteral("name")).toString(), QStringLiteral("notes.md"));
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

  // The MC's answers can beat the rows they changed: a second pick the MC took
  // still shows while the row holds the first, or neither.
  void anAccessChangeAnsweredBeforeItsRowStillShows() {
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
    shell.mc.lagRows = true;
    shell.mc.hold(QStringLiteral("answers"));
    pick(QStringLiteral("approval-required"));
    pick(QStringLiteral("auto-accept-edits"));
    QTRY_COMPARE(shell.mc.commands.size(), 2);
    shell.mc.answerHeld();
    // The answers went first: the row with the first pick comes after them.
    shell.mc.catchUp(1);
    QTRY_COMPARE(shell.native->store()->thread(shell.key)->runtimeMode, QStringLiteral("approval-required"));
    QCOMPARE(shown(), QStringLiteral("auto-accept-edits"));

    shell.mc.catchUp();
    QTRY_COMPARE(shell.native->store()->thread(shell.key)->runtimeMode, QStringLiteral("auto-accept-edits"));
    QCOMPARE(shown(), QStringLiteral("auto-accept-edits"));
  }

  // A thread that named no provider was switched to the composer's model on
  // its first send, a provider.switch the user never asked for, ahead of the
  // message. The message's own model is what the MC runs it on.
  void aThreadWithNoProviderIsNotSwitchedOnItsFirstSend() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    QVERIFY(shell.native->store()->thread(shell.key)->modelSelection.isEmpty());
    shell.type(QStringLiteral("first prompt"));
    shell.submit(QStringLiteral("first prompt"));
    QTRY_COMPARE(shell.dispatched(), 1);
    QStringList types;
    for (const QJsonObject& command : std::as_const(shell.mc.commands)) types.append(command.value(QLatin1String("type")).toString());
    QCOMPARE(types, QStringList{QStringLiteral("message.dispatch")});
    const QJsonObject message = shell.mc.commands.constLast();
    QCOMPARE(message.value(QLatin1String("modelSelection")).toObject().value(QLatin1String("instanceId")).toString(), QStringLiteral("codex"));
  }

  // A model picked in a started thread's draft stayed the draft's after the
  // thread ran on it, so a model another client set later never showed here.
  void aPickTheThreadTookFollowsAChangeFromElsewhere() {
    QTemporaryDir home;
    Shell shell(home.path());
    const auto runOn = [&](const QString& slug) {
      QJsonObject row = shell.mc.threads.value(QStringLiteral("t1"));
      row.insert(QStringLiteral("modelSelection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), slug}});
      shell.mc.threads.insert(QStringLiteral("t1"), row);
      shell.mc.sendRow(QStringLiteral("t1"), row);
    };
    const auto shows = [&] { return shell.composer()->currentSelection().value(QLatin1String("model")).toString(); };
    runOn(QStringLiteral("gpt-a"));
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    QVERIFY(shell.open());
    QTRY_COMPARE(shows(), QStringLiteral("gpt-a"));
    shell.bridge->dispatch(QStringLiteral("composer.model.select"),
                           QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-b")}});
    QTRY_COMPARE(shows(), QStringLiteral("gpt-b"));
    runOn(QStringLiteral("gpt-b"));
    QTRY_VERIFY(shell.native->store()->thread(shell.key)->modelSelection.value(QLatin1String("model")) == QLatin1String("gpt-b"));
    runOn(QStringLiteral("gpt-a"));
    QTRY_COMPARE(shows(), QStringLiteral("gpt-a"));
  }

  // The model and mode a new thread carried into the project's draft counted
  // as the user's own, so a new thread from another thread reopened the draft
  // still showing the first thread's.
  void aNewThreadFromAnotherThreadReplacesWhatTheLastOneCarried() {
    QTemporaryDir home;
    Shell shell(home.path());
    const auto model = [](const QString& slug) {
      return QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), slug}};
    };
    QJsonObject a = shell.mc.threads.value(QStringLiteral("t1"));
    a.insert(QStringLiteral("modelSelection"), model(QStringLiteral("gpt-a")));
    a.insert(QStringLiteral("interactionMode"), QStringLiteral("plan"));
    shell.mc.threads.insert(QStringLiteral("t1"), a);
    QJsonObject b = a;
    b.insert(QStringLiteral("id"), QStringLiteral("t2"));
    b.insert(QStringLiteral("title"), QStringLiteral("t2"));
    b.insert(QStringLiteral("modelSelection"), model(QStringLiteral("gpt-b")));
    b.insert(QStringLiteral("interactionMode"), QStringLiteral("default"));
    shell.mc.threads.insert(QStringLiteral("t2"), b);
    QVERIFY(shell.restart(true));
    QVERIFY(shell.native->controller<SettingsController>()->writeDevice(QStringLiteral("planModeEnabled"), true));
    const auto shows = [&](const QString& slug, const QString& mode) {
      return shell.composer()->currentSelection().value(QLatin1String("model")).toString() == slug &&
             shell.composerState().value(QStringLiteral("interactionMode")).toString() == mode;
    };
    const auto draftOpen = [&] { return shell.native->controller<NavigationController>()->route().draftId; };

    QVERIFY(shell.open());
    shell.bridge->dispatch(QStringLiteral("thread.new"), QVariantMap{});
    QTRY_VERIFY(!draftOpen().isEmpty());
    const QString draftId = draftOpen();
    QTRY_VERIFY(shows(QStringLiteral("gpt-a"), QStringLiteral("plan")));

    shell.key = QStringLiteral("env-a:t2");
    QVERIFY(shell.open());
    shell.bridge->dispatch(QStringLiteral("thread.new"), QVariantMap{});
    QTRY_COMPARE(draftOpen(), draftId);
    QTRY_VERIFY(shows(QStringLiteral("gpt-b"), QStringLiteral("default")));

    // A pick there is the user's: the next new thread keeps it.
    shell.bridge->dispatch(QStringLiteral("composer.interactionMode.set"), QVariantMap{{QStringLiteral("mode"), QStringLiteral("plan")}});
    QTRY_VERIFY(shows(QStringLiteral("gpt-b"), QStringLiteral("plan")));
    shell.key = QStringLiteral("env-a:t1");
    QVERIFY(shell.open());
    shell.bridge->dispatch(QStringLiteral("thread.new"), QVariantMap{});
    QTRY_COMPARE(draftOpen(), draftId);
    QTRY_VERIFY(shows(QStringLiteral("gpt-b"), QStringLiteral("plan")));
  }

  // Sessions are keyed per instance and a provider switch keeps the old
  // one, so a thread that moved from a non-steering provider to Codex held
  // both sessions and canSteerActive read them all: the old session alone
  // forced Queue for good. Only the current instance's session matters.
  void aSwitchedThreadsOldSessionDoesNotBlockSteering() {
    QTemporaryDir home;
    Shell shell(home.path());
    const auto session = [](const QString& instance, bool steers) {
      return QJsonObject{
          {QStringLiteral("id"), QStringLiteral("provider-session:%1:t1").arg(instance)},
          {QStringLiteral("providerInstanceId"), instance},
          {QStringLiteral("status"), QStringLiteral("ready")},
          {QStringLiteral("capabilities"),
           QJsonObject{{QStringLiteral("turns"), QJsonObject{{QStringLiteral("supportsActiveSteering"), steers}}}}}};
    };
    shell.sessions = {session(QStringLiteral("antigravity"), false), session(QStringLiteral("codex"), true)};
    const auto onInstance = [&](const QString& instance) {
      QJsonObject row = shell.mc.threads.value(QStringLiteral("t1"));
      row.insert(QStringLiteral("modelSelection"),
                 QJsonObject{{QStringLiteral("instanceId"), instance}, {QStringLiteral("model"), QStringLiteral("gpt-a")}});
      shell.mc.threads.insert(QStringLiteral("t1"), row);
      shell.mc.sendRow(QStringLiteral("t1"), row);
    };
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    onInstance(QStringLiteral("codex"));
    QVERIFY(shell.open());
    QTRY_COMPARE(shell.composerState().value(QStringLiteral("canSteer")).toBool(), true);

    // On the non-steering instance the same two sessions refuse steering.
    onInstance(QStringLiteral("antigravity"));
    QTRY_COMPARE(shell.composerState().value(QStringLiteral("canSteer")).toBool(), false);
  }

  // Taking a carried thread's chip off dropped its record but left the
  // [@title](hal-c2-context://v1/thread/...) link selectSuggestion put in
  // the draft, so the send carried a link with no record behind it.
  void removingAThreadChipStripsItsLinkFromTheDraft() {
    QTemporaryDir home;
    Shell shell(home.path());
    QJsonObject other = shell.mc.threads.value(QStringLiteral("t1"));
    other.insert(QStringLiteral("id"), QStringLiteral("t2"));
    other.insert(QStringLiteral("title"), QStringLiteral("Other thread"));
    shell.mc.threads.insert(QStringLiteral("t2"), other);
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    shell.mc.sendRow(QStringLiteral("t2"), other);
    QVERIFY(shell.open());
    shell.type(QStringLiteral("look @"));
    QTRY_VERIFY(std::any_of(shell.composerState().value(QStringLiteral("suggestions")).toList().cbegin(),
                            shell.composerState().value(QStringLiteral("suggestions")).toList().cend(), [](const QVariant& entry) {
                              return entry.toMap().value(QStringLiteral("id")).toString() == QLatin1String("thread:env-a:t2");
                            }));
    shell.bridge->dispatch(QStringLiteral("composer.suggest.select"),
                           QVariantMap{{QStringLiteral("id"), QStringLiteral("thread:env-a:t2")}});
    QTRY_COMPARE(shell.composerState().value(QStringLiteral("threadContexts")).toList().size(), 1);
    QVERIFY(shell.composerState().value(QStringLiteral("text")).toString().contains(
        QStringLiteral("[@Other thread](hal-c2-context://v1/thread/thread_")));
    const auto chipId = [&shell] {
      return shell.composerState()
          .value(QStringLiteral("threadContexts"))
          .toList()
          .constFirst()
          .toMap()
          .value(QStringLiteral("id"))
          .toString();
    };
    const auto place = [&shell](const QString& text, int cursor) {
      shell.bridge->dispatch(QStringLiteral("composer.text.set"), QVariantMap{{QStringLiteral("target"), shell.key},
                                                                               {QStringLiteral("edit"), shell.edit()},
                                                                               {QStringLiteral("text"), text},
                                                                               {QStringLiteral("cursor"), cursor}});
    };
    // More words after the link, the caret among them: stripping the link
    // before the caret shifts it back by the link's length, not forward
    // into the words after it.
    const QString linked = shell.composerState().value(QStringLiteral("text")).toString();
    place(linked + QStringLiteral("please and more"), int(linked.size()) + 6);
    QTRY_COMPARE(shell.composerState().value(QStringLiteral("cursor")).toInt(), int(linked.size()) + 6);

    // What the chip's click sends (Composer.qml).
    shell.bridge->dispatch(QStringLiteral("composer.terminalContext.remove"), QVariantMap{{QStringLiteral("id"), chipId()}});
    QTRY_COMPARE(shell.composerState().value(QStringLiteral("threadContexts")).toList().size(), 0);
    QTRY_COMPARE(shell.composerState().value(QStringLiteral("text")).toString(), QStringLiteral("look please and more"));
    QCOMPARE(shell.composerState().value(QStringLiteral("cursor")).toInt(), int(QStringLiteral("look please").size()));

    // Again, with the caret inside the link: it lands where the link started.
    place(QStringLiteral("look please @ and more"), 13);
    QTRY_VERIFY(std::any_of(shell.composerState().value(QStringLiteral("suggestions")).toList().cbegin(),
                            shell.composerState().value(QStringLiteral("suggestions")).toList().cend(), [](const QVariant& entry) {
                              return entry.toMap().value(QStringLiteral("id")).toString() == QLatin1String("thread:env-a:t2");
                            }));
    shell.bridge->dispatch(QStringLiteral("composer.suggest.select"),
                           QVariantMap{{QStringLiteral("id"), QStringLiteral("thread:env-a:t2")}});
    QTRY_COMPARE(shell.composerState().value(QStringLiteral("threadContexts")).toList().size(), 1);
    const QString relinked = shell.composerState().value(QStringLiteral("text")).toString();
    place(relinked, int(relinked.indexOf(QStringLiteral("[@"))) + 3);
    shell.bridge->dispatch(QStringLiteral("composer.terminalContext.remove"), QVariantMap{{QStringLiteral("id"), chipId()}});
    QTRY_COMPARE(shell.composerState().value(QStringLiteral("text")).toString(), QStringLiteral("look please and more"));
    QCOMPARE(shell.composerState().value(QStringLiteral("cursor")).toInt(), int(QStringLiteral("look please").size()));
  }

  // On an environment without file attachments, the refusal also caught a
  // large paste: turned into pasted-text.txt it has no base64, so it was
  // skipped with a toast and the pasted words were lost. They go inline.
  void aLargePasteGoesInlineWhereFilesAreRefused() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->isActive() && shell.native->store()->threadOnline(shell.key));
    shell.mc.capabilities.remove(QStringLiteral("fileAttachments"));
    shell.mc.announceEnvironment();
    QTRY_VERIFY(!shell.native->store()->acceptsFileAttachments(QStringLiteral("env-a")));
    QVERIFY(shell.open());
    shell.type(QStringLiteral("before "));
    const auto attach = [&shell](const QVariantMap& file) {
      shell.bridge->dispatch(QStringLiteral("composer.attach"), QVariantMap{{QStringLiteral("files"), QVariantList{file}}});
    };
    const auto toastTitles = [&shell] {
      QStringList titles;
      for (const QVariant& toast : shell.bridge->state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
        titles.append(toast.toMap().value(QStringLiteral("title")).toString());
      }
      return titles;
    };
    attach({{QStringLiteral("name"), QStringLiteral("pasted-text.txt")},
            {QStringLiteral("mimeType"), QStringLiteral("text/plain")},
            {QStringLiteral("text"), QStringLiteral("a very long paste")}});
    QTRY_COMPARE(shell.composerState().value(QStringLiteral("text")).toString(), QStringLiteral("before a very long paste"));
    QCOMPARE(shell.composerState().value(QStringLiteral("attachments")).toList().size(), 0);
    QVERIFY(!toastTitles().contains(QStringLiteral("File not attached")));

    // A chosen file is still refused, and the draft keeps its words.
    attach({{QStringLiteral("name"), QStringLiteral("notes.bin")}, {QStringLiteral("path"), QStringLiteral("/work/shop/notes.bin")}});
    QTRY_VERIFY(toastTitles().contains(QStringLiteral("File not attached")));
    QCOMPARE(shell.composerState().value(QStringLiteral("text")).toString(), QStringLiteral("before a very long paste"));
    QCOMPARE(shell.composerState().value(QStringLiteral("attachments")).toList().size(), 0);
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
