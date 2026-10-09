// What tests/prop/tst_KeysKeybindingsProp.cpp found in KeybindingController.

#include <QtTest>

#include "FakeMc.h"
#include "KeybindingController.h"
#include "McClient.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "TestTime.h"

namespace {

// The app on a fake MC that keeps keybindings.json, its stores in `home`. A
// remove drops the rules equal to the one asked for, as the MC's does.
struct Shell {
  explicit Shell(const QString& home) {
    mc.onShape(QStringLiteral("config"), [this](int id, const QJsonObject&) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config")},
               {QStringLiteral("id"), id},
               {QStringLiteral("mc"), mc.name},
               {QStringLiteral("config"), QJsonObject{{QStringLiteral("keybindingRules"), rules},
                                                     {QStringLiteral("settings"), QJsonObject()}}}});
    });
    mc.onRpc(QStringLiteral("hal-c2.removeKeybinding"), [this](const FakeMc::Rpc& rpc) {
      ++removes;
      auto answer = [this, rpc] {
        QJsonArray kept;
        for (const QJsonValue& rule : std::as_const(rules)) {
          if (rule != rpc.payload) kept.append(rule);
        }
        rules = kept;
        mc.reply(rpc, QJsonObject{{QStringLiteral("rules"), rules}});
        push();
      };
      if (mc.holding(QStringLiteral("keys"))) {
        mc.defer(answer);
      } else {
        answer();
      }
    });
    native = std::make_unique<NativeShell>(&bridge);
    native->client()->setRetryDelays({20});
    native->setStoreDirs(home + QStringLiteral("/state"), home + QStringLiteral("/data"), home + QStringLiteral("/cache"));
    native->controller<SettingsController>()->setDevicePath(home + QStringLiteral("/config/preferences.json"));
    native->restoreWindows();
    native->open(mc.origin(), QStringLiteral("mc-token"));
  }

  KeybindingController* keys() const { return native->controller<KeybindingController>(); }

  void push() {
    for (const int id : mc.subscribers(QStringLiteral("config"))) {
      mc.send({{QStringLiteral("t"), QStringLiteral("config.keybindings")}, {QStringLiteral("id"), id}, {QStringLiteral("rules"), rules}});
    }
  }

  // A round trip: what the MC sent before it has been read.
  bool sync() {
    bool done = false;
    native->client()->call(native.get(), mc.environmentId, QStringLiteral("test.barrier"), QJsonValue::Null,
                           [&done](const QJsonValue&, const std::optional<QString>&) { done = true; });
    return halc2::test::waitFor([&done] { return done; });
  }

  // The first row of `command`.
  QVariantMap row(const QString& command) const {
    for (const QVariant& value : keys()->bindings()) {
      if (value.toMap().value(QStringLiteral("command")) == command) return value.toMap();
    }
    return {};
  }

  FakeMc mc;
  QJsonArray rules;
  int removes = 0;
  ShellBridge bridge;
  std::unique_ptr<NativeShell> native;
};

QJsonObject rule(const QString& command, const QString& key) {
  return {{QStringLiteral("command"), command}, {QStringLiteral("key"), key}};
}

}  // namespace

class KeysKeybindingsRegression : public QObject {
  Q_OBJECT

private slots:
  // A row sent its key and condition as shown, "mod+shift+y" for a rule
  // written "shift+mod+y"; the MC matches the rule exactly, so the remove
  // (and a reset, or an edit replacing it) did nothing.
  void aRowRemovesTheRuleAsWritten() {
    QTemporaryDir home;
    Shell shell(home.path());
    shell.rules = {rule(QStringLiteral("chat.new"), QStringLiteral("shift+mod+y"))};
    HAL_C2_TRY_VERIFY(shell.native->isActive());
    HAL_C2_TRY_COMPARE(shell.keys()->customCount(), 1);
    const QVariantMap row = shell.row(QStringLiteral("chat.new"));
    QCOMPARE(row.value(QStringLiteral("key")).toString(), QStringLiteral("mod+shift+y"));

    shell.keys()->remove(row);
    HAL_C2_TRY_COMPARE(shell.keys()->customCount(), 0);
    QVERIFY(shell.rules.isEmpty());
  }

  // With a call already on its way, another one said "saving" changed
  // when it stayed true.
  void savingChangesOnlyWhenItDoes() {
    QTemporaryDir home;
    Shell shell(home.path());
    shell.rules = {rule(QStringLiteral("chat.new"), QStringLiteral("mod+y")),
                   rule(QStringLiteral("diff.toggle"), QStringLiteral("mod+u"))};
    HAL_C2_TRY_VERIFY(shell.native->isActive());
    HAL_C2_TRY_COMPARE(shell.keys()->customCount(), 2);
    QSignalSpy saving(shell.keys(), &KeybindingController::savingChanged);
    shell.mc.hold(QStringLiteral("keys"));
    shell.keys()->remove(shell.row(QStringLiteral("chat.new")));
    shell.keys()->remove(shell.row(QStringLiteral("diff.toggle")));
    QCOMPARE(saving.count(), 1);
    QVERIFY(shell.keys()->saving());

    HAL_C2_TRY_COMPARE(shell.removes, 2);
    shell.mc.answerHeld();
    HAL_C2_TRY_VERIFY(!shell.keys()->saving());
    QCOMPARE(saving.count(), 2);
  }

  // A rule that does not parse, swapped for another that does not, changes
  // neither the rows nor how many rules there are, yet repainted the list.
  void anUnparsedRuleRepaintsNothing() {
    QTemporaryDir home;
    Shell shell(home.path());
    shell.rules = {rule(QStringLiteral("chat.new"), QStringLiteral("mod+k+j"))};
    HAL_C2_TRY_VERIFY(shell.native->isActive());
    HAL_C2_TRY_COMPARE(shell.keys()->customCount(), 1);
    const QVariantList rows = shell.keys()->bindings();
    QSignalSpy bindings(shell.keys(), &KeybindingController::bindingsChanged);

    shell.rules = {rule(QStringLiteral("chat.new"), QStringLiteral("mod+j+k"))};
    shell.push();
    QVERIFY(shell.sync());
    QCOMPARE(shell.keys()->bindings(), rows);
    QCOMPARE(bindings.count(), 0);

    // Its count still tells: one more is a change.
    shell.rules.append(rule(QStringLiteral("diff.toggle"), QStringLiteral("mod+j+k")));
    shell.push();
    HAL_C2_TRY_COMPARE(shell.keys()->customCount(), 2);
    QCOMPARE(bindings.count(), 1);
  }

  // `a0 && a1 && ... && a66` parsed but printed as 66 nested brackets, deeper
  // than a condition may nest, so the settings page saved text that no longer
  // loaded.
  void aLongChainReadsBackAsWritten_data() {
    QTest::addColumn<QString>("op");
    QTest::addColumn<int>("terms");
    for (const int terms : {2, 66, 67, 100, 120}) {
      QTest::addRow("and %d", terms) << QStringLiteral("&&") << terms;
      QTest::addRow("or %d", terms) << QStringLiteral("||") << terms;
    }
  }
  void aLongChainReadsBackAsWritten() {
    QFETCH(QString, op);
    QFETCH(int, terms);
    QStringList names;
    for (int index = 0; index < terms; ++index) names.append(QStringLiteral("a%1").arg(index));
    const QString text = names.join(QLatin1Char(' ') + op + QLatin1Char(' '));
    const keybindings::WhenPtr when = keybindings::parseWhen(text);
    QVERIFY(when);
    QCOMPARE(keybindings::whenText(when), text);
    QVERIFY(keybindings::parseWhen(keybindings::whenText(when)));
  }

  // Brackets only where they change the grouping.
  void bracketsOnlyWhereTheyGroup() {
    for (const QString& text : {QStringLiteral("a && b || c && !d"), QStringLiteral("a && (b || c)"),
                                QStringLiteral("a && (b && c)"), QStringLiteral("a || (b || c)"),
                                QStringLiteral("!(a && b) || !!c"), QStringLiteral("(a || b) && (c || d) && e")}) {
      const keybindings::WhenPtr when = keybindings::parseWhen(text);
      QVERIFY2(when, qPrintable(text));
      QCOMPARE(keybindings::whenText(when), text);
    }
    QCOMPARE(keybindings::whenText(keybindings::parseWhen(QStringLiteral("((a && b)) && c"))), QStringLiteral("a && b && c"));
  }

  // A chain is as deep as it is long, and evaluating or printing it recurses
  // that deep, so a condition has a size cap as it has a depth cap; the
  // settings page says so as it does of one nested too deep.
  void aHugeChainIsRefused() {
    QTemporaryDir home;
    Shell shell(home.path());
    QStringList names;
    for (int index = 0; index < 300; ++index) names.append(QStringLiteral("a%1").arg(index));
    const QString text = names.join(QStringLiteral(" && "));
    QVERIFY(!keybindings::parseWhen(text));
    QVERIFY(!keybindings::parseWhen(QStringLiteral("!").repeated(60) + names.join(QStringLiteral(" || !!!!"))));
    QVERIFY(!shell.keys()->whenError(text).isEmpty());
    QVERIFY(!keybindings::compile({QStringLiteral("mod+k"), QStringLiteral("chat.new"), text}));
    QVERIFY(keybindings::parseWhen(names.mid(0, 120).join(QStringLiteral(" && "))));
  }
};

int main(int argc, char** argv) {
  // Every store the shell opens, in a home of its own.
  QTemporaryDir root(QDir::tempPath() + QStringLiteral("/keys-regression-XXXXXX"));
  const QByteArray path = QFile::encodeName(root.path());
  qputenv("HOME", path);
  qputenv("HAL_C2_HOME", path + "/hal-c2");
  qputenv("XDG_CONFIG_HOME", path + "/config");
  qputenv("XDG_DATA_HOME", path + "/data");
  qputenv("XDG_STATE_HOME", path + "/state");
  qputenv("XDG_CACHE_HOME", path + "/cache");
  QStandardPaths::setTestModeEnabled(true);
  QGuiApplication app(argc, argv);
  KeysKeybindingsRegression test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_KeysKeybindingsRegression.moc"
