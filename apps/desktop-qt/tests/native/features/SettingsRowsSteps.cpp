// Driving the rows of a native settings page as the user does: its switches by
// clicking them, its lists by picking an option (SettingsRows.h).

#include <QQuickItem>
#include <QTest>

#include "Brick.h"
#include "Harness.h"
#include "SettingsController.h"
#include "SettingsRows.h"
#include "World.h"

namespace {

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

QQuickItem* find(QQuickItem* item, const QString& name) {
  if (item->objectName() == name) return item;
  for (QQuickItem* child : item->childItems()) {
    if (QQuickItem* found = find(child, name)) return found;
  }
  return nullptr;
}

QString rowName(const QString& key) {
  return QStringLiteral("settingsRow:") + key;
}

}  // namespace

Brick& generalPage(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nGeneralSettings {}\n", QSize(800, 3200));
    expect(QTest::qWaitForWindowExposed(&world.brick->window()), QStringLiteral("the settings page was not shown"));
  }
  return *world.brick;
}

QQuickItem* pageItem(World& world, const QString& name, const QString& child) {
  Brick& page = generalPage(world);
  // Rows are made as the page lays out.
  page.grab();
  QQuickItem* row = find(page.window().contentItem(), name);
  expect(row != nullptr, QStringLiteral("the page has no %1").arg(name));
  QQuickItem* found = find(row, child);
  expect(found != nullptr, QStringLiteral("%1 has no %2").arg(name, child));
  return found;
}

bool rowShown(World& world, const QString& key) {
  Brick& page = generalPage(world);
  page.grab();
  const QQuickItem* row = find(page.window().contentItem(), rowName(key));
  return row != nullptr && row->isVisible();
}

bool settingOn(World& world, const QString& key) {
  const QVariant value = settings(world)->setting(key);
  return value.typeId() == QMetaType::Bool ? value.toBool() : value.toString() != QLatin1String("separate");
}

void turnRow(World& world, const QString& key, bool on) {
  Brick& page = generalPage(world);
  QQuickItem* control = pageItem(world, rowName(key), QStringLiteral("control"));
  expect(control->isEnabled(), QStringLiteral("the %1 switch is disabled").arg(key));
  if (control->property("checked").toBool() != on) QTest::mouseClick(&page.window(), Qt::LeftButton, Qt::NoModifier, page.at(control));
  world.waitFor([&] { return settingOn(world, key) == on && control->property("checked").toBool() == on; },
                [&] { return QStringLiteral("%1 to be %2; it is %3").arg(key, on ? u"on"_qs : u"off"_qs, show(settings(world)->setting(key))); });
}

void chooseRow(World& world, const QString& key, const QString& label) {
  QQuickItem* control = pageItem(world, rowName(key), QStringLiteral("control"));
  expect(control->isEnabled(), QStringLiteral("the %1 list is disabled").arg(key));
  const QVariantList options = control->property("model").toList();
  QStringList labels;
  for (int index = 0; index < options.size(); ++index) {
    const QVariantMap option = options.at(index).toMap();
    labels.append(option.value(QStringLiteral("label")).toString());
    if (labels.last() != label) continue;
    // What picking it from the open list does.
    QMetaObject::invokeMethod(control, "activated", Q_ARG(int, index));
    const QVariant value = option.value(QStringLiteral("value"));
    world.waitFor([&] { return settings(world)->setting(key) == value && control->property("currentIndex").toInt() == index; },
                  [&] { return QStringLiteral("%1 to be %2; it is %3").arg(key, show(value), show(settings(world)->setting(key))); });
    return;
  }
  fail(QStringLiteral("%1 offers %2, not \"%3\"").arg(key, labels.join(QStringLiteral(", ")), label));
}

QString rowText(World& world, const QString& key) {
  return pageItem(world, rowName(key), QStringLiteral("control"))->property("currentText").toString();
}
