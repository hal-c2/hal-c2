#include <QProcessEnvironment>
#include <QTest>

#include "StoragePaths.h"

namespace {

QProcessEnvironment environment(std::initializer_list<std::pair<const char*, const char*>> values) {
  QProcessEnvironment env;
  for (const auto& [name, value] : values) {
    env.insert(QString::fromLatin1(name), QString::fromLatin1(value));
  }
  return env;
}

StoragePaths onUnix(const QProcessEnvironment& env, const QString& homeDir = QString()) {
  return resolveStoragePaths(homeDir, env, QStringLiteral("/home/me"), StoragePlatform::Unix);
}

}  // namespace

class StoragePathsTest : public QObject {
  Q_OBJECT

private slots:
  void defaultsToTheXdgLayoutOnLinuxAndMacOs() {
    const StoragePaths paths = onUnix({});
    QVERIFY(paths.root.isEmpty());
    QCOMPARE(paths.config, QStringLiteral("/home/me/.config/hal-c2"));
    QCOMPARE(paths.data, QStringLiteral("/home/me/.local/share/hal-c2"));
    QCOMPARE(paths.state, QStringLiteral("/home/me/.local/state/hal-c2"));
    QCOMPARE(paths.cache, QStringLiteral("/home/me/.cache/hal-c2"));
  }

  void absoluteXdgVariablesMoveTheirKind() {
    const StoragePaths paths = onUnix(environment({{"XDG_CONFIG_HOME", "/xdg/config"},
                                                 {"XDG_CACHE_HOME", " /xdg/cache/ "}}));
    QCOMPARE(paths.config, QStringLiteral("/xdg/config/hal-c2"));
    QCOMPARE(paths.cache, QStringLiteral("/xdg/cache/hal-c2"));
    QCOMPARE(paths.state, QStringLiteral("/home/me/.local/state/hal-c2"));
  }

  void relativeXdgVariablesAreIgnored() {
    const StoragePaths paths =
        onUnix(environment({{"XDG_CONFIG_HOME", "config"}, {"XDG_STATE_HOME", "./state"}}));
    QCOMPARE(paths.config, QStringLiteral("/home/me/.config/hal-c2"));
    QCOMPARE(paths.state, QStringLiteral("/home/me/.local/state/hal-c2"));
  }

  void halC2HomeIsOneRootAndOutranksXdg() {
    const StoragePaths paths =
        onUnix(environment({{"HAL_C2_HOME", "/srv/hal-c2"}, {"XDG_CONFIG_HOME", "/xdg/config"}}));
    QCOMPARE(paths.root, QStringLiteral("/srv/hal-c2"));
    QCOMPARE(paths.config, QStringLiteral("/srv/hal-c2/config"));
    QCOMPARE(paths.data, QStringLiteral("/srv/hal-c2/data"));
    QCOMPARE(paths.state, QStringLiteral("/srv/hal-c2/state"));
    QCOMPARE(paths.cache, QStringLiteral("/srv/hal-c2/cache"));
  }

  void anOldHomeInHalC2HomeIsNotARoot() {
    for (const char* old : {"/home/me/.hal-c2", "/home/me/.t3/", "relative"}) {
      const StoragePaths paths = onUnix(environment({{"HAL_C2_HOME", old}}));
      QVERIFY2(paths.root.isEmpty(), old);
      QCOMPARE(paths.config, QStringLiteral("/home/me/.config/hal-c2"));
    }
  }

  void homeDirOutranksHalC2Home() {
    const StoragePaths paths =
        onUnix(environment({{"HAL_C2_HOME", "/srv/hal-c2"}}), QStringLiteral("/tmp/sandbox"));
    QCOMPARE(paths.root, QStringLiteral("/tmp/sandbox"));
    QCOMPARE(paths.config, QStringLiteral("/tmp/sandbox/config"));
    QCOMPARE(paths.cache, QStringLiteral("/tmp/sandbox/cache"));
  }

  void theDevelopmentProfileIsItsOwnXdgDirectoriesAndIgnoresHalC2Home() {
    const StoragePaths paths = resolveStoragePaths(
        QString(), environment({{"HAL_C2_HOME", "/srv/hal-c2"}, {"XDG_DATA_HOME", "/xdg/data"}}),
        QStringLiteral("/home/me"), StoragePlatform::Unix, StorageProfile::Development);
    QVERIFY(paths.root.isEmpty());
    QCOMPARE(paths.config, QStringLiteral("/home/me/.config/hal-c2-dev"));
    QCOMPARE(paths.data, QStringLiteral("/xdg/data/hal-c2-dev"));
    QCOMPARE(paths.state, QStringLiteral("/home/me/.local/state/hal-c2-dev"));
    QCOMPARE(paths.cache, QStringLiteral("/home/me/.cache/hal-c2-dev"));
  }

  void homeDirIsARootInTheDevelopmentProfileToo() {
    const StoragePaths paths =
        resolveStoragePaths(QStringLiteral("/tmp/sandbox"), environment({}), QStringLiteral("/home/me"),
                            StoragePlatform::Unix, StorageProfile::Development);
    QCOMPARE(paths.root, QStringLiteral("/tmp/sandbox"));
    QCOMPARE(paths.data, QStringLiteral("/tmp/sandbox/data"));
  }

  void windowsUsesAppDataForConfigAndLocalAppDataForTheRest() {
    const StoragePaths paths = resolveStoragePaths(
        QString(),
        environment({{"APPDATA", "C:/Users/me/AppData/Roaming"},
                     {"LOCALAPPDATA", "C:/Users/me/AppData/Local"},
                     {"XDG_CACHE_HOME", "relative"},
                     {"XDG_DATA_HOME", "D:/xdg/data"}}),
        QStringLiteral("C:/Users/me"), StoragePlatform::Windows);
    QVERIFY(paths.root.isEmpty());
    QCOMPARE(paths.config, QStringLiteral("C:/Users/me/AppData/Roaming/hal-c2/config"));
    // An XDG variable is a base for one kind, so nothing is nested under it.
    QCOMPARE(paths.data, QStringLiteral("D:/xdg/data/hal-c2"));
    QCOMPARE(paths.state, QStringLiteral("C:/Users/me/AppData/Local/hal-c2/state"));
    QCOMPARE(paths.cache, QStringLiteral("C:/Users/me/AppData/Local/hal-c2/cache"));
  }

  void windowsOldHomesCompareWithoutCase() {
    const StoragePaths paths =
        resolveStoragePaths(QString(), environment({{"HAL_C2_HOME", "c:/USERS/me/.HAL-C2"}}),
                            QStringLiteral("C:/Users/me"), StoragePlatform::Windows);
    QVERIFY(paths.root.isEmpty());
  }
};

QTEST_GUILESS_MAIN(StoragePathsTest)
#include "tst_StoragePaths.moc"
