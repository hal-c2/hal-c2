// The settings navigation as the desktop draws it (qml/HalC2/Bricks/SettingsNav.qml):
// its search, its results from the keyboard, and a query set from elsewhere
// (features/navigation/focus.feature). And the settings the command palette
// finds, from the same table (js/settingsPages.js), with the keybinding
// commands after them (navigation/command-palette.feature).

#include <QTest>

#include "Brick.h"
#include "CommandPaletteController.h"
#include "Harness.h"
#include "World.h"

namespace {

Brick& nav(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nSettingsNav {}\n", QSize(260, 900));
    world.brick->takesKeys = true;
    expect(QTest::qWaitForWindowActive(&world.brick->window()), QStringLiteral("the settings window did not become active"));
  }
  return *world.brick;
}

QQuickItem* field(World& world) {
  return nav(world).item(QStringLiteral("search"));
}

QVariantList rows(World& world) {
  return nav(world).root()->property("rows").toList();
}

QString describeRows(World& world) {
  QStringList lines;
  for (const QVariant& value : rows(world)) {
    const QVariantMap row = value.toMap();
    lines.append(row.value(QStringLiteral("result")).toBool()
                     ? QStringLiteral("%1 (%2)").arg(row.value(QStringLiteral("title")).toString(), row.value(QStringLiteral("sectionLabel")).toString())
                     : row.value(QStringLiteral("label")).toString());
  }
  return QStringLiteral("the search is \"%1\", listing %2").arg(field(world)->property("text").toString(), lines.join(QStringLiteral(", ")));
}

// Types into the search field, as the user does.
void search(World& world, const QString& query) {
  Brick& brick = nav(world);
  brick.click(QStringLiteral("search"));
  expect(field(world)->hasActiveFocus(), QStringLiteral("the settings search did not take the keyboard"));
  for (const QChar character : query) QTest::keyClick(&brick.window(), character.toLatin1());
  expect(field(world)->property("text").toString() == query, describeRows(world));
}

int resultTitled(World& world, const QString& title) {
  const QVariantList list = rows(world);
  for (int index = 0; index < list.size(); ++index) {
    const QVariantMap row = list.at(index).toMap();
    if (row.value(QStringLiteral("result")).toBool() && row.value(QStringLiteral("title")) == title) return index;
  }
  fail(QStringLiteral("no result is titled \"%1\"; %2").arg(title, describeRows(world)));
}

struct NavState {
  int result = -1;
};

CommandPaletteController& palette(World& world) {
  return *world.native().controller<CommandPaletteController>();
}

// The palette gets its settings from the brick's own table, as CommandPalette.qml hands it.
void handPaletteItsSettings(World& world) {
  const QByteArray qml = "import QtQuick\nimport HalC2.Shell\nimport \"file://" HAL_C2_QML_DIR
                         "/HalC2/Bricks/js/settingsPages.js\" as Pages\n"
                         "Item { Component.onCompleted: PaletteModel.setSettingsSections(Pages.paletteEntries(Qt.platform.os)) }\n";
  Brick loader(world, qml, QSize(10, 10));
}

int paletteRow(World& world, const std::function<bool(const QString& kind, const QString& id, const QString& title)>& matches) {
  CommandPaletteController& model = palette(world);
  for (int row = 0; row < model.count(); ++row) {
    if (matches(model.kindAt(row), model.idAt(row), model.index(row).data(CommandPaletteController::TitleRole).toString())) return row;
  }
  return -1;
}

QString describePalette(World& world) {
  CommandPaletteController& model = palette(world);
  QStringList lines;
  for (int row = 0; row < model.count(); ++row) {
    lines.append(QStringLiteral("%1 %2").arg(model.kindAt(row), model.index(row).data(CommandPaletteController::TitleRole).toString()));
  }
  return QStringLiteral("the palette lists %1").arg(lines.join(QStringLiteral(", ")));
}

const Steps steps([] {
  const QString q = kQuoted;
  Brick::registerSingletons();

  step(QStringLiteral("the user searche[sd] settings for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    search(world, c[0]);
  });
  step(QStringLiteral("each result names its section"), [](World& world, const Captures&, const Table&) {
    const QVariantList list = rows(world);
    expect(!list.isEmpty(), describeRows(world));
    for (const QVariant& value : list) {
      const QVariantMap row = value.toMap();
      expect(row.value(QStringLiteral("result")).toBool() && !row.value(QStringLiteral("sectionLabel")).toString().isEmpty(),
             describeRows(world));
    }
    // And draws it: the first result's row shows its title and its section.
    const QVariantMap first = list.first().toMap();
    expect(nav(world).shows(first.value(QStringLiteral("title")).toString()) &&
               nav(world).shows(first.value(QStringLiteral("sectionLabel")).toString()),
           describeRows(world));
  });
  step(QStringLiteral("the settings search lists %1").arg(q), [](World& world, const Captures& c, const Table&) {
    search(world, c[0].toLower());
    world.mc.part<NavState>().result = resultTitled(world, c[0]);
  });
  step(QStringLiteral("the user presses Space on that result"), [](World& world, const Captures&, const Table&) {
    Brick& brick = nav(world);
    QQuickItem* row = brick.item(QStringLiteral("settingsRow%1").arg(world.mc.part<NavState>().result));
    row->forceActiveFocus(Qt::TabFocusReason);
    expect(row->hasActiveFocus(), QStringLiteral("the result did not take the keyboard"));
    brick.press(QStringLiteral("space"));
    world.sync();
  });
  step(QStringLiteral("the section holding %1 opens with %1 highlighted").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == QLatin1String("Theme") && c[1] == c[0], QStringLiteral("the steps know the \"Theme\" setting"));
    const QVariant route = world.state(QStringLiteral("route"));
    expect(at(route, QStringLiteral("kind")) == QLatin1String("settings") &&
               at(route, QStringLiteral("section")) == QLatin1String("/settings/appearance") &&
               at(route, QStringLiteral("target")) == QLatin1String("themes"),
           QStringLiteral("the route is %1").arg(show(route)));
  });
  step(QStringLiteral("the settings search is empty"), [](World& world, const Captures&, const Table&) {
    expect(field(world)->property("text").toString().isEmpty(), describeRows(world));
  });
  step(QStringLiteral("the section list is shown again"), [](World& world, const Captures&, const Table&) {
    const QVariantList list = rows(world);
    expect(!list.isEmpty() && !list.first().toMap().value(QStringLiteral("result")).toBool() &&
               list.first().toMap().value(QStringLiteral("label")) == QLatin1String("General") && nav(world).shows(QStringLiteral("General")),
           describeRows(world));
  });
  step(QStringLiteral("the user cleared the settings search with Escape"), [](World& world, const Captures&, const Table&) {
    search(world, QStringLiteral("theme"));
    nav(world).press(QStringLiteral("escape"));
    expect(field(world)->property("text").toString().isEmpty(), describeRows(world));
  });
  step(QStringLiteral("the app sets the settings search to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("settings.search"), QVariantMap{{QStringLiteral("query"), c[0]}});
  });
  step(QStringLiteral("the settings search shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(field(world)->property("text").toString() == c[0], describeRows(world));
    // And searches for it.
    const QVariantList list = rows(world);
    expect(!list.isEmpty() && list.first().toMap().value(QStringLiteral("result")).toBool(), describeRows(world));
  });

  // The command palette's settings.
  step(QStringLiteral("the %1 setting is listed before the %1 shortcut").arg(q), [](World& world, const Captures& c, const Table&) {
    handPaletteItsSettings(world);
    const int setting = paletteRow(world, [&](const QString& kind, const QString& id, const QString& title) {
      return kind == QLatin1String("setting") && title == c[0] && id.contains(QLatin1Char('#'));
    });
    const int shortcut = paletteRow(world, [&](const QString& kind, const QString& id, const QString& title) {
      return kind == QLatin1String("setting") && title.startsWith(c[1]) && id.contains(QLatin1Char('?'));
    });
    expect(setting >= 0 && shortcut > setting, describePalette(world));
  });
  step(QStringLiteral("the user searches the palette for %1 and chooses the setting").arg(q), [](World& world, const Captures& c, const Table&) {
    handPaletteItsSettings(world);
    CommandPaletteController& model = palette(world);
    if (!model.isOpen()) model.show();
    model.setQuery(c[0]);
    const int row = paletteRow(world, [&](const QString& kind, const QString&, const QString& title) {
      return kind == QLatin1String("setting") && title.compare(c[0], Qt::CaseInsensitive) == 0;
    });
    expect(row >= 0, describePalette(world));
    expect(model.run(row), describePalette(world));
    world.sync();
  });
  step(QStringLiteral("settings open with the word wrap setting highlighted"), [](World& world, const Captures&, const Table&) {
    const QVariant route = world.state(QStringLiteral("route"));
    expect(at(route, QStringLiteral("kind")) == QLatin1String("settings") &&
               at(route, QStringLiteral("section")) == QLatin1String("/settings/appearance") &&
               at(route, QStringLiteral("target")) == QLatin1String("settingsRow:wordWrap"),
           QStringLiteral("the route is %1").arg(show(route)));
    expect(!palette(world).isOpen(), QStringLiteral("the palette is still open"));
  });
});

}  // namespace
