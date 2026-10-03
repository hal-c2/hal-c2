// This device's theme library: the theme editor as the desktop draws it
// (qml/HalC2/Bricks/ThemeEditor.qml over ThemeController's draft), importing,
// exporting and removing themes (features/navigation/theme-editor.feature,
// environment-themes.feature), and the appearance rows that are colours or
// keys (navigation/appearance.feature).

#include <QColor>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QTest>

#include "Brick.h"
#include "CommandPaletteController.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "Keymap.h"
#include "SettingsController.h"
#include "ThemeController.h"
#include "ThemeLibrary.h"
#include "World.h"

namespace {

struct Library {
  QString canvas;
  QString accent;
  QVariantMap unsaved;
  QString exported;
  QString routeBefore;
  QString copyId;
  QVariantMap copyColors;
  QJsonArray before;  // this device's themes before an import
};

Library& library(World& world) {
  return world.mc.part<Library>();
}

ThemeController* themes(World& world) {
  return world.native().controller<ThemeController>();
}

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

QJsonArray saved(World& world) {
  return settings(world)->deviceSettings().value(QLatin1String("customThemes")).toArray();
}

std::optional<QJsonObject> savedNamed(World& world, const QString& label) {
  for (const QJsonValue& value : saved(world)) {
    if (value.toObject().value(QLatin1String("label")).toString() == label) return value.toObject();
  }
  return std::nullopt;
}

QString describe(World& world) {
  return QStringLiteral("this device has %1; the import says \"%2\", waiting on %3")
      .arg(show(saved(world).toVariantList()), themes(world)->importError(), show(themes(world)->importConflicts()));
}

// A saved theme of this device by that name, made up when there is none.
QString ensureTheme(World& world, const QString& name, const QString& canvas = QStringLiteral("#2e3440")) {
  if (const auto theme = savedNamed(world, name)) return theme->value(QLatin1String("id")).toString();
  QJsonArray custom = saved(world);
  const QString id = QString(name).toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
  custom.append(QJsonObject{{QStringLiteral("id"), id},
                            {QStringLiteral("label"), name},
                            {QStringLiteral("appearance"), QStringLiteral("dark")},
                            {QStringLiteral("colors"), QJsonObject{{QStringLiteral("canvas"), canvas}, {QStringLiteral("accent"), QStringLiteral("#88c0d0")}}}});
  expect(settings(world)->writeDevice(QStringLiteral("customThemes"), custom.toVariantList()), settings(world)->deviceError());
  return id;
}

// A theme file as the web exports it.
QByteArray themeFile(const QString& name, const QString& canvas, const QString& id = {}) {
  QJsonObject file{{QStringLiteral("version"), 1},
                   {QStringLiteral("name"), name},
                   {QStringLiteral("appearance"), QStringLiteral("dark")},
                   {QStringLiteral("colors"), QJsonObject{{QStringLiteral("canvas"), canvas}, {QStringLiteral("accent"), QStringLiteral("#ff8800")}}}};
  if (!id.isEmpty()) file.insert(QStringLiteral("id"), id);
  return QJsonDocument(file).toJson();
}

QString writeFile(World& world, const QString& name, const QByteArray& content) {
  const QString dir = QDir(world.homeDir()).filePath(QStringLiteral("downloads"));
  QDir().mkpath(dir);
  const QString path = QDir(dir).filePath(name);
  QFile file(path);
  if (!file.open(QIODevice::WriteOnly)) fail(QStringLiteral("cannot write %1").arg(path));
  file.write(content);
  return path;
}

// The editor over a bare window, as ShellWindow holds it.
Brick& editor(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world,
                                          "import QtQuick\nimport HalC2.Bricks\n"
                                          "Item { property alias editor: editor; ThemeEditor { id: editor } }\n",
                                          QSize(720, 760));
    expect(QTest::qWaitForWindowActive(&world.brick->window()), QStringLiteral("the window did not become active"));
    world.waitFor([&] { return world.brick->root()->property("editor").value<QObject*>()->property("opened").toBool(); },
                  QStringLiteral("the theme editor to open"));
  }
  return *world.brick;
}

QObject* popup(World& world) {
  return editor(world).root()->property("editor").value<QObject*>();
}

// Replaces a field's text as the user does: select all, type, Enter.
void typeInto(Brick& brick, const QString& objectName, const QString& text) {
  QQuickItem* field = brick.item(objectName);
  field->forceActiveFocus(Qt::MouseFocusReason);
  expect(field->hasActiveFocus(), QStringLiteral("%1 did not take the keyboard").arg(objectName));
  QTest::keyClick(&brick.window(), Qt::Key_A, Qt::ControlModifier);
  for (const QChar character : text) QTest::keyClick(&brick.window(), character.toLatin1());
  QTest::keyClick(&brick.window(), Qt::Key_Return);
}

QVariantMap editingColors(World& world) {
  return themes(world)->editing().value(QStringLiteral("colors")).toMap();
}

QStringList headings(World& world) {
  QStringList titles;
  for (const QVariant& row : popup(world)->property("rows").toList()) {
    const QString heading = row.toMap().value(QStringLiteral("heading")).toString();
    if (!heading.isEmpty()) titles.append(heading);
  }
  return titles;
}

double relativeLuminance(const QColor& color) {
  const auto linear = [](double channel) { return channel <= 0.04045 ? channel / 12.92 : std::pow((channel + 0.055) / 1.055, 2.4); };
  return 0.2126 * linear(color.redF()) + 0.7152 * linear(color.greenF()) + 0.0722 * linear(color.blueF());
}

double contrast(const QColor& a, const QColor& b) {
  const double la = relativeLuminance(a), lb = relativeLuminance(b);
  return (std::max(la, lb) + 0.05) / (std::min(la, lb) + 0.05);
}

void answer(World& world, bool accepted) {
  const QVariant question = world.state(QStringLiteral("confirmation"));
  expect(question.typeId() == QMetaType::QVariantMap, QStringLiteral("no question is asked"));
  world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                          QVariantMap{{QStringLiteral("requestId"), at(question, QStringLiteral("requestId"))}, {QStringLiteral("accepted"), accepted}});
}

// Evaluates a settingsRows.js expression as the settings pages do.
QVariant evaluateRows(World& world, const QString& expression) {
  const QByteArray qml = QStringLiteral("import QtQuick\nimport \"file://%1/HalC2/Bricks/js/settingsRows.js\" as Rows\n"
                                        "Item { property var result: %2 }\n")
                             .arg(QStringLiteral(HAL_C2_QML_DIR), expression)
                             .toUtf8();
  Brick probe(world, qml, QSize(10, 10));
  return probe.root()->property("result");
}

const QColor kNordCanvas(QStringLiteral("#2e3440"));
const QString kImportedCanvas = QStringLiteral("#102030");

const Steps steps([] {
  const QString q = kQuoted;
  Brick::registerSingletons();

  // The editor.
  step(QStringLiteral("the theme editor is open"), [](World& world, const Captures&, const Table&) {
    // Its toggle: the palette's entry and the shortcut run it.
    auto* commands = world.native().controller<KeybindingController>()->commands();
    expect(commands->run(QStringLiteral("themeEditor.toggle")) && themes(world)->editorOpen(), QStringLiteral("the theme editor did not open"));
  });
  step(QStringLiteral("the user sets the canvas and accent colors"), [](World& world, const Captures&, const Table&) {
    Library& state = library(world);
    state.canvas = QStringLiteral("#1b2433");
    state.accent = QStringLiteral("#e0a040");
    Brick& brick = editor(world);
    typeInto(brick, QStringLiteral("color:canvas"), state.canvas);
    typeInto(brick, QStringLiteral("color:accent"), state.accent);
  });
  step(QStringLiteral("the rest of the palette is derived from them"), [](World& world, const Captures&, const Table&) {
    const Library& state = library(world);
    const QVariantMap colors = editingColors(world);
    const auto color = [&colors](const char* role) { return QColor(colors.value(QLatin1String(role)).toString()); };
    expect(color("canvas") == QColor(state.canvas) && color("accent") == QColor(state.accent), show(colors));
    // Every role is set, and the ones that must follow the two do.
    for (const QString& role : themes(world)->roles()) {
      expect(QColor(colors.value(role).toString()).isValid(), QStringLiteral("%1 is %2").arg(role, colors.value(role).toString()));
    }
    expect(contrast(color("text"), color("canvas")) >= 7, QStringLiteral("text %1 on %2").arg(color("text").name(), color("canvas").name()));
    expect(color("sidebar") != color("canvas") && color("surfaceRaised") != color("canvas") && color("border") != color("canvas") &&
               color("focus") == color("accent") && color("terminalBackground") == color("canvas"),
           show(colors));
    expect(contrast(color("accentForeground"), color("accent")) >= 4.5, show(colors));
  });
  step(QStringLiteral("the user shows the advanced colors"), [](World& world, const Captures&, const Table&) {
    editor(world).click(QStringLiteral("advanced"));
  });
  step(QStringLiteral("colors are grouped as Foundation, Brand & content, Context and Status"), [](World& world, const Captures&, const Table&) {
    const QStringList wanted{QStringLiteral("Foundation"), QStringLiteral("Brand & content"), QStringLiteral("Context"), QStringLiteral("Status")};
    expect(headings(world) == wanted, show(headings(world)));
    // Every role is under one of them, and the first family is drawn.
    qsizetype roles = 0;
    for (const QVariant& row : popup(world)->property("rows").toList()) roles += !row.toMap().value(QStringLiteral("role")).toString().isEmpty();
    expect(roles == themes(world)->roles().size(), QStringLiteral("%1 of %2 roles are listed").arg(roles).arg(themes(world)->roles().size()));
    // The list makes its rows when the window next lays out.
    world.waitFor([&] {
      editor(world).grab();
      return editor(world).shows(QStringLiteral("Foundation")) && editor(world).shows(QStringLiteral("canvas"));
    }, QStringLiteral("the advanced list to be drawn"));
  });
  step(QStringLiteral("the user can filter them by name"), [](World& world, const Captures&, const Table&) {
    Brick& brick = editor(world);
    QQuickItem* filter = brick.item(QStringLiteral("filter"));
    filter->forceActiveFocus(Qt::MouseFocusReason);
    for (const QChar character : QStringLiteral("sidebar")) QTest::keyClick(&brick.window(), character.toLatin1());
    const QVariantList rows = popup(world)->property("rows").toList();
    expect(headings(world) == QStringList{QStringLiteral("Context")} && rows.size() > 1, show(rows));
    for (const QVariant& row : rows) {
      const QString role = row.toMap().value(QStringLiteral("role")).toString();
      expect(role.isEmpty() || role.contains(QLatin1String("sidebar"), Qt::CaseInsensitive), show(rows));
    }
  });
  step(QStringLiteral("the theme editor is open with unsaved changes"), [](World& world, const Captures&, const Table&) {
    QVariantMap draft = themes(world)->draft();
    draft.insert(QStringLiteral("id"), QString());
    themes(world)->edit(draft);
    QVariantMap colors = draft.value(QStringLiteral("colors")).toMap();
    colors.insert(QStringLiteral("canvas"), QStringLiteral("#203040"));
    draft.insert(QStringLiteral("colors"), colors);
    draft.insert(QStringLiteral("label"), QStringLiteral("Half done"));
    themes(world)->setEditing(draft);
    library(world).unsaved = draft;
    expect(themes(world)->editorOpen() && themes(world)->editing() == draft, show(themes(world)->editing()));
  });
  step(QStringLiteral("the user opens a thread"), [](World& world, const Captures&, const Table&) {
    world.mc.projects.insert(QStringLiteral("p1"), {{QStringLiteral("id"), QStringLiteral("p1")}, {QStringLiteral("title"), QStringLiteral("p1")},
                                                     {QStringLiteral("workspaceRoot"), QStringLiteral("/work/p1")}, {QStringLiteral("scripts"), QJsonArray()}});
    world.mc.threads.insert(QStringLiteral("t1"), {{QStringLiteral("id"), QStringLiteral("t1")}, {QStringLiteral("projectId"), QStringLiteral("p1")},
                                                    {QStringLiteral("title"), QStringLiteral("One")},
                                                    {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                                    {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    world.mc.sendRow(QStringLiteral("p1"), world.mc.projects.value(QStringLiteral("p1")), QStringLiteral("project"));
    world.mc.sendRow(QStringLiteral("t1"), world.mc.threads.value(QStringLiteral("t1")));
    world.sync();
    world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), world.mc.environmentId + QStringLiteral(":t1")}});
    world.waitFor([&] { return at(world.state(QStringLiteral("route")), QStringLiteral("kind")) == QLatin1String("thread"); },
                  [&] { return QStringLiteral("the thread; the route is %1").arg(show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("the theme editor is still open with the changes"), [](World& world, const Captures&, const Table&) {
    expect(themes(world)->editorOpen() && themes(world)->editing() == library(world).unsaved, show(themes(world)->editing()));
    // And the window still draws it, over the thread.
    expect(popup(world)->property("opened").toBool() && editor(world).item(QStringLiteral("name"))->property("text") == QLatin1String("Half done"),
           QStringLiteral("the editor shows \"%1\"").arg(editor(world).item(QStringLiteral("name"))->property("text").toString()));
  });
  step(QStringLiteral("the user presses the theme editor shortcut"), [](World& world, const Captures&, const Table&) {
    setKeyFocus(world, {});
    pressKey(world, QStringLiteral("mod+alt+shift+t"));
  });
  step(QStringLiteral("the theme editor is closed"), [](World& world, const Captures&, const Table&) {
    expect(keyRan(world, QStringLiteral("themeEditor.toggle")) && !themes(world)->editorOpen() && themes(world)->editing().isEmpty(),
           describeKeyPress(world));
  });

  // Importing.
  step(QStringLiteral("the user imports one HAL-C2 theme file"), [](World& world, const Captures&, const Table&) {
    themes(world)->importFiles({writeFile(world, QStringLiteral("aurora.json"), themeFile(QStringLiteral("Aurora"), kImportedCanvas))});
  });
  step(QStringLiteral("the user imports one VS Code theme file"), [](World& world, const Captures&, const Table&) {
    // As an extension ships it: workbench colours, some translucent, most left out.
    const QJsonObject file{{QStringLiteral("name"), QStringLiteral("aurora-theme")},
                           {QStringLiteral("displayName"), QStringLiteral("Aurora")},
                           {QStringLiteral("type"), QStringLiteral("dark")},
                           {QStringLiteral("colors"), QJsonObject{{QStringLiteral("editor.background"), kImportedCanvas},
                                                                  {QStringLiteral("editor.foreground"), QStringLiteral("#d8dee9")},
                                                                  {QStringLiteral("focusBorder"), QStringLiteral("#88c0d0")},
                                                                  {QStringLiteral("sideBar.background"), QStringLiteral("#0c1622")},
                                                                  {QStringLiteral("list.hoverBackground"), QStringLiteral("#ffffff1a")}}},
                           {QStringLiteral("tokenColors"), QJsonArray()}};
    themes(world)->importFiles({writeFile(world, QStringLiteral("aurora-color-theme.json"), QJsonDocument(file).toJson())});
    // Its own colours where it names them, the rest grown from its background.
    const auto theme = savedNamed(world, QStringLiteral("Aurora"));
    expect(theme.has_value(), describe(world));
    const QJsonObject colors = theme->value(QLatin1String("colors")).toObject();
    const auto color = [&colors](const char* role) { return QColor(colors.value(QLatin1String(role)).toString()); };
    expect(theme->value(QLatin1String("appearance")) == QLatin1String("dark") && color("text") == QColor(QStringLiteral("#d8dee9")) &&
               color("accent") == QColor(QStringLiteral("#88c0d0")) && color("sidebar") == QColor(QStringLiteral("#0c1622")) &&
               color("sidebarRowHover").alpha() == 255 && color("sidebarRowHover") != color("sidebar") && color("border").isValid() &&
               contrast(color("sidebarForeground"), color("sidebar")) >= 4.5,
           show(colors.toVariantMap()));
  });
  step(QStringLiteral("the user pastes a theme's JSON"), [](World& world, const Captures&, const Table&) {
    expect(themes(world)->importText(QString::fromUtf8(themeFile(QStringLiteral("Aurora"), kImportedCanvas))), describe(world));
  });
  step(QStringLiteral("the theme is added"), [](World& world, const Captures&, const Table&) {
    const auto theme = savedNamed(world, QStringLiteral("Aurora"));
    expect(theme && QColor(theme->value(QLatin1String("colors")).toObject().value(QLatin1String("canvas")).toString()) == QColor(kImportedCanvas),
           describe(world));
    bool offered = false;
    for (const QVariant& value : themes(world)->available()) {
      offered |= value.toMap().value(QStringLiteral("label")) == QLatin1String("Aurora") && value.toMap().value(QStringLiteral("source")) == QLatin1String("custom");
    }
    expect(offered && themes(world)->importError().isEmpty(), describe(world));
  });
  step(QStringLiteral("the user imports three theme files at once"), [](World& world, const Captures&, const Table&) {
    QStringList paths;
    for (const QString& name : {QStringLiteral("Aurora"), QStringLiteral("Borealis"), QStringLiteral("Corona")}) {
      paths.append(writeFile(world, name.toLower() + QStringLiteral(".json"), themeFile(name, kImportedCanvas)));
    }
    const QString active = themes(world)->resolvedId();
    themes(world)->importFiles(paths);
    expect(saved(world).size() == 3 && themes(world)->resolvedId() == active, describe(world));
  });
  step(QStringLiteral("the user imports a theme file larger than 256 KB"), [](World& world, const Captures&, const Table&) {
    QByteArray big = themeFile(QStringLiteral("Huge"), kImportedCanvas);
    big.append(QByteArray(300 * 1024, ' '));
    themes(world)->importFiles({writeFile(world, QStringLiteral("huge.json"), big)});
  });
  step(QStringLiteral("the file is refused with the size limit explained"), [](World& world, const Captures&, const Table&) {
    const QString error = themes(world)->importError();
    expect(error.contains(QLatin1String("limit 256 KB")) && error.contains(QLatin1String("was not read")) && saved(world).isEmpty(), describe(world));
  });
  step(QStringLiteral("the user imports a theme file that cannot be read"), [](World& world, const Captures&, const Table&) {
    // The import dialog, which says why under its paste field.
    world.brick = std::make_unique<Brick>(world,
                                          "import QtQuick\nimport HalC2.Bricks\n"
                                          "Item { ThemeImportDialog { Component.onCompleted: open() } }\n",
                                          QSize(640, 520));
    const QString path = writeFile(world, QStringLiteral("locked.json"), themeFile(QStringLiteral("Locked"), kImportedCanvas));
    QFile::setPermissions(path, QFileDevice::Permissions());
    themes(world)->importFiles({path});
    QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    expect(saved(world).isEmpty(), describe(world));
  });
  step(QStringLiteral("%1 is installed").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureTheme(world, c[0], kNordCanvas.name());
    library(world).before = saved(world);
  });
  step(QStringLiteral("the user imports %1 again and chooses (Update existing|Keep both|Cancel)").arg(q),
       [](World& world, const Captures& c, const Table&) {
         const QString id = savedNamed(world, c[0])->value(QLatin1String("id")).toString();
         themes(world)->importFiles({writeFile(world, id + QStringLiteral(".json"), themeFile(c[0], kImportedCanvas, id))});
         // Nothing is touched until the user says which.
         expect(themes(world)->importConflicts() == QStringList{c[0]} && saved(world) == library(world).before, describe(world));
         themes(world)->resolveImport(c[1] == QLatin1String("Update existing") ? QStringLiteral("update")
                                      : c[1] == QLatin1String("Keep both")   ? QStringLiteral("copy")
                                                                             : QStringLiteral("cancel"));
         expect(themes(world)->importConflicts().isEmpty(), describe(world));
       });
  const auto canvasOf = [](const QJsonObject& theme) {
    return QColor(theme.value(QLatin1String("colors")).toObject().value(QLatin1String("canvas")).toString());
  };
  step(QStringLiteral("the installed %1 is replaced").arg(q), [canvasOf](World& world, const Captures& c, const Table&) {
    const auto theme = savedNamed(world, c[0]);
    expect(saved(world).size() == 1 && theme && canvasOf(*theme) == QColor(kImportedCanvas), describe(world));
  });
  step(QStringLiteral("a copy named %1 is added").arg(q), [canvasOf](World& world, const Captures& c, const Table&) {
    const auto copy = savedNamed(world, c[0]);
    const auto original = savedNamed(world, QStringLiteral("Nord"));
    expect(saved(world).size() == 2 && copy && canvasOf(*copy) == QColor(kImportedCanvas) && original && canvasOf(*original) == kNordCanvas &&
               copy->value(QLatin1String("id")) != original->value(QLatin1String("id")),
           describe(world));
  });
  step(QStringLiteral("nothing changes"), [](World& world, const Captures&, const Table&) {
    expect(saved(world) == library(world).before && themes(world)->importError().isEmpty(), describe(world));
  });

  // Exporting and removing.
  step(QStringLiteral("the user exports %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = ensureTheme(world, c[0]);
    Library& state = library(world);
    state.exported = QDir(world.homeDir()).filePath(QStringLiteral("my-theme.json"));
    expect(themes(world)->exportTheme(id, state.exported), QStringLiteral("the theme was not exported"));
  });
  step(QStringLiteral("a JSON theme file is saved that can be imported elsewhere"), [](World& world, const Captures&, const Table&) {
    QFile file(library(world).exported);
    expect(file.open(QIODevice::ReadOnly), QStringLiteral("%1 was not written").arg(file.fileName()));
    const QJsonObject theme = QJsonDocument::fromJson(file.readAll()).object();
    expect(theme.value(QLatin1String("version")).toInt() == 1 && theme.value(QLatin1String("name")) == QLatin1String("My Theme") &&
               theme.value(QLatin1String("appearance")) == QLatin1String("dark") &&
               QColor(theme.value(QLatin1String("colors")).toObject().value(QLatin1String("canvas")).toString()) == kNordCanvas,
           show(theme.toVariantMap()));
    // Elsewhere: a device that does not have it yet takes the file.
    expect(themes(world)->removeCustom(theme.value(QLatin1String("id")).toString()) && saved(world).isEmpty(), describe(world));
    themes(world)->importFiles({library(world).exported});
    const auto back = savedNamed(world, QStringLiteral("My Theme"));
    expect(back && QColor(back->value(QLatin1String("colors")).toObject().value(QLatin1String("canvas")).toString()) == kNordCanvas, describe(world));
  });
  step(QStringLiteral("the user confirms"), [](World& world, const Captures&, const Table&) { answer(world, true); });
  step(QStringLiteral("%1 is gone").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!savedNamed(world, c[0]), describe(world));
    for (const QVariant& value : themes(world)->available()) {
      expect(value.toMap().value(QStringLiteral("label")) != c[0], QStringLiteral("%1 is still offered").arg(c[0]));
    }
  });

  // A published theme's copy.
  step(QStringLiteral("the user has an editable copy that does not change when the server updates %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         const auto copy = savedNamed(world, c[0] + QStringLiteral(" copy"));
         expect(copy.has_value(), describe(world));
         const QString id = copy->value(QLatin1String("id")).toString();
         const QVariantMap before = themes(world)->draft(id);
         expect(before.value(QStringLiteral("id")) == id, QStringLiteral("the copy cannot be edited: %1").arg(show(before)));
         // The server changes its colours.
         const QJsonArray updated{QJsonObject{{QStringLiteral("id"), c[0]}, {QStringLiteral("name"), c[0]}, {QStringLiteral("appearance"), QStringLiteral("dark")},
                                              {QStringLiteral("canvas"), QStringLiteral("#222233")}, {QStringLiteral("accent"), QStringLiteral("#ff8800")}}};
         publishThemes(world.mc, world.mc.environmentId, updated);
         world.waitFor([&] { return settings(world)->themes() == updated; }, QStringLiteral("the shell to hear of the update"));
         expect(QColor(at(themes(world)->draft(c[0]), QStringLiteral("colors.canvas")).toString()) == QColor(QStringLiteral("#222233")),
                QStringLiteral("the published theme did not change"));
         expect(themes(world)->draft(id) == before, QStringLiteral("the copy is now %1").arg(show(themes(world)->draft(id))));
       });

  // Settings → Appearance: keys and the rows that are colours.
  step(QStringLiteral("the user presses the theme shortcut"), [](World& world, const Captures&, const Table&) {
    library(world).routeBefore = show(world.state(QStringLiteral("route")));
    setKeyFocus(world, {});
    pressKey(world, QStringLiteral("mod+alt+a"));
  });
  step(QStringLiteral("the theme picker opens over the thread"), [](World& world, const Captures&, const Table&) {
    auto* palette = world.native().controller<CommandPaletteController>();
    expect(keyRan(world, QStringLiteral("theme.select")) && palette->isOpen() && palette->submenu() == QLatin1String("Change theme"),
           describeKeyPress(world));
    // The window stays where it was.
    expect(show(world.state(QStringLiteral("route"))) == library(world).routeBefore,
           QStringLiteral("the route moved to %1").arg(show(world.state(QStringLiteral("route")))));
  });
  step(QStringLiteral("the current theme is marked \"Current\""), [](World& world, const Captures&, const Table&) {
    auto* palette = world.native().controller<CommandPaletteController>();
    QStringList current;
    for (int row = 0; row < palette->count(); ++row) {
      if (palette->index(row).data(CommandPaletteController::CurrentRole).toBool()) {
        current.append(palette->index(row).data(CommandPaletteController::TitleRole).toString());
      }
    }
    // The standard look, with no theme chosen.
    expect(current == QStringList{QStringLiteral("HAL-C2")}, show(current));
  });
  step(QStringLiteral("the user holds the appearance shortcut down"), [](World& world, const Captures&, const Table&) {
    setKeyFocus(world, {});
    auto* keys = world.native().controller<KeybindingController>();
    const QString sequence = keybindings::sequence(*keybindings::parseShortcut(QStringLiteral("mod+alt+shift+a")), keys->mac());
    QVariantMap shortcut;
    for (const QVariant& value : keys->shortcuts()) {
      if (value.toMap().value(QStringLiteral("sequence")) == sequence) shortcut = value.toMap();
    }
    expect(!shortcut.isEmpty(), QStringLiteral("no window shortcut for %1").arg(sequence));
    // The press, then the key repeats while it is held: a window Shortcut
    // fires again only when it repeats (ShellWindow binds autoRepeat to this).
    pressKey(world, QStringLiteral("mod+alt+shift+a"));
    for (int repeat = 0; repeat < 6 && shortcut.value(QStringLiteral("autoRepeat")).toBool(); ++repeat) {
      pressKey(world, QStringLiteral("mod+alt+shift+a"));
    }
  });
  step(QStringLiteral("font smoothing is not offered"), [](World& world, const Captures&, const Table&) {
    const QString os = world.native().controller<KeybindingController>()->mac() ? QStringLiteral("osx") : QStringLiteral("linux");
    const QString offered = QStringLiteral("Rows.visible(Rows.appearance, \"%1\").some(row => row.key === \"fontSmoothing\")");
    expect(os == QLatin1String("linux") && !evaluateRows(world, offered.arg(os)).toBool(), QStringLiteral("font smoothing is offered on %1").arg(os));
    // It is the Mac's row.
    expect(evaluateRows(world, offered.arg(QStringLiteral("osx"))).toBool(), QStringLiteral("font smoothing is offered nowhere"));
  });
  step(QStringLiteral("the user sets diff colors to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString value = c[0] == QLatin1String("Blue & orange") ? QStringLiteral("blue-orange") : QStringLiteral("red-green");
    settings(world)->set(QStringLiteral("diffColorScheme"), value);
    world.waitFor([&] { return settings(world)->setting(QStringLiteral("diffColorScheme")) == value; }, QStringLiteral("the diff colors to be saved"));
  });
  step(QStringLiteral("added and removed lines are shown in (green and red|blue and orange)"), [](World& world, const Captures& c, const Table&) {
    // What DiffPanel paints additions and deletions with.
    const QColor added = world.theme().color(QStringLiteral("diffAdded"), QColor());
    const QColor removed = world.theme().color(QStringLiteral("diffRemoved"), QColor());
    const auto near = [](const QColor& color, int hue) { return color.isValid() && std::abs(color.hslHue() - hue) <= 25; };
    const bool blue = c[0] == QLatin1String("blue and orange");
    expect(near(added, blue ? 217 : 142) && near(removed, blue ? 25 : 0),
           QStringLiteral("additions are %1 (hue %2), deletions %3 (hue %4)").arg(added.name()).arg(added.hslHue()).arg(removed.name()).arg(removed.hslHue()));
  });
  step(QStringLiteral("the user sets glass opacity to (\\d+)"), [](World& world, const Captures& c, const Table&) {
    library(world).copyColors.insert(QStringLiteral("overlay"), world.theme().color(QStringLiteral("surfaceOverlay"), QColor()).alphaF());
    settings(world)->set(QStringLiteral("glassOpacity"), c[0].toInt());
    world.waitFor([&] { return settings(world)->setting(QStringLiteral("glassOpacity")).toInt() == c[0].toInt(); }, QStringLiteral("the glass opacity to be saved"));
  });
  step(QStringLiteral("translucent surfaces are more see-through"), [](World& world, const Captures&, const Table&) {
    const double before = library(world).copyColors.value(QStringLiteral("overlay")).toDouble();
    const double now = world.theme().color(QStringLiteral("surfaceOverlay"), QColor()).alphaF();
    expect(now < before && std::abs(now - 0.5) < 0.01, QStringLiteral("menus and dialogs were %1 solid and are now %2").arg(before).arg(now));
  });
});

}  // namespace

bool removesTheme(World& world, const QString& name) {
  const QVariant route = world.state(QStringLiteral("route"));
  if (at(route, QStringLiteral("kind")) != QLatin1String("settings") || at(route, QStringLiteral("section")) != QLatin1String("/settings/appearance")) {
    return false;
  }
  themes(world)->requestRemove(ensureTheme(world, name));
  return true;
}
