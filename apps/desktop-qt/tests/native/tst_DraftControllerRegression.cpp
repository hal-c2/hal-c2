// What tests/prop/tst_DraftControllerProp.cpp found about the drafts of a
// machine that leaves the cluster, each as the plain case that shows it
// (hal-c2#1589).

#include <QtTest>

#include "DraftController.h"
#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"

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
    // The draft goes, and the window, home again, lands on none of the
    // machine's while its rows are still listed.
    QCOMPARE(shell.draftsFor(kBox), QStringList());

    shell.mc.remove(kBox);
    QTRY_VERIFY(!shell.native->store()->servesEnvironment(kBox));
    shell.barrier();
    QCOMPARE(shell.draftsFor(kBox), QStringList());
  }

  // The other way round, the machine gone before the answer: its drafts go
  // with its rows, and the answer finds nothing left.
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
    QCOMPARE(shell.draftsFor(kBox), QStringList());
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
