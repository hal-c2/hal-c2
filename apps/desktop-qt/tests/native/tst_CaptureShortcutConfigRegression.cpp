// CaptureShortcutConfig::edit on the bindings a user wrote by hand.

#include <QtTest>

#include "CaptureShortcutConfig.h"

using Config = CaptureShortcutConfig;

class CaptureShortcutConfigRegression : public QObject {
  Q_OBJECT

private slots:
  void removalTakesKeysNoCompositorChordParses() {
    QString error;
    const auto edit = Config::edit(QStringLiteral("bind = $mainMod, 2, global, hal-c2:capture-window\nbind = SUPER, T, exec, foot\n"),
                                   Config::Format::Hyprland, QStringLiteral("hal-c2"), false, {}, &error);
    QVERIFY2(edit.has_value(), qPrintable(error));
    QCOMPARE(edit->after, QStringLiteral("bind = SUPER, T, exec, foot\n"));
  }

  void aLuaBindingOnTheSameKeysIsAConflict_data() {
    QTest::addColumn<QString>("line");
    QTest::newRow("exec") << QStringLiteral("hl.bind(\"CTRL + SHIFT + 2\", hl.dsp.exec_cmd(\"foot\"))\n");
    QTest::newRow("another global") << QStringLiteral("hl.bind(\"CTRL + SHIFT + 2\", hl.dsp.global(\"other:thing\"))\n");
    QTest::newRow("function") << QStringLiteral("hl.bind('CTRL + SHIFT + 2', function()\n  print(1)\nend)\n");
  }
  void aLuaBindingOnTheSameKeysIsAConflict() {
    QFETCH(QString, line);
    QString error;
    QVERIFY(!Config::edit(line, Config::Format::HyprlandLua, QStringLiteral("hal-c2"), true, QStringLiteral("Ctrl+Shift+2"), &error));
    QVERIFY2(error.contains(QStringLiteral("already used")), qPrintable(error));
  }

  void aLuaCaptureBindingIsStillReplacedNotAConflict() {
    QString error;
    const auto edit = Config::edit(QStringLiteral("hl.bind(\"CTRL + SHIFT + 2\", hl.dsp.global(\"hal-c2:capture-window\"))\n"),
                                   Config::Format::HyprlandLua, QStringLiteral("hal-c2"), true, QStringLiteral("Ctrl+Alt+K"), &error);
    QVERIFY2(edit.has_value(), qPrintable(error));
    QVERIFY(!edit->after.contains(QStringLiteral("SHIFT")));
    QVERIFY(edit->after.contains(QStringLiteral("CTRL + ALT + K")));
  }
};

QTEST_GUILESS_MAIN(CaptureShortcutConfigRegression)
#include "tst_CaptureShortcutConfigRegression.moc"
