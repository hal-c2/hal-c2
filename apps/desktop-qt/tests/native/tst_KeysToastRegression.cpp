// What tests/prop/tst_KeysToastProp.cpp found in ToastController, and the
// stack that replaced its cap.

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

bool expanded(ShellBridge& bridge) {
  return bridge.state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("expanded")).toBool();
}

QVariantMap expand(bool to) {
  return {{QStringLiteral("expanded"), to}};
}

// A controller on a clock the test moves.
struct Clocked {
  ShellBridge bridge;
  ToastController toasts{&bridge, nullptr};
  QDateTime now = QDateTime::fromString(QStringLiteral("2026-09-23T10:00:00Z"), Qt::ISODate);

  Clocked() {
    toasts.setClock([this] { return now; });
    toasts.activate();
  }
  void pass(int ms) {
    now = now.addMSecs(ms);
    toasts.expire();
  }
};

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

  // Past five toasts the oldest used to drop off, a refused send's "Restore
  // prompt" with it and the prompt lost.
  void aPersistentToastOutlastsAnyNumberOfNewerOnes() {
    ShellBridge bridge;
    ToastController toasts(&bridge, nullptr);
    toasts.activate();
    int restored = 0;
    const QString id = toasts.show(QStringLiteral("error"), QStringLiteral("Send refused"), {},
                                   ToastController::Action{QStringLiteral("Restore prompt"), [&restored] { ++restored; }},
                                   0);
    for (int i = 0; i < 12; ++i) toasts.show(QStringLiteral("info"), QStringLiteral("Saved"), {}, {}, 0);
    QCOMPARE(items(bridge).size(), 13);
    QCOMPARE(items(bridge).last().toMap().value(QStringLiteral("id")).toString(), id);
    QVERIFY(toasts.handle(QStringLiteral("notification.action"), click(id, QStringLiteral("primary"))));
    QCOMPARE(restored, 1);
  }

  // As Base UI's: while the stack is expanded no toast's time runs, and it
  // takes up the time it had left once it collapses.
  void anExpandedStackHoldsTheTime() {
    Clocked clock;
    clock.toasts.show(QStringLiteral("error"), QStringLiteral("Failed"));
    clock.pass(4000);
    QVERIFY(clock.toasts.handle(QStringLiteral("notification.expand"), expand(true)));
    QVERIFY(expanded(clock.bridge));
    clock.pass(60000);
    QCOMPARE(items(clock.bridge).size(), 1);
    clock.toasts.handle(QStringLiteral("notification.expand"), expand(false));
    clock.pass(999);
    QCOMPARE(items(clock.bridge).size(), 1);
    clock.pass(1);
    QVERIFY(items(clock.bridge).isEmpty());
  }

  // A toast shown into an expanded stack waits for it to collapse.
  void aToastShownWhileExpandedStartsOnCollapse() {
    Clocked clock;
    clock.toasts.show(QStringLiteral("info"), QStringLiteral("First"), {}, {}, 0);
    clock.toasts.setExpanded(true);
    clock.toasts.show(QStringLiteral("info"), QStringLiteral("Second"), {}, {}, 1000);
    clock.pass(5000);
    QCOMPARE(items(clock.bridge).size(), 2);
    clock.toasts.setExpanded(false);
    clock.pass(1000);
    QCOMPARE(items(clock.bridge).size(), 1);
  }

  // The stack collapses with its last toast, so the next one's time runs
  // even though nothing said the pointer left.
  void theLastToastGoingCollapsesTheStack() {
    Clocked clock;
    const QString id = clock.toasts.show(QStringLiteral("info"), QStringLiteral("First"), {}, {}, 0);
    clock.toasts.setExpanded(true);
    clock.toasts.handle(QStringLiteral("notification.dismiss"), QVariantMap{{QStringLiteral("id"), id}});
    QVERIFY(!expanded(clock.bridge));
    QVERIFY(!clock.toasts.expanded());
    clock.toasts.show(QStringLiteral("info"), QStringLiteral("Second"), {}, {}, 1000);
    clock.pass(1000);
    QVERIFY(items(clock.bridge).isEmpty());
  }

  // Settling, snoozing and archiving in a row left a toast reading only the
  // verb for each; the undo notice counts the threads it will restore, and one
  // Undo takes them all back.
  void consecutiveUndoNoticesOfOneKindJoinAndUndoTogether() {
    ShellBridge bridge;
    ToastController toasts(&bridge, nullptr);
    toasts.activate();
    QStringList undone;
    const QString first = toasts.showUndo(QStringLiteral("Settled"), QStringLiteral("Settled"), [&undone] { undone.append(QStringLiteral("a")); });
    QCOMPARE(items(bridge).first().toMap().value(QStringLiteral("title")).toString(), QStringLiteral("Settled"));
    QCOMPARE(toasts.showUndo(QStringLiteral("Settled"), QStringLiteral("Settled"), [&undone] { undone.append(QStringLiteral("b")); }), first);
    toasts.showUndo(QStringLiteral("Settled"), QStringLiteral("Settled"), [&undone] { undone.append(QStringLiteral("c")); });
    QCOMPARE(items(bridge).size(), 1);
    QCOMPARE(items(bridge).first().toMap().value(QStringLiteral("title")).toString(), QStringLiteral("Settled 3 threads"));
    // Another kind starts its own notice.
    toasts.showUndo(QStringLiteral("Archived"), QStringLiteral("Archived"), [&undone] { undone.append(QStringLiteral("x")); });
    QCOMPARE(items(bridge).size(), 2);
    QVERIFY(toasts.runAction(QStringLiteral("Undo")));
    QCOMPARE(undone, QStringList{QStringLiteral("x")});
    QVERIFY(toasts.runAction(QStringLiteral("Undo")));
    QCOMPARE(undone, (QStringList{QStringLiteral("x"), QStringLiteral("c"), QStringLiteral("b"), QStringLiteral("a")}));
    QVERIFY(items(bridge).isEmpty());
  }

  // Nothing to expand: an empty stack stays collapsed.
  void anEmptyStackDoesNotExpand() {
    Clocked clock;
    clock.toasts.setExpanded(true);
    QVERIFY(!expanded(clock.bridge));
  }
};

QTEST_GUILESS_MAIN(KeysToastRegression)
#include "tst_KeysToastRegression.moc"
