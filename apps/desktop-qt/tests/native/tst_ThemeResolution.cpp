// How ThemeController resolves the theme it publishes: built-in, then this
// device's, then the MC's; halves over the chosen theme; the standard look
// when nothing matches; and the colours every theme is drawn in.

#include <QDir>
#include <QDirIterator>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
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

  // What a picker previews a theme with: its canvas, accent and text in the
  // appearance drawn now, and the standard look's beside them.
  void everyThemeOfferedCarriesItsSwatch() {
    const auto swatchOf = [this](const QString& id) {
      for (const QVariant& theme : themes()->available()) {
        if (theme.toMap().value(QStringLiteral("id")) == id) return theme.toMap().value(QStringLiteral("swatch")).toStringList();
      }
      return QStringList();
    };
    QCOMPARE(themes()->standardSwatch().value(0), QStringLiteral("#fcfcfc"));
    const QStringList light = swatchOf(QStringLiteral("grove"));
    for (const QVariant& theme : themes()->available()) {
      const QStringList swatch = theme.toMap().value(QStringLiteral("swatch")).toStringList();
      QCOMPARE(swatch.size(), 3);
      for (const QString& color : swatch) QVERIFY2(QColor(color).isValid(), qPrintable(theme.toMap().value(QStringLiteral("id")).toString()));
    }
    themes()->setSystemDark(true);
    QCOMPARE(themes()->standardSwatch().value(0), QStringLiteral("#0a0a0a"));
    QVERIFY(swatchOf(QStringLiteral("grove")) != light);
    // A theme without the appearance drawn shows the one it has.
    save({{QStringLiteral("customThemes"), QJsonArray{theme(QStringLiteral("mine"), QStringLiteral("light"), QStringLiteral("#010101"))}}});
    QCOMPARE(swatchOf(QStringLiteral("mine")).value(0), QStringLiteral("#010101"));
  }

  // A role no theme carries is drawn in its fallback, in light themes too (a
  // "popover" dialog stayed near-black): every role the bricks ask the palette
  // for by name comes with every theme, or is one a theme may add.
  void bricksPaintWithRolesEveryThemeHas() {
    // Drawn in the brick's own fallback unless a theme names them.
    const QStringList optional{QStringLiteral("projectForeground"), QStringLiteral("branchForeground"),
                               QStringLiteral("sidebarActiveIndicator"), QStringLiteral("scrim")};
    static const QRegularExpression read(QStringLiteral("palette\\.color\\(\"([A-Za-z0-9]+)\""));
    QStringList unknown;
    int found = 0;
    for (const bool dark : {false, true}) {
      themes()->setSystemDark(dark);
      const QVariantMap colors = published().value(QStringLiteral("colors")).toMap();
      for (const char* dir : {"/qml", "/../mobile-qt/qml"}) {
        QDirIterator files(QString::fromUtf8(HAL_C2_TEST_SOURCE_DIR) + QLatin1String(dir), {QStringLiteral("*.qml")}, QDir::Files, QDirIterator::Subdirectories);
        while (files.hasNext()) {
          QFile file(files.next());
          QVERIFY(file.open(QIODevice::ReadOnly));
          auto matches = read.globalMatch(QString::fromUtf8(file.readAll()));
          while (matches.hasNext()) {
            const QString role = matches.next().captured(1);
            ++found;
            const QString where = QFileInfo(file).fileName() + QLatin1Char(':') + role;
            if (!colors.contains(role) && !optional.contains(role) && !unknown.contains(where)) unknown.append(where);
          }
        }
      }
    }
    QVERIFY(found > 100);
    QVERIFY2(unknown.isEmpty(), qPrintable(unknown.join(QStringLiteral(", "))));
  }

  void builtInsWinTheirIds() {
    // A saved theme cannot take a built-in's (or a reserved) id.
    save({{QStringLiteral("customThemes"), QJsonArray{theme(QStringLiteral("grove"), QStringLiteral("light"), QStringLiteral("#010101"))}},
          {QStringLiteral("theme"), QStringLiteral("grove")}});
    QCOMPARE(themes()->resolvedId(), QStringLiteral("grove"));
    QVERIFY(canvas() != QStringLiteral("#010101"));
    QCOMPARE(canvas(), ThemeController::canonicalColor(QStringLiteral("oklch(0.972369 0.005497 157.15)")));
  }

  // The standard look has no row of its own to give way, so an imported file
  // may not take its id, named or made from the name "HAL-C2".
  void anImportedThemeCannotTakeTheStandardLooksId() {
    const QVariantList before = themes()->available();
    for (const QJsonObject& extra : {QJsonObject{{QStringLiteral("id"), QStringLiteral("hal-c2")}}, QJsonObject{}}) {
      QJsonObject file{{QStringLiteral("version"), 1},
                       {QStringLiteral("name"), QStringLiteral("HAL-C2")},
                       {QStringLiteral("appearance"), QStringLiteral("dark")},
                       {QStringLiteral("colors"), QJsonObject{{QStringLiteral("canvas"), QStringLiteral("#101010")}}}};
      for (auto it = extra.begin(); it != extra.end(); ++it) file.insert(it.key(), it.value());
      QVERIFY(!themes()->importText(QString::fromUtf8(QJsonDocument(file).toJson())));
      QCOMPARE(themes()->importError(), QStringLiteral("The theme id \"hal-c2\" is reserved."));
      themes()->clearImport();
    }
    QCOMPARE(themes()->available(), before);
  }

  // A published theme may not take the standard look's id either: it would
  // offer a second "hal-c2" row beside the standard look.
  void aPublishedThemeCannotTakeTheStandardLooksId() {
    const QVariantList before = themes()->available();
    settings()->setThemes({theme(QStringLiteral("hal-c2"), QStringLiteral("dark"), QStringLiteral("#020202"))});
    QCOMPARE(themes()->available(), before);
    QCOMPARE(themes()->resolvedId(), QStringLiteral("hal-c2"));
    settings()->setThemes({});
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

  // draft("") starts from the theme actually drawn: a single-appearance
  // theme chosen as a half (no whole theme set) is that draft, not the
  // standard look.
  void aDraftWithNoIdStartsFromTheDrawnHalf() {
    save({{QStringLiteral("customThemes"), QJsonArray{theme(QStringLiteral("midnight"), QStringLiteral("dark"), QStringLiteral("#050505"))}}});
    QVERIFY(themes()->choose(QStringLiteral("midnight")));
    QCOMPARE(themes()->themeId(), QString());
    themes()->setSystemDark(true);
    QCOMPARE(themes()->resolvedId(), QStringLiteral("midnight"));
    const QVariantMap drawn = themes()->draft(QString());
    QCOMPARE(drawn.value(QStringLiteral("label")), QVariant(QStringLiteral("midnight")));
    QCOMPARE(drawn.value(QStringLiteral("colors")).toMap().value(QStringLiteral("canvas")), QVariant(QStringLiteral("#050505")));
    // In the other appearance nothing is chosen, so the standard look is drawn and drafted.
    themes()->setSystemDark(false);
    QCOMPARE(themes()->draft(QString()).value(QStringLiteral("label")), QVariant(QStringLiteral("HAL-C2")));
  }

  // A choice that no longer resolves draws the standard look, so that is what
  // is drafted -- not a legacy saved theme that holds the standard id.
  void aDraftWithAStaleChoiceStartsFromTheStandardLook() {
    save({{QStringLiteral("customThemes"), QJsonArray{theme(QStringLiteral("hal-c2"), QStringLiteral("dark"), QStringLiteral("#050505"))}},
          {QStringLiteral("theme"), QStringLiteral("gone")}});
    QCOMPARE(themes()->resolvedId(), QStringLiteral("hal-c2"));
    const QVariantMap drawn = themes()->draft(QString());
    QVERIFY(drawn.value(QStringLiteral("id")).toString().isEmpty());
    QCOMPARE(drawn.value(QStringLiteral("label")), QVariant(QStringLiteral("HAL-C2")));
    // Chosen on purpose, the legacy theme is drafted.
    save({{QStringLiteral("customThemes"), QJsonArray{theme(QStringLiteral("hal-c2"), QStringLiteral("dark"), QStringLiteral("#050505"))}},
          {QStringLiteral("theme"), QStringLiteral("hal-c2")}});
    QCOMPARE(themes()->draft(QString()).value(QStringLiteral("id")), QVariant(QStringLiteral("hal-c2")));
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
