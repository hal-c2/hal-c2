// The shell's own toasts (ToastController): what the user sees in `toasts`,
// and dismissing them or choosing their action as the Notifications brick does
// (features/navigation/toasts.feature, desktop/native-toasts.feature).

#include <QVariantList>

#include "Harness.h"
#include "World.h"

namespace {

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

std::optional<QVariantMap> toastTitled(World& world, const QString& title) {
  for (const QVariant& item : toasts(world)) {
    if (item.toMap().value(QStringLiteral("title")).toString() == title) return item.toMap();
  }
  return std::nullopt;
}

QVariantMap waitForToast(World& world, const QString& title) {
  world.waitFor([&] { return toastTitled(world, title).has_value(); },
                [&] { return QStringLiteral("the toast \"%1\"; the shell shows %2").arg(title, show(toasts(world))); });
  return *toastTitled(world, title);
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user sees an? %1 toast %1 saying %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, c[1]);
    expect(toast.value(QStringLiteral("type")) == c[0] && toast.value(QStringLiteral("description")) == c[2],
           QStringLiteral("the toast is %1").arg(show(toast)));
  });
  step(QStringLiteral("the user sees an? %1 toast %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, c[1]);
    expect(toast.value(QStringLiteral("type")) == c[0], QStringLiteral("the toast is %1").arg(show(toast)));
  });
  step(QStringLiteral("the user sees an? %1 toast %1 offering %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, c[1]);
    const QVariantList actions = toast.value(QStringLiteral("actions")).toList();
    expect(toast.value(QStringLiteral("type")) == c[0] && actions.size() == 1 &&
               actions.first().toMap().value(QStringLiteral("label")) == c[2],
           QStringLiteral("the toast is %1").arg(show(toast)));
  });
  step(QStringLiteral("the toast %1 offers %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, c[0]);
    QStringList labels;
    for (const QVariant& action : toast.value(QStringLiteral("actions")).toList()) {
      labels.append(action.toMap().value(QStringLiteral("label")).toString());
    }
    labels.sort();
    QStringList wanted{c[1], c[2]};
    wanted.sort();
    expect(labels == wanted, QStringLiteral("the toast is %1").arg(show(toast)));
  });
  step(QStringLiteral("the user sees the toast %1 once").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForToast(world, c[0]);
    world.sync();
    qsizetype count = 0;
    for (const QVariant& item : toasts(world)) count += item.toMap().value(QStringLiteral("title")).toString() == c[0];
    expect(count == 1, QStringLiteral("the shell shows %1").arg(show(toasts(world))));
  });
  step(QStringLiteral("the toast %1 is gone").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(!toastTitled(world, c[0]), QStringLiteral("the shell shows %1").arg(show(toasts(world))));
  });
  step(QStringLiteral("the user sees (\\d+) toasts"), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(toasts(world).size() == c[0].toInt(), QStringLiteral("the shell shows %1").arg(show(toasts(world))));
  });
  // The pointer over the stack, or a tap on it on a phone, as the brick says.
  step(QStringLiteral("the user (expands|collapses) the toasts"), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("notification.expand"),
                            QVariantMap{{QStringLiteral("expanded"), c[0] == QLatin1String("expands")}});
  });
  step(QStringLiteral("the user sees no toast"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(toasts(world).isEmpty(), QStringLiteral("the shell shows %1").arg(show(toasts(world))));
  });
  step(QStringLiteral("the user chooses %1 on the toast %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, c[1]);
    for (const QVariant& action : toast.value(QStringLiteral("actions")).toList()) {
      if (action.toMap().value(QStringLiteral("label")) != c[0]) continue;
      world.bridge().dispatch(QStringLiteral("notification.action"),
                              QVariantMap{{QStringLiteral("id"), toast.value(QStringLiteral("id"))},
                                          {QStringLiteral("actionId"), action.toMap().value(QStringLiteral("id"))}});
      return;
    }
    fail(QStringLiteral("the toast is %1").arg(show(toast)));
  });
  step(QStringLiteral("the user dismisses the toast %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap toast = waitForToast(world, c[0]);
    world.bridge().dispatch(QStringLiteral("notification.dismiss"),
                            QVariantMap{{QStringLiteral("id"), toast.value(QStringLiteral("id"))}});
  });
  step(QStringLiteral("(\\d+) seconds? pass(?:es)?"), [](World& world, const Captures& c, const Table&) {
    world.setTime(world.now().addSecs(c[0].toInt()));
  });
});

}  // namespace
