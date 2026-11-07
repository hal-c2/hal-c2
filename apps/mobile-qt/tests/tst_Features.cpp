// Runs the phone's scenarios (the @mobile and @shared ones in the files
// kDefaultGlobs names) against a fake MC: the Gherkin reader and step
// definitions the desktop's runner shares (apps/desktop-qt/tests/native/
// features/Runner.h), the steps the files in features/ register (Harness.h),
// and one QTest row per scenario. Each scenario gets a phone of its own
// (features/World.h): the app as main.cpp builds it, with its real root.
// HAL_C2_FEATURES narrows the run to other globs under features/ (space
// separated; a glob may name scenarios after a colon), and HAL_C2_BACKLOG=1
// runs the @backlog and @backlog-mobile ones instead. HAL_C2_SHOTS=<dir>
// keeps what the window showed after each step, as
// <dir>/<scenario's row>-<step's line>.png.

#include <QDir>
#include <QGuiApplication>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTest>

#include <ctime>

#include "Harness.h"
#include "MobileApp.h"
#include "Runner.h"
#include "features/World.h"

namespace {

const QStringList kDefaultGlobs{
    QStringLiteral("files/file-viewer-and-editing.feature"),
    QStringLiteral("mobile/pairing-and-environments.feature"),
    QStringLiteral("connections/connection-health.feature:An app that starts with its environment*"),
    QStringLiteral("connections/connection-health.feature:A network that comes back is tried at once"),
    QStringLiteral("connections/connection-health.feature:An environment on this machine is reached without a network"),
    QStringLiteral("connections/connection-health.feature:A client opened without a network waits for it"),
    QStringLiteral("connections/connection-health.feature:A connection is ready only after the environment describes itself"),
    QStringLiteral("connections/connection-health.feature:A failed shell subscription is not shown as reconnecting"),
    QStringLiteral("connections/connection-health.feature:The environment's status says it is reconnecting, in plain words"),
    QStringLiteral("connections/connection-health.feature:The connection's state is an icon with a word*"),
    QStringLiteral("connections/connection-health.feature:A reconnect within a second and a half is not shown"),
    QStringLiteral("connections/connection-health.feature:The user copies a connection's trace id for a bug report"),
    QStringLiteral("connections/connection-health.feature:Cached data stays readable offline without looking live"),
    QStringLiteral("connections/connection-health.feature:A thread left for under five minutes resumes without a snapshot"),
    QStringLiteral("connections/connection-health.feature:A thread left for longer comes back from what the client kept"),
    QStringLiteral("connections/connection-health.feature:Subscriptions follow a replaced connection"),
    QStringLiteral("connections/connection-health.feature:Reconnecting does not repeat the user's actions"),
    QStringLiteral("connections/connection-health.feature:Removing an environment clears everything the client kept for it"),
    QStringLiteral("connections/connection-health.feature:One connection serves every MC of a cluster"),
    QStringLiteral("connections/connection-health.feature:A cluster connection resumes each stream from where it stopped"),
    QStringLiteral("connections/connection-health.feature:A long background suspension replaces the connection"),
    QStringLiteral("connections/connection-health.feature:A dropped connection retries with growing delays"),
    QStringLiteral("connections/connection-health.feature:An offline device waits instead of retrying"),
    QStringLiteral("connections/connection-health.feature:A device that lost one of its two networks keeps trying"),
    QStringLiteral("connections/connection-health.feature:A device that lost every network waits and says it is offline"),
    QStringLiteral("connections/connection-health.feature:A refused credential waits for the user"),
    QStringLiteral("connections/connection-health.feature:Foregrounding wakes a waiting retry"),
    QStringLiteral("connections/connection-health.feature:Foregrounding probes a healthy connection instead of replacing it"),
    QStringLiteral("connections/connection-health.feature:The phone gives the foreground check 3 seconds*"),
    QStringLiteral("connections/connection-health.feature:A protocol mismatch blocks the connection with advice*"),
    QStringLiteral("connections/connection-health.feature:A server on another HAL-C2 version warns only when it is behind*"),
    QStringLiteral("connections/connection-health.feature:What the environment answers decides*"),
    QStringLiteral("connections/connection-health.feature:An address that answers as a different*"),
    QStringLiteral("connections/connection-health.feature:A connection that does not answer the check*"),
    QStringLiteral("connections/connection-health.feature:A connection that is not set up within*"),
    QStringLiteral("connections/connection-health.feature:The retry delays start over*"),
    QStringLiteral("connections/connection-health.feature:A blocked environment is tried again*"),
    QStringLiteral("connections/connection-health.feature:A connection with nothing to say*"),
    QStringLiteral("connections/connection-health.feature:An action waiting for its answer*"),
    QStringLiteral("connections/connection-health.feature:An action for an environment that is not connected*"),
    QStringLiteral("connections/connection-health.feature:A slow MC finishes*"),
    QStringLiteral("connections/connection-health.feature:Cached data never overwrites*"),
    QStringLiteral("connections/connection-health.feature:A kept copy the client cannot read*"),
    QStringLiteral("connections/connection-health.feature:A new task offline still offers*"),
    QStringLiteral("connections/connection-health.feature:Only the whole branch list*"),
    QStringLiteral("connections/connection-health.feature:A change to a repository's branches*"),
    QStringLiteral("connections/connection-health.feature:Only the environment with the bad credential stops*"),
    QStringLiteral("connections/connection-health.feature:A saved environment whose record or credential has gone*"),
    QStringLiteral("connections/connection-health.feature:An expiring credential does not close*"),
    QStringLiteral("connections/connection-health.feature:A failed renewal affects only its request*"),
    QStringLiteral("mobile/home-and-thread-list.feature"),
    QStringLiteral("mobile/composer.feature"),
    QStringLiteral("mobile/navigation-and-deep-links.feature"),
    QStringLiteral("mobile/offline-and-lifecycle.feature"),
    QStringLiteral("mobile/tablet-and-hardware-keyboard.feature"),
    QStringLiteral("mobile/notifications.feature"),
    QStringLiteral("mobile/spaces.feature"),
    QStringLiteral("mobile/terminal.feature"),
    QStringLiteral("terminal/*.feature"),
    QStringLiteral("space/pages.feature"),
    QStringLiteral("timeline/plans-and-subagents.feature"),
    QStringLiteral("space/page-history.feature"),
    QStringLiteral("space/agent-in-page.feature"),
    QStringLiteral("space/prompt.feature"),
    QStringLiteral("space/self-updating-pages.feature"),
    QStringLiteral("space/visualize.feature"),
    QStringLiteral("space/slides.feature"),
    QStringLiteral("space/sites.feature"),
    QStringLiteral("space/images.feature"),
    QStringLiteral("space/presence.feature"),
    QStringLiteral("space/markdown.feature"),
    QStringLiteral("space/project-files.feature"),
    QStringLiteral("timeline/streaming.feature"),
    QStringLiteral("threads/sidebar-list.feature:Very long settled*"),
    QStringLiteral("threads/sidebar-list.feature:*plugin*"),
    QStringLiteral("threads/settle.feature"),
    QStringLiteral("providers/codex.feature:A plan Codex marked finished*"),
    QStringLiteral("mc/orchestration/queue-and-steering.feature:A usage limit keeps the queue*"),
    QStringLiteral("settings/updates.feature"),
    QStringLiteral("source-control/worktrees-and-setup-scripts.feature"),
    QStringLiteral("source-control/review-diffs.feature"),
    QStringLiteral("source-control/pull-request-threads.feature"),
    QStringLiteral("timeline/tool-calls.feature"),
};

const QString kFeaturesDir = QStringLiteral(HAL_C2_FEATURES_DIR);

}  // namespace

class tst_Features : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() {
    runner::defineSteps();
    qsizetype files = 0;
    m_scenarios = runner::collectScenarios(kFeaturesDir, kDefaultGlobs, QStringLiteral("mobile"), &files);
    // A mistyped glob, a renamed file or a wrong features dir matches nothing: that fails.
    QVERIFY2(files > 0, "no feature files matched");
    // Files whose scenarios all wait on the backlog have nothing to run yet.
    if (m_scenarios.isEmpty()) QSKIP("no runnable scenarios matched");
  }

  void scenarios_data() { runner::addRows(m_scenarios, kFeaturesDir); }

  void scenarios() {
    QFETCH(int, index);
    World world;
    const Scenario& scenario = m_scenarios.at(index);
    const QString shots = qEnvironmentVariable("HAL_C2_SHOTS");
    if (shots.isEmpty()) {
      if (const auto failure = runner::run(world, scenario, kFeaturesDir)) QFAIL(qPrintable(*failure));
      return;
    }
    static const QRegularExpression unsafe(QStringLiteral("[^A-Za-z0-9]+"));
    QDir().mkpath(shots);
    for (const Step& step : scenario.steps) {
      std::optional<QString> failure;
      try {
        runner::runStep(world, step);
      } catch (const Failure& failed) {
        failure = runner::describe(scenario, step, failed, kFeaturesDir);
      }
      world.snapshot(QDir(shots).filePath(QStringLiteral("%1-%2.png").arg(QString::fromUtf8(QTest::currentDataTag()).replace(unsafe, QStringLiteral("-"))).arg(step.line)));
      if (failure) QFAIL(qPrintable(*failure));
    }
  }

private:
  QList<Scenario> m_scenarios;
};

int main(int argc, char** argv) {
  // The scenarios' times are read in UTC, as on CI.
  qputenv("TZ", "UTC");
  tzset();
  // Qt's own files (the QML cache) go to its test locations, not the user's.
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  MobileApp::prepare();
  tst_Features test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_Features.moc"
