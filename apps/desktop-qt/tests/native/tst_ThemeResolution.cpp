// How ThemeController resolves the theme it publishes: built-in, then this
// device's, then the MC's; halves over the chosen theme; the standard look
// when nothing matches; and the colours every theme is drawn in.

#include <QDir>
#include <QGuiApplication>
#include <QJsonArray>
#include <QTemporaryDir>
#include <QTest>

#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ThemeController.h"

namespace {

QJsonObject theme(const QString& id, const QString& appearance, const QString& canvas) {
  return {{QStringLiteral("id"), id},
          {QStringLiteral("label"), id},
          {QStringLiteral("appearance"), appearance},
          {QStringLiteral("colors"), QJsonObject{{QStringLiteral("canvas"), canvas}}}};
}

}  // namespace

class tst_ThemeResolution : public QObject {
  Q_OBJECT

  QTemporaryDir m_dir;
  std::unique_ptr<ShellBridge> m_bridge;
  std::unique_ptr<NativeShell> m_native;

  SettingsController* settings() { return m_native->controller<SettingsController>(); }
  ThemeController* themes() { return m_native->controller<ThemeController>(); }
  QVariantMap published() { return m_bridge->state()->value(QStringLiteral("theme")).toMap(); }
  QString canvas() { return published().value(QStringLiteral("colors")).toMap().value(QStringLiteral("canvas")).toString(); }

  void save(const QJsonObject& device) { QVERIFY(settings()->setDeviceSettings(device)); }

private slots:
  void init() {
    m_native.reset();
    m_bridge = std::make_unique<ShellBridge>();
    m_native = std::make_unique<NativeShell>(m_bridge.get());
    QFile::remove(m_dir.filePath(QStringLiteral("preferences.json")));
    settings()->setDevicePath(m_dir.filePath(QStringLiteral("preferences.json")));
    themes()->setSystemDark(false);
  }

  void cleanup() {
    m_native.reset();
    m_bridge.reset();
  }

  void colorsAreDrawable() {
    QCOMPARE(ThemeController::canonicalColor(QStringLiteral("#ABC")), QStringLiteral("#aabbcc"));
    QCOMPARE(ThemeController::canonicalColor(QStringLiteral("#11223344")), QStringLiteral("#11223344"));
    QCOMPARE(ThemeController::canonicalColor(QStringLiteral("oklch(1 0 0)")), QStringLiteral("#ffffff"));
    QCOMPARE(ThemeController::canonicalColor(QStringLiteral("oklch(0 0 0)")), QStringLiteral("#000000"));
    // index.css --success (emerald-500, #00bc7d in Tailwind 4).
    QCOMPARE(ThemeController::canonicalColor(QStringLiteral("oklch(0.696 0.17 162.48)")), QStringLiteral("#00bc7d"));
    QCOMPARE(ThemeController::canonicalColor(QStringLiteral("oklch(50% 0 0 / 50%)")).size(), 9);
    QCOMPARE(ThemeController::canonicalColor(QStringLiteral("Tomato")), QStringLiteral("#ff6347"));
    QVERIFY(ThemeController::canonicalColor(QStringLiteral("var(--x)")).isEmpty());
    QVERIFY(ThemeController::canonicalColor(QStringLiteral("#12345")).isEmpty());
  }

  void nothingChosenIsTheStandardLook() {
    QCOMPARE(published().value(QStringLiteral("id")), QVariant(QStringLiteral("hal-c2")));
    QCOMPARE(canvas(), QStringLiteral("#fcfcfc"));
    themes()->setSystemDark(true);
    QCOMPARE(canvas(), QStringLiteral("#0a0a0a"));
    // The roles the bricks paint outside theme files come with every theme.
    QVERIFY(published().value(QStringLiteral("colors")).toMap().contains(QStringLiteral("success")));
    QVERIFY(published().value(QStringLiteral("colors")).toMap().contains(QStringLiteral("info")));
  }

  void menusAndDialogsAreNearlyOpaqueByDefault() {
    // Nothing saved: the overlay (menus, palettes, dialogs) keeps 96% of its alpha, not 80%.
    const auto overlay = [this] { return published().value(QStringLiteral("colors")).toMap().value(QStringLiteral("surfaceOverlay")).toString(); };
    QCOMPARE(overlay(), QStringLiteral("#fffffff5"));
    themes()->setSystemDark(true);
    QCOMPARE(overlay(), QStringLiteral("#111111f5"));
  }

  void builtInsWinTheirIds() {
    // A saved theme cannot take a built-in's (or a reserved) id.
    save({{QStringLiteral("customThemes"), QJsonArray{theme(QStringLiteral("grove"), QStringLiteral("light"), QStringLiteral("#010101"))}},
          {QStringLiteral("theme"), QStringLiteral("grove")}});
    QCOMPARE(themes()->resolvedId(), QStringLiteral("grove"));
    QVERIFY(canvas() != QStringLiteral("#010101"));
    QCOMPARE(canvas(), ThemeController::canonicalColor(QStringLiteral("oklch(0.972369 0.005497 157.15)")));
  }

  void savedThemesWinOverPublishedOnes() {
    settings()->setThemes({theme(QStringLiteral("dusk"), QStringLiteral("light"), QStringLiteral("#020202"))});
    save({{QStringLiteral("theme"), QStringLiteral("dusk")}});
    QCOMPARE(canvas(), QStringLiteral("#020202"));
    save({{QStringLiteral("theme"), QStringLiteral("dusk")},
          {QStringLiteral("customThemes"), QJsonArray{theme(QStringLiteral("dusk"), QStringLiteral("light"), QStringLiteral("#030303"))}}});
    QCOMPARE(canvas(), QStringLiteral("#030303"));
    const QVariantList offered = themes()->available();
    const auto dusk = std::count_if(offered.cbegin(), offered.cend(), [](const QVariant& entry) {
      return entry.toMap().value(QStringLiteral("id")) == QLatin1String("dusk");
    });
    QCOMPARE(dusk, 1);
    // No longer saved, the published one is drawn again; no longer published either, the standard look.
    save({{QStringLiteral("theme"), QStringLiteral("dusk")}});
    QCOMPARE(canvas(), QStringLiteral("#020202"));
    settings()->setThemes({});
    QCOMPARE(themes()->resolvedId(), QStringLiteral("hal-c2"));
  }

  void missingRolesComeFromTheDefaults() {
    settings()->setThemes({theme(QStringLiteral("dusk"), QStringLiteral("light"), QStringLiteral("#020202"))});
    save({{QStringLiteral("theme"), QStringLiteral("dusk")}});
    const QVariantMap colors = published().value(QStringLiteral("colors")).toMap();
    QVERIFY(colors.value(QStringLiteral("text")).toString().startsWith(QLatin1Char('#')));
    // Short form: a canvas and an accent paint the surfaces and the accents.
    settings()->setThemes({QJsonObject{{QStringLiteral("id"), QStringLiteral("dusk")},
                                       {QStringLiteral("appearance"), QStringLiteral("light")},
                                       {QStringLiteral("canvas"), QStringLiteral("#040404")},
                                       {QStringLiteral("accent"), QStringLiteral("#ff0000")}}});
    const QVariantMap seeded = published().value(QStringLiteral("colors")).toMap();
    QCOMPARE(seeded.value(QStringLiteral("sidebar")), QVariant(QStringLiteral("#040404")));
    QCOMPARE(seeded.value(QStringLiteral("focus")), QVariant(QStringLiteral("#ff0000")));
    // A theme with nothing drawable is skipped.
    settings()->setThemes({theme(QStringLiteral("dusk"), QStringLiteral("light"), QStringLiteral("not a colour"))});
    QCOMPARE(themes()->resolvedId(), QStringLiteral("hal-c2"));
  }

  void halvesOverTheChosenTheme() {
    save({{QStringLiteral("theme"), QStringLiteral("iris")}, {QStringLiteral("themeHalves"), QJsonObject{{QStringLiteral("dark"), QStringLiteral("ocean")}}}});
    QCOMPARE(themes()->resolvedId(), QStringLiteral("iris"));
    themes()->setSystemDark(true);
    QCOMPARE(themes()->resolvedId(), QStringLiteral("ocean"));
    QCOMPARE(themes()->appearance(), QStringLiteral("dark"));
    // Choosing a whole theme drops the halves.
    QVERIFY(themes()->choose(QStringLiteral("grove")));
    QCOMPARE(themes()->resolvedId(), QStringLiteral("grove"));
    QVERIFY(themes()->halves().isEmpty());
  }

  void aOneAppearanceThemeKeepsItsAppearance() {
    save({{QStringLiteral("customThemes"), QJsonArray{theme(QStringLiteral("midnight"), QStringLiteral("dark"), QStringLiteral("#050505"))}},
          {QStringLiteral("theme"), QStringLiteral("grove")}});
    // Chosen, it takes the dark half only.
    QVERIFY(themes()->choose(QStringLiteral("midnight")));
    QCOMPARE(themes()->themeId(), QStringLiteral("grove"));
    QCOMPARE(themes()->halves().value(QStringLiteral("dark")), QVariant(QStringLiteral("midnight")));
    QCOMPARE(themes()->resolvedId(), QStringLiteral("grove"));
    themes()->setSystemDark(true);
    QCOMPARE(canvas(), QStringLiteral("#050505"));
    // As the whole choice (a file written elsewhere), it is drawn in its own appearance.
    save({{QStringLiteral("customThemes"), QJsonArray{theme(QStringLiteral("midnight"), QStringLiteral("dark"), QStringLiteral("#050505"))}},
          {QStringLiteral("theme"), QStringLiteral("midnight")},
          {QStringLiteral("appearance"), QStringLiteral("light")}});
    QCOMPARE(themes()->appearance(), QStringLiteral("dark"));
    QCOMPARE(canvas(), QStringLiteral("#050505"));
  }

  // settings/search-and-navigation.feature: restoring defaults puts the whole
  // theme choice back at once, or, when it cannot be saved, none of it.
  void restoringDefaultsIsAllOrNothing() {
    const QString locked = m_dir.filePath(QStringLiteral("locked"));
    QVERIFY(QDir().mkpath(locked));
    settings()->setDevicePath(locked + QStringLiteral("/preferences.json"));
    save({{QStringLiteral("theme"), QStringLiteral("grove")},
          {QStringLiteral("appearance"), QStringLiteral("dark")},
          {QStringLiteral("themeHalves"), QJsonObject{{QStringLiteral("light"), QStringLiteral("grove")}}},
          {QStringLiteral("timestampFormat"), QStringLiteral("24-hour")}});
    // A directory that cannot be written to keeps the preferences unsaved.
    QFile::setPermissions(locked, QFileDevice::ReadOwner | QFileDevice::ExeOwner);
    const bool restored = themes()->restoreDefaults();
    QFile::setPermissions(locked, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    QVERIFY(!restored);
    QCOMPARE(themes()->themeId(), QStringLiteral("grove"));
    QCOMPARE(themes()->mode(), QStringLiteral("dark"));
    QVERIFY(!themes()->halves().isEmpty());
    const QVariantList toasts = m_bridge->state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
    QVERIFY(std::any_of(toasts.begin(), toasts.end(), [](const QVariant& toast) {
      return toast.toMap().value(QStringLiteral("title")) == QStringLiteral("Couldn’t restore theme settings");
    }));
    QVERIFY(themes()->restoreDefaults());
    QCOMPARE(themes()->themeId(), QString());
    QCOMPARE(themes()->mode(), QStringLiteral("system"));
    QVERIFY(themes()->halves().isEmpty());
    QCOMPARE(settings()->deviceSettings().value(QLatin1String("timestampFormat")), QJsonValue(QStringLiteral("24-hour")));
    // The rows go back together, in this device's store here.
    settings()->resetAll({QStringLiteral("timestampFormat"), QStringLiteral("unknown")});
    QVERIFY(settings()->isDefault(QStringLiteral("timestampFormat")));
    QVERIFY(!settings()->deviceSettings().contains(QLatin1String("timestampFormat")));
  }
};

QTEST_MAIN(tst_ThemeResolution)
#include "tst_ThemeResolution.moc"
