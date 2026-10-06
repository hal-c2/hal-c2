// The thread list at home and a thread's own screen (features/mobile/
// navigation-and-deep-links.feature, and the Backgrounds of the others).

#include <QJsonObject>
#include <QQuickItem>

#include "Harness.h"
#include "Phone.h"
#include "World.h"

QString haveThread(World& world, const QString& title) {
  for (auto it = world.mc.threads.cbegin(); it != world.mc.threads.cend(); ++it) {
    if (it->value(QLatin1String("title")).toString() == title) return it.key();
  }
  const QString id = QStringLiteral("thread-%1").arg(world.mc.threads.size() + 1);
  world.mc.threads.insert(id, {{QStringLiteral("id"), id},
                               {QStringLiteral("title"), title},
                               {QStringLiteral("projectId"), QStringLiteral("shop")},
                               {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                               {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  // To a phone already connected it arrives as a row; the next snapshot has it either way.
  world.mc.sendRow(id, world.mc.threads.value(id));
  return id;
}

QQuickItem* threadRow(World& world, const QString& title) {
  QQuickItem* row = nullptr;
  world.waitFor(
      [&] {
        row = world.findWhere([&](QQuickItem* candidate) {
          return candidate->objectName().startsWith(QLatin1String("threadRow:")) &&
                 candidate->property("item").toMap().value(QStringLiteral("title")).toString() == title;
        });
        return row != nullptr;
      },
      [&] { return QStringLiteral("%1 in the thread list; the screen says: %2").arg(title, world.texts().join(QStringLiteral(" | "))); });
  return row;
}

void openThread(World& world, const QString& title) {
  world.item(QStringLiteral("homeScreen"));
  world.tap(threadRow(world, title));
  world.waitFor([&] { return world.find(QStringLiteral("threadScreen")) != nullptr || world.popupShowing(QStringLiteral("mobileMenu")); },
                [&] { return QStringLiteral("the thread's screen; the screen says: %1").arg(world.texts().join(QStringLiteral(" | "))); });
  expect(!world.popupShowing(QStringLiteral("mobileMenu")), QStringLiteral("a tap on %1 opened its menu, not the thread").arg(title));
  world.waitFor([&] { return world.item(QStringLiteral("title"))->property("text").toString() == title; },
                [&] { return QStringLiteral("the thread's screen; the screen says: %1").arg(world.texts().join(QStringLiteral(" | "))); });
}

namespace {

const Steps steps([] {
  using S = QString;

  step(S("%1 has the thread %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == world.mc.label, S("the phone is paired with %1").arg(world.mc.label));
    haveThread(world, c[1]);
    threadRow(world, c[1]);
  });

  step(S("the user opens %1 from the home screen").arg(kQuoted), [](World& world, const Captures& c, const Table&) { openThread(world, c[0]); });

  // Opened and left again: the phone has loaded it once.
  step(S("the user has opened the thread %1 before").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.thread = haveThread(world, c[0]);
    openThread(world, c[0]);
    world.back();
    world.item(S("homeScreen"));
  });

  step(S("going back returns to the home screen"), [](World& world, const Captures&, const Table&) {
    world.item(S("threadScreen"));
    world.back();
    world.waitFor([&] { return world.find(S("homeScreen")) != nullptr && world.find(S("threadScreen")) == nullptr; },
                  [&] { return S("the home screen; the screen says: %1").arg(world.texts().join(S(" | "))); });
    expect(world.state(S("route")).toMap().value(S("kind")) == QLatin1String("home"), S("the route is %1").arg(show(world.state(S("route")))));
  });
});

}  // namespace
