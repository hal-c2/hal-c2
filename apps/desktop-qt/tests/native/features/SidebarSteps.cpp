// The native sidebar: row actions, its scope and snooze menu, and the sections
// it shows (features/desktop/native-sidebar.feature).

#include <QVariantList>

#include "Harness.h"
#include "Turn.h"
#include "World.h"

namespace {

QVariantMap keyed(const QString& key) {
  return {{QStringLiteral("key"), key}};
}

QString sectionTitles(World& world, const QString& section) {
  QStringList titles;
  for (const QVariant& row : at(world.state(QStringLiteral("sidebar")), section).toList()) {
    titles.append(row.toMap().value(QStringLiteral("title")).toString());
  }
  return titles.join(QStringLiteral(", "));
}

const Steps steps([] {
  const QString q = kQuoted;

  // The user in the shell.
  const auto dispatch = [](const QString& type) {
    return [type](World& world, const Captures& c, const Table&) { world.bridge().dispatch(type, keyed(c[0])); };
  };
  step(QStringLiteral("the user settles %1").arg(q), dispatch(QStringLiteral("thread.settle")));
  step(QStringLiteral("the user un-settles %1").arg(q), dispatch(QStringLiteral("thread.unsettle")));
  step(QStringLiteral("the user wakes %1").arg(q), dispatch(QStringLiteral("thread.unsnooze")));
  step(QStringLiteral("the user marks %1 unread").arg(q), dispatch(QStringLiteral("thread.markUnread")));
  step(QStringLiteral("the user dismisses the woke pill on %1").arg(q), dispatch(QStringLiteral("thread.wokeDismiss")));
  step(QStringLiteral("the user dispatches %1 for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(c[0], keyed(c[1]));
  });
  step(QStringLiteral("the user scopes the sidebar to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("sidebar.scope"), QVariantMap{{QStringLiteral("projectKey"), world.projectKey(c[0])}});
  });
  step(QStringLiteral("the user clears the sidebar's scope"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("sidebar.scope"),
                            QVariantMap{{QStringLiteral("projectKey"), QVariant::fromValue(nullptr)}});
  });
  step(QStringLiteral("the user opens the snooze menu for %1 at (\\d+), (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("thread.snoozeMenu"), QVariantMap{
                                                                     {QStringLiteral("key"), c[0]},
                                                                     {QStringLiteral("x"), c[1].toDouble()},
                                                                     {QStringLiteral("y"), c[2].toDouble()},
                                                                 });
  });
  const auto choose = [](World& world, const QVariant& id) {
    const QVariant menu = world.state(QStringLiteral("menu"));
    expect(menu.typeId() == QMetaType::QVariantMap, QStringLiteral("no menu is open"));
    world.bridge().dispatch(QStringLiteral("menu.select"),
                            QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), id}});
  };
  step(QStringLiteral("the user picks %1").arg(q), [choose](World& world, const Captures& c, const Table&) {
    // With no menu open, the pick is an answer to the agent's question.
    world.sync();  // a menu can open on the node's answer
    if (world.state(QStringLiteral("menu")).typeId() != QMetaType::QVariantMap) return pickAnswer(world, c[0]);
    choose(world, c[0]);
  });
  step(QStringLiteral("the user dismisses the menu"), [choose](World& world, const Captures&, const Table&) {
    choose(world, QVariant::fromValue(nullptr));
  });

  // The sidebar and menu the shell shows.
  step(QStringLiteral("the sidebar's %1 section lists %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QString titles = sectionTitles(world, c[0]);
    expect(titles == c[1], QStringLiteral("%1 lists \"%2\"").arg(c[0], titles));
  });
  step(QStringLiteral("the sidebar's %1 section is empty").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QString titles = sectionTitles(world, c[0]);
    expect(titles.isEmpty(), QStringLiteral("%1 lists \"%2\"").arg(c[0], titles));
  });
  step(QStringLiteral("the page is told the sidebar is scoped to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QList<PageAction> scopes = world.actionsOf(QStringLiteral("sidebar.scope"));
    expect(!scopes.isEmpty() && scopes.last().payload.value(QStringLiteral("projectKey")) == world.projectKey(c[0]),
           QStringLiteral("the page got %1").arg(world.describePage()));
  });
  step(QStringLiteral("the sidebar is not scoped"), [](World& world, const Captures&, const Table&) {
    const QVariant scope = at(world.state(QStringLiteral("sidebar")), QStringLiteral("scopeProjectKey"));
    expect(scope.isNull(), QStringLiteral("the sidebar is scoped to %1").arg(scope.toString()));
  });
  step(QStringLiteral("the shell shows a menu at (\\d+), (\\d+) with:"), [](World& world, const Captures& c, const Table& table) {
    world.sync();
    const QVariant menu = world.state(QStringLiteral("menu"));
    expect(at(menu, QStringLiteral("x")).toInt() == c[0].toInt() && at(menu, QStringLiteral("y")).toInt() == c[1].toInt(),
           QStringLiteral("the menu is %1").arg(show(menu)));
    Table actual{table.first()};
    for (const QVariant& item : at(menu, QStringLiteral("items")).toList()) {
      actual.append({item.toMap().value(QStringLiteral("id")).toString(), item.toMap().value(QStringLiteral("label")).toString()});
    }
    expect(actual == table, QStringLiteral("the menu is %1").arg(show(menu)));
  });
  step(QStringLiteral("the menu closes"), [](World& world, const Captures&, const Table&) {
    const QVariant menu = world.state(QStringLiteral("menu"));
    expect(menu.isNull(), QStringLiteral("the menu is %1").arg(show(menu)));
  });
});

}  // namespace
