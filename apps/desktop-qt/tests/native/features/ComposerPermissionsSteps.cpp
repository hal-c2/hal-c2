// Where the composer names a thread's permissions: always on a started
// thread's toolbar, in a new thread's context strip, and in the model
// control's footer (features/composer/model-and-mode.feature).

#include <algorithm>

#include <QJsonObject>
#include <QQuickItem>
#include <QStringList>
#include <QTest>

#include "Brick.h"
#include "ComposerBrick.h"
#include "Harness.h"
#include "Stream.h"
#include "World.h"

using namespace stream;

namespace {

QVariantMap composer(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

QQuickItem* part(World& world, const QString& objectName) {
  QQuickItem* item = composerPart(world, objectName);
  expect(item != nullptr, QStringLiteral("the composer shows no %1").arg(objectName));
  return item;
}

QObject* popupOf(QQuickItem* control) {
  QObject* popup = control->property("popup").value<QObject*>();
  expect(popup != nullptr, QStringLiteral("%1 has no popup").arg(control->objectName()));
  return popup;
}

void click(World& world, QQuickItem* item) {
  Brick& brick = composerBrick(world);
  expect(item->isVisible(), QStringLiteral("%1 is not on screen").arg(item->objectName()));
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item));
  world.sync();
}

bool shown(World& world, const QString& objectName) {
  QQuickItem* item = composerPart(world, objectName);
  return item && item->isVisible();
}

// The composer on screen with the shell's state drawn.
void drawn(World& world) {
  composerBrick(world);
  world.waitFor([&] { return composerItem(world)->property("ready").toBool() && shown(world, QStringLiteral("modelPicker")); },
                [&] { return QStringLiteral("the composer to be ready; it shows %1").arg(show(composer(world))); });
}

// Opens `combo` and chooses its entry `label` with the keyboard.
void choose(World& world, QQuickItem* combo, const QString& label) {
  Brick& brick = composerBrick(world);
  QObject* popup = popupOf(combo);
  if (!popup->property("opened").toBool()) click(world, combo);
  world.waitFor([&] { return popup->property("opened").toBool(); }, [&] { return QStringLiteral("%1 to open").arg(combo->objectName()); });
  const QStringList labels = combo->property("model").toStringList();
  const qsizetype index = labels.indexOf(label);
  expect(index >= 0, QStringLiteral("%1 offers %2").arg(combo->objectName(), labels.join(u", ")));
  for (int guard = 0; combo->property("highlightedIndex").toInt() != index && guard < 8; ++guard) {
    QTest::keyClick(&brick.window(), combo->property("highlightedIndex").toInt() < index ? Qt::Key_Down : Qt::Key_Up);
  }
  expect(combo->property("highlightedIndex").toInt() == index, QStringLiteral("%1 cannot reach %2").arg(combo->objectName(), label));
  QTest::keyClick(&brick.window(), Qt::Key_Return);
  world.sync();
}

QString modeOf(World& world, const QString& label) {
  for (const QVariant& entry : composer(world).value(QStringLiteral("runtimeModes")).toList()) {
    if (entry.toMap().value(QStringLiteral("label")) == label) return entry.toMap().value(QStringLiteral("value")).toString();
  }
  fail(QStringLiteral("the composer offers %1").arg(show(composer(world).value(QStringLiteral("runtimeModes")))));
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the open thread runs in (.+)"), [](World& world, const Captures& c, const Table&) {
    const QString mode = modeOf(world, c[0]);
    QJsonObject& row = world.mc.threads[kThread];
    row.insert(QStringLiteral("runtimeMode"), mode);
    world.mc.sendRow(kThread, row);
    world.sync();
    const QString key = world.mc.environmentId + QLatin1Char(':') + kThread;
    world.waitFor([&] { return composer(world).value(QStringLiteral("target")) == key && composer(world).value(QStringLiteral("runtimeMode")) == mode; },
                  [&] { return QStringLiteral("the thread in %1; the composer shows %2").arg(c[0], show(composer(world))); });
  });
  step(QStringLiteral("the app quits before the MC answers and starts again on the thread"), [](World& world, const Captures&, const Table&) {
    // The answer goes with the connection it was for.
    world.mc.dropHeld();
    world.restart();
    world.connect();
    world.sync();
    look(world, world.mc.environmentId + QLatin1Char(':') + kThread);
  });
  step(QStringLiteral("another device gives the thread Full access"), [](World& world, const Captures&, const Table&) {
    QJsonObject& row = world.mc.threads[kThread];
    row.insert(QStringLiteral("runtimeMode"), QStringLiteral("full-access"));
    world.mc.sendRow(kThread, row);
    world.sync();
  });
  step(QStringLiteral("the model control's permissions read %1").arg(q), [](World& world, const Captures& c, const Table&) {
    drawn(world);
    QQuickItem* picker = part(world, QStringLiteral("modelPicker"));
    if (!popupOf(picker)->property("opened").toBool()) click(world, picker);
    world.waitFor([&] { return popupOf(picker)->property("opened").toBool(); }, QStringLiteral("the model control to open"));
    QQuickItem* permissions = part(world, QStringLiteral("modelPickerPermissions"));
    world.waitFor([&] { return permissions->property("displayText") == c[0]; }, [&] {
      return QStringLiteral("the footer to read %1; it reads %2 and the composer shows %3")
          .arg(c[0], permissions->property("displayText").toString(), show(composer(world)));
    });
  });
  step(QStringLiteral("the user sets the thread's permissions to (.+) from the effort menu"), [](World& world, const Captures& c, const Table&) {
    drawn(world);
    QQuickItem* picker = part(world, QStringLiteral("modelPicker"));
    if (!popupOf(picker)->property("opened").toBool()) click(world, picker);
    world.waitFor([&] { return popupOf(picker)->property("opened").toBool(); }, QStringLiteral("the model control to open"));
    choose(world, part(world, QStringLiteral("modelPickerPermissions")), c[0]);
    // The MC is told, then its row carries the change.
    const QString mode = modeOf(world, c[0]);
    world.waitFor([&] {
      return std::any_of(world.mc.commands.cbegin(), world.mc.commands.cend(), [&](const QJsonObject& command) {
        return command.value(QLatin1String("type")) == QLatin1String("thread.runtime-mode.set") && command.value(QLatin1String("runtimeMode")) == mode;
      });
    }, [&] { return QStringLiteral("the access change for %1; the MC has %2").arg(mode, world.describeCommands()); });
    QJsonObject& row = world.mc.threads[kThread];
    row.insert(QStringLiteral("runtimeMode"), mode);
    world.mc.sendRow(kThread, row);
    world.sync();
  });
  step(QStringLiteral("the composer names %1 beside the model").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      QQuickItem* chip = composerPart(world, QStringLiteral("runtimeModePicker"));
      return chip && chip->isVisible() && chip->property("displayText") == c[0];
    }, [&] { return QStringLiteral("the toolbar to name %1; the composer shows %2").arg(c[0], show(composer(world))); });
    QQuickItem* chip = part(world, QStringLiteral("runtimeModePicker"));
    expect(chip->parentItem() == part(world, QStringLiteral("toolbarChips")), QStringLiteral("the permissions are not on the toolbar"));
  });

  // A new thread names them in its context strip.
  step(QStringLiteral("the draft says it will run in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    drawn(world);
    world.waitFor([&] {
      QQuickItem* named = composerPart(world, QStringLiteral("contextPermissions"));
      return composer(world).value(QStringLiteral("routeKind")) == QLatin1String("draft") && named && named->isVisible() && named->property("displayText") == c[0];
    }, [&] { return QStringLiteral("the draft to name %1; the composer shows %2").arg(c[0], show(composer(world))); });
    expect(!shown(world, QStringLiteral("runtimeModePicker")), QStringLiteral("the toolbar names the permissions too"));
  });
  step(QStringLiteral("the user chooses the permissions it names"), [](World& world, const Captures&, const Table&) {
    click(world, part(world, QStringLiteral("contextPermissions")));
  });
  step(QStringLiteral("the user can pick other permissions for the thread"), [](World& world, const Captures&, const Table&) {
    QQuickItem* named = part(world, QStringLiteral("contextPermissions"));
    world.waitFor([&] { return popupOf(named)->property("opened").toBool(); }, QStringLiteral("the permissions menu to open"));
    expect(!popupOf(part(world, QStringLiteral("modelPicker")))->property("visible").toBool(), QStringLiteral("the model list opened first"));
    expect(named->property("count").toInt() > 1, QStringLiteral("the menu offers %1").arg(named->property("model").toStringList().join(u", ")));
    choose(world, named, QStringLiteral("Supervised"));
    world.waitFor([&] { return composer(world).value(QStringLiteral("runtimeMode")) == QLatin1String("approval-required"); },
                  [&] { return QStringLiteral("the draft in Supervised; the composer shows %1").arg(show(composer(world))); });
  });
});

}  // namespace
