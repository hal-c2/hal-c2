// Settings as the desktop draws them, navigation beside the page it opens
// (qml/HalC2/Bricks/SettingsNav.qml, SettingsHost.qml): the search's ranking
// and its slash key, a result opened twice, and restoring this device's
// defaults (features/settings/search-and-navigation.feature).

#include <QDir>
#include <QFile>
#include <QTest>

#include "Brick.h"
#include "Harness.h"
#include "SettingsController.h"
#include "SettingsShell.h"
#include "ThemeController.h"
#include "World.h"

namespace {

const QString kTimeFormat = QStringLiteral("timestampFormat");
const QString kTheme = QStringLiteral("grove");

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

ThemeController* themes(World& world) {
  return world.native().controller<ThemeController>();
}

QVariantList rows(World& world) {
  return settingsShell(world).root()->property("rows").toList();
}

QString describeRows(World& world) {
  QStringList lines;
  for (const QVariant& value : rows(world)) {
    const QVariantMap row = value.toMap();
    lines.append(row.value(QStringLiteral("result")).toBool()
                     ? QStringLiteral("%1 (%2)").arg(row.value(QStringLiteral("title")).toString(), row.value(QStringLiteral("sectionLabel")).toString())
                     : row.value(QStringLiteral("label")).toString());
  }
  return QStringLiteral("settings list %1").arg(lines.join(QStringLiteral(", ")));
}

QString describeChoices(World& world) {
  return QStringLiteral("the theme is \"%1\" and the time format %2; this device holds %3")
      .arg(themes(world)->themeId(), show(settings(world)->setting(kTimeFormat)), show(settings(world)->deviceSettings().toVariantMap()));
}

void changeThemeAndTimeFormat(World& world) {
  expect(themes(world)->choose(kTheme), settings(world)->deviceError());
  settings(world)->set(kTimeFormat, QStringLiteral("24-hour"));
  expect(themes(world)->themeId() == kTheme && settings(world)->setting(kTimeFormat) == QLatin1String("24-hour"), describeChoices(world));
}

bool changed(World& world) {
  return themes(world)->themeId() == kTheme && settings(world)->setting(kTimeFormat) == QLatin1String("24-hour");
}

QQuickItem* dialogList(World& world) {
  return settingsShell(world).item(QStringLiteral("restoreList"));
}

// Asks, as the navigation's button does, and waits for the question.
void askToRestore(World& world) {
  Brick& brick = settingsShell(world);
  brick.click(QStringLiteral("restoreDefaults"));
  world.waitFor([&] { return dialogList(world)->isVisible() && brick.item(QStringLiteral("confirm"))->isVisible(); },
                QStringLiteral("the question about restoring defaults"));
}

void answerRestore(World& world, bool accepted) {
  Brick& brick = settingsShell(world);
  brick.click(accepted ? QStringLiteral("confirm") : QStringLiteral("cancel"));
  world.waitFor([&] { return !brick.shows(QStringLiteral("Restore default settings?")); }, QStringLiteral("the question to close"));
}

// The page's row for a search result, and whether the page shows all of it.
bool inView(World& world, const QString& target) {
  Brick& brick = settingsShell(world);
  const QQuickItem* item = brick.item(target);
  const QQuickItem* host = brick.item(QStringLiteral("host"));
  const double top = item->mapToItem(host, QPointF(0, 0)).y();
  return item->isVisible() && top >= 0 && top + item->height() <= host->height();
}

void openResult(World& world, const QString& title) {
  Brick& brick = settingsShell(world);
  QQuickItem* field = brick.item(QStringLiteral("search"));
  field->setProperty("text", title.toLower());
  const QVariantList list = rows(world);
  for (int index = 0; index < list.size(); ++index) {
    const QVariantMap row = list.at(index).toMap();
    if (!row.value(QStringLiteral("result")).toBool() || row.value(QStringLiteral("title")) != title) continue;
    brick.click(QStringLiteral("settingsRow%1").arg(index));
    world.sync();
    return;
  }
  fail(QStringLiteral("no result is titled \"%1\"; %2").arg(title, describeRows(world)));
}

struct Opened {
  QString target;
};

const Steps steps([] {
  const QString q = kQuoted;

  // The slash key.
  step(QStringLiteral("the keyboard is not in a text field"), [](World& world, const Captures&, const Table&) {
    Brick& brick = settingsShell(world);
    QQuickItem* row = brick.item(QStringLiteral("settingsRow0"));
    row->forceActiveFocus(Qt::TabFocusReason);
    expect(row->hasActiveFocus() && !brick.item(QStringLiteral("search"))->hasActiveFocus(), QStringLiteral("the first section did not take the keyboard"));
  });
  step(QStringLiteral("the settings search has keyboard focus"), [](World& world, const Captures&, const Table&) {
    QQuickItem* field = settingsShell(world).item(QStringLiteral("search"));
    expect(field->hasActiveFocus(), QStringLiteral("the search does not have the keyboard"));
    // The key started the search; it was not typed into it.
    expect(field->property("text").toString().isEmpty(), QStringLiteral("the search holds \"%1\"").arg(field->property("text").toString()));
  });

  // Ranking.
  step(QStringLiteral("the first result is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantList list = rows(world);
      return !list.isEmpty() && list.first().toMap().value(QStringLiteral("result")).toBool() &&
             list.first().toMap().value(QStringLiteral("title")) == c[0];
    }, [&] { return describeRows(world); });
    expect(settingsShell(world).shows(c[0]), describeRows(world));
  });

  // A result opened twice.
  step(QStringLiteral("the user opened the search result %1 and scrolled away").arg(q), [](World& world, const Captures& c, const Table&) {
    // A window short enough that the setting can be scrolled out of it.
    settingsShell(world, QSize(900, 190));
    openResult(world, c[0]);
    const QString target = at(world.state(QStringLiteral("route")), QStringLiteral("target")).toString();
    expect(!target.isEmpty(), QStringLiteral("the route is %1").arg(show(world.state(QStringLiteral("route")))));
    world.mc.part<Opened>().target = target;
    world.waitFor([&] { return inView(world, target); }, [&] {
      Brick& brick = settingsShell(world);
      const QQuickItem* item = brick.item(target);
      const QQuickItem* scroll = brick.item(QStringLiteral("scroll"));
      return QStringLiteral("the page to bring %1 into view: it is at %2, %3 tall, in a page of %4 scrolled to %5 of %6")
          .arg(target)
          .arg(item->mapToItem(brick.item(QStringLiteral("host")), QPointF(0, 0)).y())
          .arg(item->height())
          .arg(scroll->height())
          .arg(scroll->property("contentY").toDouble())
          .arg(scroll->property("contentHeight").toDouble());
    });
    QQuickItem* scroll = settingsShell(world).item(QStringLiteral("scroll"));
    const double end = scroll->property("contentHeight").toDouble() - scroll->height();
    expect(end > 0, QStringLiteral("the page does not scroll"));
    // Whichever end the setting is not at.
    scroll->setProperty("contentY", scroll->property("contentY").toDouble() > end / 2 ? 0.0 : end);
    expect(!inView(world, target), QStringLiteral("%1 is still in view").arg(target));
  });
  step(QStringLiteral("the user opens the search result %1(?: again)?").arg(q), [](World& world, const Captures& c, const Table&) {
    openResult(world, c[0]);
    world.mc.part<Opened>().target = at(world.state(QStringLiteral("route")), QStringLiteral("target")).toString();
  });
  step(QStringLiteral("the page brings the setting into view"), [](World& world, const Captures&, const Table&) {
    const QString target = world.mc.part<Opened>().target;
    expect(!target.isEmpty(), QStringLiteral("no result was opened; the route is %1").arg(show(world.state(QStringLiteral("route")))));
    world.waitFor([&] { return inView(world, target); }, QStringLiteral("the page to bring %1 into view").arg(target));
  });
  step(QStringLiteral("the page brings the setting into view again"), [](World& world, const Captures&, const Table&) {
    const QString target = world.mc.part<Opened>().target;
    world.waitFor([&] { return inView(world, target); }, QStringLiteral("the page to bring %1 into view").arg(target));
  });

  // Restoring defaults.
  step(QStringLiteral("the user has changed the theme and the time format"), [](World& world, const Captures&, const Table&) {
    changeThemeAndTimeFormat(world);
  });
  step(QStringLiteral("the user restores default settings"), [](World& world, const Captures&, const Table&) { askToRestore(world); });
  step(QStringLiteral("the user is asked to confirm a reset of the theme and the time format"), [](World& world, const Captures&, const Table&) {
    const QString text = dialogList(world)->property("text").toString();
    expect(text == QLatin1String("This will reset: Theme, Time format."), QStringLiteral("the question reads \"%1\"").arg(text));
    // Nothing changes before the user answers.
    expect(changed(world), describeChoices(world));
  });
  step(QStringLiteral("the user is asked to confirm restoring default settings"), [](World& world, const Captures&, const Table&) {
    changeThemeAndTimeFormat(world);
    askToRestore(world);
    world.answerQuestion = [&world](bool accepted) { answerRestore(world, accepted); };
  });
  step(QStringLiteral("the theme and the time format are back to their defaults"), [](World& world, const Captures&, const Table&) {
    expect(themes(world)->themeId().isEmpty() && settings(world)->isDefault(kTimeFormat) &&
               settings(world)->setting(kTimeFormat) == settings(world)->defaultOf(kTimeFormat),
           describeChoices(world));
    expect(!settingsShell(world).item(QStringLiteral("restoreDefaults"))->isEnabled(), QStringLiteral("something is still offered to restore"));
  });
  step(QStringLiteral("every setting keeps its value"), [](World& world, const Captures&, const Table&) {
    expect(changed(world), describeChoices(world));
  });
  step(QStringLiteral("saving the theme on this device fails"), [](World& world, const Captures&, const Table&) {
    changeThemeAndTimeFormat(world);
    // A folder where the preferences file is: what the shell holds stays, and nothing more can be saved.
    const QString path = settings(world)->devicePath();
    expect(QFile::remove(path) && QDir().mkpath(path), QStringLiteral("cannot block %1").arg(path));
    expect(changed(world), describeChoices(world));
  });
  step(QStringLiteral("the user confirms restoring default settings"), [](World& world, const Captures&, const Table&) {
    askToRestore(world);
    answerRestore(world, true);
  });
  step(QStringLiteral("the theme settings keep their previous values"), [](World& world, const Captures&, const Table&) {
    expect(changed(world), describeChoices(world));
  });
  step(QStringLiteral("the user is told the theme settings could not be restored"), [](World& world, const Captures&, const Table&) {
    const QVariantList toasts = world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
    expect(std::any_of(toasts.cbegin(), toasts.cend(), [](const QVariant& toast) {
             return toast.toMap().value(QStringLiteral("title")) == QStringLiteral("Couldn’t restore theme settings");
           }),
           QStringLiteral("the shell shows %1").arg(show(toasts)));
  });
});

}  // namespace

Brick& settingsShell(World& world, const QSize& size) {
  if (!world.brick) {
    // As DefaultShell lays them out: the navigation, and the page of the route's section.
    world.brick = std::make_unique<Brick>(world,
                                          "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\n"
                                          "import \"file://" HAL_C2_QML_DIR "/HalC2/Bricks/js/settingsPages.js\" as Pages\n"
                                          "Item {\n"
                                          "  property alias rows: nav.rows\n"
                                          "  readonly property var route: Shell.state.route ?? null\n"
                                          "  SettingsNav { id: nav; objectName: \"nav\"; width: 260; height: parent.height }\n"
                                          "  SettingsHost {\n"
                                          "    objectName: \"host\"; x: 260; width: parent.width - 260; height: parent.height\n"
                                          "    section: parent.route !== null && parent.route.kind === \"settings\" ? Pages.resolve(parent.route.section) : \"\"\n"
                                          "  }\n"
                                          "}\n",
                                          size);
    world.brick->takesKeys = true;
    expect(QTest::qWaitForWindowActive(&world.brick->window()), QStringLiteral("the settings window did not become active"));
  }
  return *world.brick;
}
