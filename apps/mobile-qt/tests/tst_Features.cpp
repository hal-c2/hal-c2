// Runs the phone's scenarios (the @mobile and @shared ones in the files
// kDefaultGlobs names) against a fake MC: the Gherkin reader and step
// definitions the desktop's runner shares (apps/desktop-qt/tests/native/
// features/Runner.h), the steps the files in features/ register (Harness.h),
// and one QTest row per scenario. Each scenario gets a phone of its own
// (features/World.h): the app as main.cpp builds it, with its real root.
// HAL_C2_FEATURES narrows the run to other globs under features/ (space
// separated; a glob may name scenarios after a colon), and HAL_C2_BACKLOG=1
// runs the @backlog and @backlog-mobile ones instead.

#include <QGuiApplication>
#include <QStandardPaths>
#include <QTest>

#include "Harness.h"
#include "MobileApp.h"
#include "Runner.h"
#include "features/World.h"

namespace {

const QStringList kDefaultGlobs{
    QStringLiteral("mobile/pairing-and-environments.feature"),
    QStringLiteral("mobile/home-and-thread-list.feature"),
    QStringLiteral("mobile/composer.feature"),
    QStringLiteral("mobile/navigation-and-deep-links.feature"),
    QStringLiteral("mobile/offline-and-lifecycle.feature"),
};

const QString kFeaturesDir = QStringLiteral(HAL_C2_FEATURES_DIR);

}  // namespace

class tst_Features : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() {
    runner::defineSteps();
    m_scenarios = runner::collectScenarios(kFeaturesDir, kDefaultGlobs, QStringLiteral("mobile"));
    QVERIFY2(!m_scenarios.isEmpty(), "no scenarios matched");
  }

  void scenarios_data() { runner::addRows(m_scenarios, kFeaturesDir); }

  void scenarios() {
    QFETCH(int, index);
    World world;
    if (const auto failure = runner::run(world, m_scenarios.at(index), kFeaturesDir)) QFAIL(qPrintable(*failure));
  }

private:
  QList<Scenario> m_scenarios;
};

int main(int argc, char** argv) {
  // Qt's own files (the QML cache) go to its test locations, not the user's.
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  MobileApp::prepare();
  tst_Features test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_Features.moc"
