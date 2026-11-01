// A shortcut recorded but not yet saved could no longer be saved once the user
// started recording again and cancelled: starting cleared the shortcut's check,
// and nothing checked it again when recording stopped.

#include <QtTest>

#include "FakeMc.h"
#include "McClient.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SnapShotBackend.h"
#include "SnapShotController.h"

namespace {

// A desktop portal that has answered and holds whatever it is asked to.
class Portal : public SnapShotBackend {
public:
  using SnapShotBackend::SnapShotBackend;
  Session session() const override {
    Session session;
    session.ready = true;
    session.mode = QStringLiteral("portal");
    session.backend = QStringLiteral("screenshot-portal");
    return session;
  }
  void play(const QString&) override {}
};

QVariantMap shortcut(const ShellBridge& bridge) {
  return bridge.state()->value(QStringLiteral("snapShot")).toMap().value(QStringLiteral("shortcut")).toMap();
}

}  // namespace

class SnapShotRegression : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() {
    QProcessEnvironment env;
    env.insert(QStringLiteral("XDG_SESSION_TYPE"), QStringLiteral("wayland"));
    SnapShotBackend::setEnvironment(env);
    SnapShotBackend::setPortalFactory([](const SnapShotBackend::Platform&, QObject* parent) -> SnapShotBackend* { return new Portal(parent); });
  }

  void aRecordedShortcutCanBeSavedAfterRecordingAgainIsCancelled_data() {
    QTest::addColumn<bool>("escape");
    QTest::newRow("the user presses Escape") << true;
    QTest::newRow("the user cancels recording") << false;
  }

  void aRecordedShortcutCanBeSavedAfterRecordingAgainIsCancelled() {
    QFETCH(bool, escape);
    QTemporaryDir home;
    FakeMc mc;
    mc.onShape(QStringLiteral("config"), [&mc](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("settings"), QJsonObject()}}}});
    });
    ShellBridge bridge;
    NativeShell native{&bridge};
    native.setStoreDirs(home.filePath(QStringLiteral("state")), home.filePath(QStringLiteral("data")), home.filePath(QStringLiteral("cache")));
    native.controller<SettingsController>()->setDevicePath(home.filePath(QStringLiteral("preferences.json")));
    native.restoreWindows();
    native.open(mc.origin(), QStringLiteral("mc-token"));
    QTRY_VERIFY(native.isActive() && native.store()->synchronized());
    native.controller<NavigationController>()->open(NavigationController::Route::settings(SnapShotController::kSection));
    const auto dispatch = [&bridge](const char* action, const QVariantMap& payload = {}) {
      bridge.dispatch(QStringLiteral("snapShot.") + QString::fromLatin1(action), payload);
    };

    dispatch("record.start");
    dispatch("record.key", {{QStringLiteral("key"), int(Qt::Key_F9)}, {QStringLiteral("modifiers"), int(Qt::ControlModifier | Qt::AltModifier)}});
    QTRY_VERIFY(shortcut(bridge).value(QStringLiteral("canSave")).toBool());

    dispatch("record.start");
    if (escape) dispatch("record.key", {{QStringLiteral("key"), int(Qt::Key_Escape)}, {QStringLiteral("modifiers"), 0}});
    else dispatch("record.cancel");
    QTRY_VERIFY(!shortcut(bridge).value(QStringLiteral("recording")).toBool());
    QVERIFY(shortcut(bridge).value(QStringLiteral("changed")).toBool());
    QVERIFY(shortcut(bridge).value(QStringLiteral("canSave")).toBool());

    dispatch("shortcut.save");
    QTRY_COMPARE(native.controller<SettingsController>()->setting(QStringLiteral("snapShotShortcut")).toMap().value(QStringLiteral("key")).toString(),
                 QStringLiteral("f9"));
  }
};

QTEST_MAIN(SnapShotRegression)
#include "tst_SnapShotRegression.moc"
