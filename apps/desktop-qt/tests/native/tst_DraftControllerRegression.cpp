// What tests/prop/tst_DraftControllerProp.cpp found about the drafts of a
// machine that leaves the cluster, each as the plain case that shows it
// (hal-c2#1589).

#include <QBuffer>
#include <QImage>
#include <QtTest>

#include "ComposerController.h"
#include "DraftController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"

namespace {

const QString kBox = QStringLiteral("Build box");

// The app on a fake MC that answers Cluster settings, its stores in `home`.
struct Shell {
  explicit Shell(const QString& home) {
    mc.onRpc(QStringLiteral("cluster."), [this](const FakeMc::Rpc& rpc) {
      if (rpc.method == QLatin1String("cluster.remove")) removals.append(rpc);
      else mc.reply(rpc, QJsonObject());
    });
    native = std::make_unique<NativeShell>(&bridge);
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home + QStringLiteral("/state"), home + QStringLiteral("/data"), home + QStringLiteral("/cache"));
    native->controller<SettingsController>()->setDevicePath(home + QStringLiteral("/config/preferences.json"));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
  }

  // The machine joins the cluster with its project, and the shell lists it.
  void join() {
    mc.join(kBox);
    mc.sendPeerRow(kBox, QStringLiteral("ops"),
                   {{QStringLiteral("id"), QStringLiteral("ops")},
                    {QStringLiteral("title"), QStringLiteral("ops")},
                    {QStringLiteral("workspaceRoot"), QStringLiteral("/work/ops")},
                    {QStringLiteral("scripts"), QJsonArray()}},
                   QStringLiteral("project"));
    QTRY_VERIFY(native->store()->project(kBox + QStringLiteral(":ops")));
  }

  DraftController* drafts() const { return native->controller<DraftController>(); }

  QStringList draftsFor(const QString& environment) const {
    QStringList texts;
    for (const DraftController::Draft& draft : drafts()->drafts()) {
      if (draft.environmentId == environment) texts.append(draft.text);
    }
    return texts;
  }

  // The composer's text of `draft` set to `text`, as edit `revision`.
  void write(const QString& draft, const QString& text, int revision) {
    bridge.dispatch(QStringLiteral("composer.text.set"),
                    QVariantMap{{QStringLiteral("target"), draft},
                                {QStringLiteral("edit"), edit(revision)},
                                {QStringLiteral("text"), text},
                                {QStringLiteral("cursor"), int(text.size())}});
  }

  static QVariantMap edit(int revision) {
    return QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), revision}};
  }

  // `text` sent in the background from `draft`, open in the window.
  void sendInBackground(const QString& draft, const QString& text) {
    QTRY_COMPARE(bridge.state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")).toString(), draft);
    write(draft, text, 1);
    bridge.dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("edit"), edit(2)},
                                                                  {QStringLiteral("text"), text},
                                                                  {QStringLiteral("intent"), QStringLiteral("background")}});
  }

  // A draft of the joined machine whose background send of "in the back" the
  // MC refused once the draft held "newer": a toast offers the prompt back.
  // Its id in `offered`.
  void refuseBehindANewerPrompt() {
    QList<FakeMc::Rpc> launches;
    mc.onRpc(QStringLiteral("orchestration.launchThread"), [&launches](const FakeMc::Rpc& rpc) { launches.append(rpc); });
    QTRY_VERIFY(native->client()->isReady() && native->store()->synchronized());
    join();
    offered = drafts()->start(kBox, QStringLiteral("ops"));
    sendInBackground(offered, QStringLiteral("in the back"));
    QTRY_COMPARE(launches.size(), 1);
    mc.onRpc(QStringLiteral("orchestration.launchThread"), [](const FakeMc::Rpc&) {});
    write(offered, QStringLiteral("newer"), 3);
    mc.refuse(launches.takeFirst(), QStringLiteral("no room"));
    barrier();
    QCOMPARE(native->controller<ComposerController>()->draft(offered), QStringLiteral("newer"));
    QVERIFY(native->controller<ComposerController>()->offersLaunch(offered));
  }

  // Whatever the MC has sent so far has reached the shell.
  void barrier() {
    bool done = false;
    native->client()->call(native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    QTRY_VERIFY(done);
  }

  FakeMc mc;
  ShellBridge bridge;
  std::unique_ptr<NativeShell> native;
  QList<FakeMc::Rpc> removals;
  QString offered;
};

}  // namespace

class DraftControllerRegression : public QObject {
  Q_OBJECT

private slots:
  // The MC answers the removal before it tells its shell subscribers the
  // machine went. Dropping the machine's draft on the answer took the window
  // home while the machine's project was still listed, and home lands on a
  // draft of the most recent project: a new, empty one for the machine being
  // removed, which nothing dropped once its rows went.
  void aRemovedMachineKeepsNoDraftWhenTheMcAnswersFirst() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    shell.join();
    const QString draft = shell.drafts()->start(kBox, QStringLiteral("ops"));
    shell.drafts()->setText(draft, QStringLiteral("roll back the deploy"));
    QCOMPARE(shell.native->controller<NavigationController>()->route(), NavigationController::Route::draft(draft));

    shell.bridge.dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), kBox}});
    QTRY_COMPARE(shell.removals.size(), 1);
    shell.mc.reply(shell.removals.takeFirst(), QJsonObject());
    shell.barrier();
    // The draft goes. The window, home again, lands on an empty one for the
    // machine while its rows are still listed, and that goes with them.
    QVERIFY(!shell.draftsFor(kBox).contains(QStringLiteral("roll back the deploy")));

    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList());
  }

  // The other way round, the machine gone before the answer: what was
  // written waits for the answer, which drops it.
  void aRemovedMachineKeepsNoDraftWhenItGoesFirst() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    shell.join();
    const QString draft = shell.drafts()->start(kBox, QStringLiteral("ops"));
    shell.drafts()->setText(draft, QStringLiteral("roll back the deploy"));

    shell.bridge.dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), kBox}});
    QTRY_COMPARE(shell.removals.size(), 1);
    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QStringLiteral("roll back the deploy")});
    shell.mc.reply(shell.removals.takeFirst(), QJsonObject());
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList());
  }

  // Removed from another client, the machine only goes from the shell's
  // rows. The window had landed on a draft of its project, the most recent,
  // and the draft stayed once the rows went.
  void aMachineRemovedElsewhereKeepsNoDraft() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    shell.join();
    shell.native->controller<NavigationController>()->open(NavigationController::Route());
    QTRY_COMPARE(shell.draftsFor(kBox), QStringList{QString()});

    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList());
  }

  // A machine that goes without this client removing it may only be
  // switched off, or not back yet: what the user wrote for it stays, and is
  // there when it comes back.
  void aWrittenDraftOutlivesAMachineThatOnlyWent() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    shell.join();
    const QString draft = shell.drafts()->start(kBox, QStringLiteral("ops"));
    shell.drafts()->setText(draft, QStringLiteral("roll back the deploy"));

    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QStringLiteral("roll back the deploy")});

    shell.join();
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QStringLiteral("roll back the deploy")});
  }

  // A background send empties its draft for the next prompt and keeps the
  // prompt until the launch is answered. A machine that goes meanwhile takes
  // its empty drafts, but not that one: a refused launch puts the prompt back.
  void aBackgroundLaunchKeepsItsDraftWhileTheMachineIsGone() {
    QTemporaryDir home;
    Shell shell(home.path());
    QList<FakeMc::Rpc> launches;
    shell.mc.onRpc(QStringLiteral("orchestration.launchThread"), [&launches](const FakeMc::Rpc& rpc) { launches.append(rpc); });
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    shell.join();
    const QString draft = shell.drafts()->start(kBox, QStringLiteral("ops"));
    QTRY_COMPARE(shell.bridge.state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")).toString(), draft);
    const auto edit = [](int revision) {
      return QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), revision}};
    };
    shell.bridge.dispatch(QStringLiteral("composer.text.set"), QVariantMap{{QStringLiteral("target"), draft},
                                                                          {QStringLiteral("edit"), edit(1)},
                                                                          {QStringLiteral("text"), QStringLiteral("in the back")},
                                                                          {QStringLiteral("cursor"), 11}});
    shell.bridge.dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("edit"), edit(2)},
                                                                        {QStringLiteral("text"), QStringLiteral("in the back")},
                                                                        {QStringLiteral("intent"), QStringLiteral("background")}});
    QTRY_COMPARE(launches.size(), 1);
    QCOMPARE(shell.draftsFor(kBox), QStringList{QString()});

    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QString()});
    shell.mc.refuse(launches.takeFirst(), QStringLiteral("box went"));
    QTRY_COMPARE(shell.native->controller<ComposerController>()->draft(draft), QStringLiteral("in the back"));
  }

  // The removal answered while a background send from the machine's draft is
  // unanswered: the draft waits for the launch, whose refused prompt comes back.
  void theRemovalAnswerKeepsADraftWhoseLaunchIsPending() {
    QTemporaryDir home;
    Shell shell(home.path());
    QList<FakeMc::Rpc> launches;
    shell.mc.onRpc(QStringLiteral("orchestration.launchThread"), [&launches](const FakeMc::Rpc& rpc) { launches.append(rpc); });
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    shell.join();
    const QString draft = shell.drafts()->start(kBox, QStringLiteral("ops"));
    QTRY_COMPARE(shell.bridge.state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")).toString(), draft);
    const auto edit = [](int revision) {
      return QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), revision}};
    };
    shell.bridge.dispatch(QStringLiteral("composer.text.set"), QVariantMap{{QStringLiteral("target"), draft},
                                                                          {QStringLiteral("edit"), edit(1)},
                                                                          {QStringLiteral("text"), QStringLiteral("in the back")},
                                                                          {QStringLiteral("cursor"), 11}});
    shell.bridge.dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("edit"), edit(2)},
                                                                        {QStringLiteral("text"), QStringLiteral("in the back")},
                                                                        {QStringLiteral("intent"), QStringLiteral("background")}});
    QTRY_COMPARE(launches.size(), 1);

    shell.bridge.dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), kBox}});
    QTRY_COMPARE(shell.removals.size(), 1);
    shell.mc.reply(shell.removals.takeFirst(), QJsonObject());
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QString()});
    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QString()});
    shell.mc.refuse(launches.takeFirst(), QStringLiteral("box went"));
    QTRY_COMPARE(shell.native->controller<ComposerController>()->draft(draft), QStringLiteral("in the back"));
  }

  // A background send answered after its machine went: nothing comes back
  // into the emptied draft, so it goes then, not on the next store change.
  void aBackgroundLaunchAnsweredAfterTheMachineWentTakesItsDraft() {
    QTemporaryDir home;
    Shell shell(home.path());
    QList<FakeMc::Rpc> launches;
    shell.mc.onRpc(QStringLiteral("orchestration.launchThread"), [&launches](const FakeMc::Rpc& rpc) { launches.append(rpc); });
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    shell.join();
    const QString draft = shell.drafts()->start(kBox, QStringLiteral("ops"));
    shell.sendInBackground(draft, QStringLiteral("in the back"));
    QTRY_COMPARE(launches.size(), 1);

    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QString()});
    shell.mc.reply(launches.takeFirst(), QJsonObject());
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList());
  }

  // A background send refused while its draft holds a newer prompt: a toast
  // offers the prompt back. Emptied while its machine is gone, the draft
  // stays for the offer, which brings the prompt back.
  void aRestoreOfferKeepsItsEmptiedDraftWhileTheMachineIsGone() {
    QTemporaryDir home;
    Shell shell(home.path());
    shell.refuseBehindANewerPrompt();
    const QString draft = shell.offered;
    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.barrier();
    shell.write(draft, QString(), 4);
    shell.drafts()->reconcile();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QString()});

    QVERIFY(shell.native->controller<ToastController>()->runAction(QStringLiteral("Restore prompt")));
    QTRY_COMPARE(shell.native->controller<ComposerController>()->draft(draft), QStringLiteral("in the back"));
  }

  // An offer keeps an emptied draft, not one the removal was asked with: the
  // answer takes the draft still holding its newer prompt.
  void theRemovalAnswerTakesADraftARestoreOfferIsShownFor() {
    QTemporaryDir home;
    Shell shell(home.path());
    shell.refuseBehindANewerPrompt();
    shell.bridge.dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), kBox}});
    QTRY_COMPARE(shell.removals.size(), 1);
    shell.mc.reply(shell.removals.takeFirst(), QJsonObject());
    shell.barrier();
    QVERIFY(!shell.drafts()->draft(shell.offered));
    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList());
  }

  // The offer closed by hand gives nothing back: the emptied draft goes.
  void aClosedRestoreOfferLetsItsEmptiedDraftGo() {
    QTemporaryDir home;
    Shell shell(home.path());
    shell.refuseBehindANewerPrompt();
    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.barrier();
    shell.write(shell.offered, QString(), 4);
    shell.drafts()->reconcile();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QString()});

    const QVariantList toasts =
        shell.bridge.state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
    QCOMPARE(toasts.size(), 1);
    shell.bridge.dispatch(QStringLiteral("notification.dismiss"),
                          QVariantMap{{QStringLiteral("id"), toasts.constFirst().toMap().value(QStringLiteral("id"))}});
    QTRY_COMPARE(shell.draftsFor(kBox), QStringList());
  }

  // The answer drops the drafts the machine had when it was asked to go. One
  // written after it joined again, before a late answer, stays.
  void aLateAnswerKeepsADraftWrittenAfterARejoin() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    shell.join();

    shell.bridge.dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), kBox}});
    QTRY_COMPARE(shell.removals.size(), 1);
    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.join();
    const QString draft = shell.drafts()->start(kBox, QStringLiteral("ops"));
    shell.drafts()->setText(draft, QStringLiteral("deploy again"));

    shell.mc.reply(shell.removals.takeFirst(), QJsonObject());
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QStringLiteral("deploy again")});
  }

  // The answer comes after the machine is back and the user wrote again in the
  // draft it had when the removal was asked: what was written since is kept.
  void aLateAnswerKeepsTextRewrittenAfterARejoin() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    shell.join();
    const QString draft = shell.drafts()->start(kBox, QStringLiteral("ops"));
    shell.drafts()->setText(draft, QStringLiteral("roll back the deploy"));

    shell.bridge.dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), kBox}});
    QTRY_COMPARE(shell.removals.size(), 1);
    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.join();
    QCOMPARE(shell.drafts()->start(kBox, QStringLiteral("ops")), draft);
    shell.drafts()->setText(draft, QStringLiteral("roll back the deploy, then tag it"));

    shell.mc.reply(shell.removals.takeFirst(), QJsonObject());
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QStringLiteral("roll back the deploy, then tag it")});
  }

  // Written in since, though back to what it was when the removal was asked.
  void aLateAnswerKeepsTextWrittenBackToWhatItWas() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    shell.join();
    const QString draft = shell.drafts()->start(kBox, QStringLiteral("ops"));
    shell.drafts()->setText(draft, QStringLiteral("roll back the deploy"));

    shell.bridge.dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), kBox}});
    QTRY_COMPARE(shell.removals.size(), 1);
    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.join();
    shell.drafts()->setText(draft, QStringLiteral("roll back the deploy, then tag it"));
    shell.drafts()->setText(draft, QStringLiteral("roll back the deploy"));

    shell.mc.reply(shell.removals.takeFirst(), QJsonObject());
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QStringLiteral("roll back the deploy")});
  }

  // Its text as it was, but a file attached since: kept, file and all.
  void aLateAnswerKeepsADraftGivenAFileAfterARejoin() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    shell.join();
    const QString draft = shell.drafts()->start(kBox, QStringLiteral("ops"));
    shell.drafts()->setText(draft, QStringLiteral("roll back the deploy"));

    shell.bridge.dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), kBox}});
    QTRY_COMPARE(shell.removals.size(), 1);
    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.join();
    QCOMPARE(shell.drafts()->start(kBox, QStringLiteral("ops")), draft);
    QTRY_COMPARE(shell.bridge.state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")).toString(), draft);
    QImage picture(8, 8, QImage::Format_RGB32);
    picture.fill(Qt::darkCyan);
    QByteArray png;
    QBuffer buffer(&png);
    buffer.open(QIODevice::WriteOnly);
    picture.save(&buffer, "PNG");
    shell.bridge.dispatch(QStringLiteral("composer.attach"),
                          QVariantMap{{QStringLiteral("files"), QVariantList{QVariantMap{
                                                                    {QStringLiteral("name"), QStringLiteral("shot.png")},
                                                                    {QStringLiteral("mimeType"), QStringLiteral("image/png")},
                                                                    {QStringLiteral("base64"), QString::fromLatin1(png.toBase64())},
                                                                }}}});
    auto* composer = shell.native->controller<ComposerController>();
    QTRY_COMPARE(composer->attachments(draft).size(), 1);

    shell.mc.reply(shell.removals.takeFirst(), QJsonObject());
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QStringLiteral("roll back the deploy")});
    QCOMPARE(composer->attachments(draft).size(), 1);
  }

  // Its text as it was, but a terminal excerpt added since: kept, excerpt and all.
  void aLateAnswerKeepsADraftGivenAnExcerptAfterARejoin() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    shell.join();
    const QString draft = shell.drafts()->start(kBox, QStringLiteral("ops"));
    shell.drafts()->setText(draft, QStringLiteral("roll back the deploy"));

    shell.bridge.dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), kBox}});
    QTRY_COMPARE(shell.removals.size(), 1);
    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.join();
    QCOMPARE(shell.drafts()->start(kBox, QStringLiteral("ops")), draft);
    QTRY_COMPARE(shell.bridge.state()->value(QStringLiteral("composer")).toMap().value(QStringLiteral("target")).toString(), draft);
    shell.bridge.dispatch(QStringLiteral("composer.terminalContext.add"),
                          QVariantMap{{QStringLiteral("text"), QStringLiteral("deploy failed: exit 1")},
                                      {QStringLiteral("terminalId"), QStringLiteral("term-1")},
                                      {QStringLiteral("terminalLabel"), QStringLiteral("Terminal 1")},
                                      {QStringLiteral("lineStart"), 3},
                                      {QStringLiteral("lineEnd"), 3}});
    auto* composer = shell.native->controller<ComposerController>();
    QCOMPARE(composer->terminalContexts(draft).size(), 1);

    shell.mc.reply(shell.removals.takeFirst(), QJsonObject());
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList{QStringLiteral("roll back the deploy")});
    QCOMPARE(composer->terminalContexts(draft).size(), 1);
  }

  // A snapshot sent before a member's rows have come names it without a
  // version and with no rows: its projects may only not have come yet, and
  // what was written for them is kept.
  void aMemberNamedBeforeItsRowsKeepsItsDrafts() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    shell.join();
    const QString draft = shell.drafts()->start(kBox, QStringLiteral("ops"));
    shell.drafts()->setText(draft, QStringLiteral("roll back the deploy"));

    QJsonObject snapshot = shell.mc.shellFrames.last();
    QJsonArray mcs = snapshot.value(QLatin1String("mcs")).toArray();
    mcs.append(QJsonObject{{QStringLiteral("mc"), shell.mc.peers.value(kBox)},
                           {QStringLiteral("online"), true},
                           {QStringLiteral("environment"), QJsonObject{{QStringLiteral("environmentId"), kBox}}},
                           {QStringLiteral("reset"), true}});
    snapshot.insert(QStringLiteral("mcs"), mcs);
    shell.mc.send(snapshot);
    shell.barrier();
    QVERIFY(shell.native->store()->servesEnvironment(kBox));
    QCOMPARE(shell.draftsFor(kBox), QStringList{QStringLiteral("roll back the deploy")});
  }

  // A machine the shell never listed has no rows to wait for: the answer
  // drops what was kept for it.
  void anUnlistedMachinesDraftsGoOnTheAnswer() {
    QTemporaryDir home;
    Shell shell(home.path());
    QTRY_VERIFY(shell.native->client()->isReady() && shell.native->store()->synchronized());
    const QString draft = shell.drafts()->start(kBox, QStringLiteral("ops"));
    shell.drafts()->setText(draft, QStringLiteral("roll back the deploy"));

    shell.bridge.dispatch(QStringLiteral("cluster.remove"), QVariantMap{{QStringLiteral("id"), kBox}});
    QTRY_COMPARE(shell.removals.size(), 1);
    shell.mc.reply(shell.removals.takeFirst(), QJsonObject());
    QTRY_COMPARE(shell.draftsFor(kBox), QStringList());
  }
};

QTEST_MAIN(DraftControllerRegression)
#include "tst_DraftControllerRegression.moc"
