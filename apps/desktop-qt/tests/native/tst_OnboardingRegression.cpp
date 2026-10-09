// What tests/prop/tst_ComposerProp.cpp found in onboarding.

#include <QtTest>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "TestTime.h"

class OnboardingRegression : public QObject {
  Q_OBJECT

private slots:
  // A device that already has projects counts as set up and saves so; when
  // that save failed, its deviceChanged decided again, which saved again,
  // until the stack ran out.
  void aFailedSaveOfTheFirstRunSettlesOnce() {
    QTemporaryDir home;
    FakeMc mc;
    mc.projects.insert(QStringLiteral("p1"), QJsonObject{
                                                 {QStringLiteral("id"), QStringLiteral("p1")},
                                                 {QStringLiteral("title"), QStringLiteral("Shop")},
                                                 {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")},
                                                 {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                                                 {QStringLiteral("scripts"), QJsonArray()},
                                             });
    ShellBridge bridge;
    NativeShell native(&bridge);
    native.setStoreDirs(home.path() + QStringLiteral("/state"), home.path() + QStringLiteral("/data"),
                        home.path() + QStringLiteral("/cache"));
    // No device path: every save of this device's preferences fails.
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));

    HAL_C2_TRY_COMPARE(bridge.state()->value(QStringLiteral("onboarding")).toMap().value(QStringLiteral("gate")).toString(),
                      QStringLiteral("app"));
    QVERIFY(!native.controller<SettingsController>()->deviceError().isEmpty());
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/onboarding-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  OnboardingRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_OnboardingRegression.moc"
