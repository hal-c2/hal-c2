// What tests/prop/tst_DevicePreferencesProp.cpp found in SettingsController's
// device preferences once their writes left the GUI thread (CoalescingWriter):
// a desktop's saves whose write had not landed yet were lost to the file it
// re-read, and a change back made once its own write had landed, but before
// it heard the file, was lost to the base it still held.

#include <QtTest>

#include "CoalescingWriter.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"

#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QJsonDocument>
#include <QSignalSpy>
#include <QTemporaryDir>

#include <memory>

namespace {

struct Desktop {
  ShellBridge bridge;
  NativeShell native{&bridge};

  explicit Desktop(const QString& path) { settings()->setDevicePath(path); }

  SettingsController* settings() { return native.controller<SettingsController>(); }
  CoalescingWriter* writer() { return settings()->findChild<CoalescingWriter*>(); }
  QFileSystemWatcher* watcher() { return settings()->findChild<QFileSystemWatcher*>(); }
  // Its watcher's events, while it is deaf, are lost; hear() tells it again.
  void deafen(bool deaf) { watcher()->blockSignals(deaf); }
  void hear(const QString& path) {
    deafen(false);
    QMetaObject::invokeMethod(watcher(), "directoryChanged", Q_ARG(QString, QFileInfo(path).absolutePath()));
  }
  bool save(const QString& key, const QVariant& value) { return settings()->writeDevice(key, value); }
  QJsonObject view() { return settings()->deviceSettings(); }
};

QJsonObject fileAt(const QString& path) {
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) return {};
  return QJsonDocument::fromJson(file.readAll()).object();
}

const QString kTimestamp = QStringLiteral("timestampFormat");
const QString kFontSize = QStringLiteral("fontSizeInterface");
const QString kAppearance = QStringLiteral("appearance");
const QString kOne = QStringLiteral("one");
const QString kTwo = QStringLiteral("two");

}  // namespace

class DevicePreferencesRegression : public QObject {
  Q_OBJECT

private slots:
  // Each save re-read the file and put its change over that: the second
  // found the first not written yet and wrote its own change alone.
  void twoSavesBeforeTheFileIsHeardBothLand() {
    QTemporaryDir home;
    const QString path = home.filePath(QStringLiteral("preferences.json"));
    Desktop desktop(path);
    desktop.deafen(true);
    {
      Desktop other(path);
      QVERIFY(other.save(kFontSize, kTwo));
    }  // Quitting writes its save at once.
    QCOMPARE(fileAt(path), (QJsonObject{{kFontSize, kTwo}}));

    QVERIFY(desktop.save(kTimestamp, kOne));
    QVERIFY(desktop.save(kFontSize, kOne));
    QVERIFY(desktop.writer()->flush());

    const QJsonObject both{{kTimestamp, kOne}, {kFontSize, kOne}};
    QCOMPARE(fileAt(path), both);
    desktop.hear(path);
    QCOMPARE(desktop.view(), both);
    QVERIFY(!desktop.settings()->deviceUnsaved());
  }

  // The base moved only when the watcher fired: a change back made after the
  // desktop's own write landed went over the base from before it, which
  // showed nothing to change, and the change it took back came back.
  void aChangeBackAfterTheWriteLandedStays() {
    QTemporaryDir home;
    const QString path = home.filePath(QStringLiteral("preferences.json"));
    Desktop desktop(path);
    desktop.writer()->setDelay(0);
    desktop.deafen(true);
    QSignalSpy landed(desktop.writer(), &CoalescingWriter::wrote);

    QVERIFY(desktop.save(kTimestamp, kOne));
    QVERIFY(desktop.save(kAppearance, kOne));
    QVERIFY(landed.wait());
    QCOMPARE(fileAt(path), (QJsonObject{{kTimestamp, kOne}, {kAppearance, kOne}}));

    QVERIFY(desktop.save(kAppearance, QVariant()));
    QVERIFY(landed.wait());
    QVERIFY(desktop.writer()->idle());

    const QJsonObject changedBack{{kTimestamp, kOne}};
    QCOMPARE(fileAt(path), changedBack);
    desktop.hear(path);
    QCOMPARE(desktop.view(), changedBack);
    QVERIFY(!desktop.settings()->deviceUnsaved());
  }
};

QTEST_MAIN(DevicePreferencesRegression)
#include "tst_DevicePreferencesRegression.moc"
