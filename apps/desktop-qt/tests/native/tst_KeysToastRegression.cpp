// What tests/prop/tst_KeysToastProp.cpp found in ToastController.

#include <QtTest>

#include "ShellBridge.h"
#include "ToastController.h"

namespace {

QVariantList items(ShellBridge& bridge) {
  return bridge.state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

QVariantMap click(const QString& id, const QString& actionId) {
  return {{QStringLiteral("id"), id}, {QStringLiteral("actionId"), actionId}};
}

}  // namespace

class KeysToastRegression : public QObject {
  Q_OBJECT

private slots:
  // A click on a secondary action the toast no longer offers, replace() having
  // dropped it under the pointer, used to dismiss the toast.
  void clickOnAMissingActionKeepsTheToast() {
    ShellBridge bridge;
    ToastController toasts(&bridge, nullptr);
    toasts.activate();
    int ran = 0;
    const QString id = toasts.showActions(QStringLiteral("info"), QStringLiteral("Cloning"), {},
                                          {{QStringLiteral("Cancel"), [&ran] { ++ran; }, true, {}}}, 0);
    QVERIFY(toasts.handle(QStringLiteral("notification.action"), click(id, QStringLiteral("secondary"))));
    QCOMPARE(items(bridge).size(), 1);
    QCOMPARE(ran, 0);
  }

  // The undo shortcut ran the toast's third action as its second, the one
  // shown with a button: a toast offers two.
  void runActionSkipsAThirdAction() {
    ShellBridge bridge;
    ToastController toasts(&bridge, nullptr);
    toasts.activate();
    QStringList ran;
    const auto action = [&ran](const QString& label) {
      return ToastController::Action{label, [&ran, label] { ran.append(label); }};
    };
    toasts.showActions(QStringLiteral("info"), QStringLiteral("Archived"), {},
                       {action(QStringLiteral("Open")), action(QStringLiteral("Retry")), action(QStringLiteral("Undo"))},
                       0);
    QVERIFY(!toasts.runAction(QStringLiteral("Undo")));
    QVERIFY(ran.isEmpty());
    QCOMPARE(items(bridge).size(), 1);
  }
};

QTEST_GUILESS_MAIN(KeysToastRegression)
#include "tst_KeysToastRegression.moc"
