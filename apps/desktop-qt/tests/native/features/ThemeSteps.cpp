// The theme the shell resolves and draws, the themes the MC publishes, and
// the shell theme file over them (features/desktop/native-settings.feature,
// navigation/environment-themes.feature, navigation/appearance.feature); this
// device's own themes as Settings → Appearance edits them
// (navigation/theme-editor.feature).

#include <QColor>
#include <QDir>
#include <QFile>
#include <QJsonDocument>

#include "ComposerBrick.h"
#include "FakeConfig.h"
#include "CommandPaletteController.h"
#include "FilesIdentity.h"
#include "FilesViewer.h"
#include "Harness.h"
#include "Onboarding.h"
#include "SettingsController.h"
#include "ThemeController.h"
#include "World.h"

namespace {

ThemeController* themes(World& world) {
  return world.native().controller<ThemeController>();
}

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

QString appearanceWord(const QString& word) {
  return word.toLower();
}

// The canvas the shell's theme hands the palette, and the one drawn.
QColor publishedCanvas(World& world) {
  return QColor(at(world.state(QStringLiteral("theme")), QStringLiteral("colors.canvas")).toString());
}

QColor drawnCanvas(World& world) {
  return world.theme().color(QStringLiteral("canvas"), QColor());
}

QString describe(World& world) {
  return QStringLiteral("the shell resolved %1 (%2), drawing canvas %3 from %4")
      .arg(themes(world)->resolvedId(), themes(world)->appearance(), drawnCanvas(world).name(),
           world.theme().loaded() ? QStringLiteral("the shell theme file") : QStringLiteral("the app's theme"));
}

void usesTheme(World& world, const QString& id) {
  world.waitFor([&] {
    return themes(world)->resolvedId() == id && at(world.state(QStringLiteral("theme")), QStringLiteral("id")) == id &&
           drawnCanvas(world) == publishedCanvas(world);
  }, [&] { return QStringLiteral("%1; %2").arg(id, describe(world)); });
}

void drawn(World& world, const QString& appearance) {
  world.waitFor([&] { return themes(world)->appearance() == appearance && world.theme().appearance() == appearance; },
                [&] { return QStringLiteral("drawn %1; the palette is %2, %3").arg(appearance, world.theme().appearance(), describe(world)); });
}

void ensureConnected(World& world) {
  if (settings(world)->ready()) return;
  if (world.mc.connections.isEmpty()) world.connect();
  world.waitFor([&world] { return settings(world)->ready(); }, QStringLiteral("the shell to read the MC's settings"));
}

// The MC's published themes in the short form (a canvas and an accent).
QJsonObject published(const QString& id, const QString& canvas) {
  return {{QStringLiteral("id"), id},
          {QStringLiteral("name"), id},
          {QStringLiteral("appearance"), QStringLiteral("dark")},
          {QStringLiteral("canvas"), canvas},
          {QStringLiteral("accent"), QStringLiteral("#ff8800")}};
}

void publish(World& world, const QString& environment, const QJsonArray& list) {
  publishThemes(world.mc, environment, list);
  if (environment == world.mc.environmentId) {
    world.waitFor([&] { return settings(world)->themes() == list; }, QStringLiteral("the shell to hear of the published themes"));
  }
}

void saveCustom(World& world, const QJsonObject& theme) {
  QJsonArray custom = settings(world)->deviceSettings().value(QLatin1String("customThemes")).toArray();
  custom.append(theme);
  expect(settings(world)->writeDevice(QStringLiteral("customThemes"), custom.toVariantList()), settings(world)->deviceError());
}

void choose(World& world, const QString& id) {
  expect(themes(world)->choose(id), settings(world)->deviceError());
}

QString themeFile(World& world) {
  return QDir(world.configDir()).filePath(QStringLiteral("theme.json"));
}

void writeThemeFile(World& world, const QByteArray& content) {
  QFile file(themeFile(world));
  if (!file.open(QIODevice::WriteOnly)) fail(QStringLiteral("cannot write %1").arg(file.fileName()));
  file.write(content);
}

void writeThemeFile(World& world, const QJsonObject& theme) {
  writeThemeFile(world, QJsonDocument(theme).toJson());
}

void shellRunning(World& world) {
  world.connect();
  world.waitFor([&world] { return world.native().isActive(); }, QStringLiteral("the shell to start"));
}

// A theme of this device's by that name (its id), with a palette for each
// appearance named; the ones the scenarios name are made up here.
void ensureTheme(World& world, const QString& name, const QStringList& appearances = {QStringLiteral("dark"), QStringLiteral("light")}) {
  for (const QVariant& theme : themes(world)->available()) {
    if (theme.toMap().value(QStringLiteral("id")) == name) return;
  }
  const QJsonObject dark{{QStringLiteral("canvas"), QStringLiteral("#2e3440")}, {QStringLiteral("accent"), QStringLiteral("#88c0d0")}};
  const QJsonObject light{{QStringLiteral("canvas"), QStringLiteral("#eceff4")}, {QStringLiteral("accent"), QStringLiteral("#5e81ac")}};
  const QString first = appearances.first();
  QJsonObject theme{{QStringLiteral("id"), name},
                    {QStringLiteral("label"), name},
                    {QStringLiteral("appearance"), first},
                    {QStringLiteral("colors"), first == QLatin1String("dark") ? dark : light}};
  if (appearances.size() > 1) theme.insert(QStringLiteral("variants"), QJsonObject{{QStringLiteral("light"), light}});
  saveCustom(world, theme);
}

// This device's preferences, as they are, in a directory that cannot be
// written: every later save fails. Writable again when the shell goes, so the
// scenario's home can be removed.
void blockDevice(World& world) {
  const QString locked = QDir(world.configDir()).filePath(QStringLiteral("locked"));
  const QString path = QDir(locked).filePath(QStringLiteral("preferences.json"));
  QDir().mkpath(locked);
  QFile file(path);
  if (!file.open(QIODevice::WriteOnly)) fail(QStringLiteral("cannot write %1").arg(path));
  file.write(QJsonDocument(settings(world)->deviceSettings()).toJson());
  file.close();
  settings(world)->setDevicePath(path);
  const auto readOnly = QFileDevice::ReadOwner | QFileDevice::ExeOwner;
  QFile::setPermissions(path, QFileDevice::ReadOwner);
  QFile::setPermissions(locked, readOnly);
  QObject::connect(settings(world), &QObject::destroyed, [locked, path, readOnly] {
    QFile::setPermissions(locked, readOnly | QFileDevice::WriteOwner);
    QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
  });
}

std::optional<QVariantMap> offered(World& world, const QString& label) {
  for (const QVariant& theme : themes(world)->available()) {
    if (theme.toMap().value(QStringLiteral("label")) == label) return theme.toMap();
  }
  return std::nullopt;
}

const QColor kShellCanvas(QStringLiteral("#123456"));

const Steps steps([] {
  const QString q = kQuoted;

  // The choice.
  step(QStringLiteral("the user is using HAL-C2 on the desktop"), [](World& world, const Captures&, const Table&) { shellRunning(world); });
  step(QStringLiteral("the theme choice (?:is|becomes) %1").arg(q), [](World& world, const Captures& c, const Table&) { choose(world, c[0]); });
  step(QStringLiteral("the theme choice is cleared"), [](World& world, const Captures&, const Table&) { choose(world, QString()); });
  step(QStringLiteral("the theme choice is %1 for light and %1 for dark").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(themes(world)->chooseHalf(QStringLiteral("light"), c[0]) && themes(world)->chooseHalf(QStringLiteral("dark"), c[1]),
           settings(world)->deviceError());
  });
  step(QStringLiteral("the theme choice is %1 for (light|dark)").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(themes(world)->chooseHalf(c[1], c[0]), settings(world)->deviceError());
  });
  step(QStringLiteral("the (light|dark) theme choice is cleared"), [](World& world, const Captures& c, const Table&) {
    expect(themes(world)->chooseHalf(c[0], QString()), settings(world)->deviceError());
  });
  step(QStringLiteral("the appearance choice becomes (Light|Dark|System)"), [](World& world, const Captures& c, const Table&) {
    expect(themes(world)->setMode(appearanceWord(c[0])), settings(world)->deviceError());
  });
  step(QStringLiteral("the user chose the System appearance"), [](World& world, const Captures&, const Table&) {
    expect(themes(world)->setMode(QStringLiteral("system")), settings(world)->deviceError());
  });
  // Sets the appearance, or checks it as an outcome.
  step(QStringLiteral("the appearance is (Light|Dark|System)"), [](World& world, const Captures& c, const Table&) {
    if (world.checking) {
      expect(themes(world)->mode() == appearanceWord(c[0]), QStringLiteral("the appearance is %1").arg(themes(world)->mode()));
      return;
    }
    expect(themes(world)->setMode(appearanceWord(c[0])), settings(world)->deviceError());
  });
  step(QStringLiteral("the operating system (?:is|switches to) (dark|light)"), [](World& world, const Captures& c, const Table&) {
    themes(world)->setSystemDark(c[0] == QLatin1String("dark"));
  });
  step(QStringLiteral("the user saved a custom theme %1 with only a dark palette").arg(q), [](World& world, const Captures& c, const Table&) {
    saveCustom(world, {{QStringLiteral("id"), c[0]},
                       {QStringLiteral("label"), c[0]},
                       {QStringLiteral("appearance"), QStringLiteral("dark")},
                       {QStringLiteral("colors"), QJsonObject{{QStringLiteral("canvas"), QStringLiteral("#101020")}}}});
  });

  // What is drawn.
  step(QStringLiteral("the app uses the standard theme"), [](World& world, const Captures&, const Table&) {
    usesTheme(world, QStringLiteral("hal-c2"));
    const QColor standard(themes(world)->appearance() == QLatin1String("dark") ? QStringLiteral("#0a0a0a") : QStringLiteral("#fcfcfc"));
    expect(drawnCanvas(world) == standard, describe(world));
  });
  step(QStringLiteral("the app uses %1").arg(q), [](World& world, const Captures& c, const Table&) { usesTheme(world, c[0]); });
  step(QStringLiteral("the app is drawn (dark|light)"), [](World& world, const Captures& c, const Table&) { drawn(world, c[0]); });
  step(QStringLiteral("%1 is the dark theme").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(themes(world)->halves().value(QStringLiteral("dark")) == c[0], QStringLiteral("the halves are %1").arg(show(themes(world)->halves())));
  });
  step(QStringLiteral("the light theme is still %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!themes(world)->halves().contains(QStringLiteral("light")) && themes(world)->themeId() == c[0],
           QStringLiteral("the theme is %1, the halves %2").arg(themes(world)->themeId(), show(themes(world)->halves())));
  });

  // Published themes.
  step(QStringLiteral("the (?:server|MC) publishes %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureConnected(world);
    publish(world, world.mc.environmentId, {published(c[0], QStringLiteral("#111111"))});
  });
  step(QStringLiteral("the user selected the published theme %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureConnected(world);
    publish(world, world.mc.environmentId, {published(c[0], QStringLiteral("#111111"))});
    // A dark theme, seen in the dark.
    themes(world)->setSystemDark(true);
    choose(world, c[0]);
    usesTheme(world, c[0]);
  });
  step(QStringLiteral("the server updates %1").arg(q), [](World& world, const Captures& c, const Table&) {
    publish(world, world.mc.environmentId, {published(c[0], QStringLiteral("#222233"))});
  });
  step(QStringLiteral("the server stops publishing %1").arg(q), [](World& world, const Captures&, const Table&) {
    publish(world, world.mc.environmentId, {});
  });
  step(QStringLiteral("the app shows the updated colors"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return drawnCanvas(world) == QColor(QStringLiteral("#222233")); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the app uses the published %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&world] { return settings(world)->ready(); }, QStringLiteral("the shell to read the MC's settings again"));
    usesTheme(world, c[0]);
    const QJsonArray list = fakeConfig(world.mc).themes.value(world.mc.environmentId);
    expect(drawnCanvas(world) == QColor(list.first().toObject().value(QLatin1String("canvas")).toString()), describe(world));
  });
  step(QStringLiteral("the user saved a custom theme with the id %1").arg(q), [](World& world, const Captures& c, const Table&) {
    saveCustom(world, {{QStringLiteral("id"), c[0]},
                       {QStringLiteral("label"), QStringLiteral("My ") + c[0]},
                       {QStringLiteral("appearance"), QStringLiteral("dark")},
                       {QStringLiteral("colors"), QJsonObject{{QStringLiteral("canvas"), QStringLiteral("#333333")}}}});
    themes(world)->setSystemDark(true);
    choose(world, c[0]);
  });
  step(QStringLiteral("the app uses the user's saved %1").arg(q), [](World& world, const Captures& c, const Table&) {
    usesTheme(world, c[0]);
    expect(drawnCanvas(world) == QColor(QStringLiteral("#333333")), describe(world));
  });
  step(QStringLiteral("the user connected a second environment that publishes %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureConnected(world);
    world.mc.link(QStringLiteral("env-b"));
    publish(world, QStringLiteral("env-b"), {published(c[0], QStringLiteral("#444444"))});
    world.sync();
  });
  step(QStringLiteral("%1 is not offered").arg(q), [](World& world, const Captures& c, const Table&) {
    if (checkIconImageOffered(world, c[0], false)) return;
    world.sync();
    for (const QVariant& theme : themes(world)->available()) {
      expect(theme.toMap().value(QStringLiteral("id")) != c[0], QStringLiteral("%1 is offered").arg(c[0]));
    }
    // Nor is it a choice of the menu that is open (threads/snooze.feature).
    for (const QVariant& item : at(world.state(QStringLiteral("menu")), QStringLiteral("items")).toList()) {
      expect(!item.toMap().value(QStringLiteral("label")).toString().startsWith(c[0]), QStringLiteral("the menu offers %1").arg(show(item)));
    }
  });

  // The shell theme file (docs/internals/desktop-qt.md).
  step(QStringLiteral("the desktop shell is running"), [](World& world, const Captures&, const Table&) { shellRunning(world); });
  step(QStringLiteral("the desktop shell is using a shell theme"), [](World& world, const Captures&, const Table&) {
    shellRunning(world);
    writeThemeFile(world, QJsonObject{{QStringLiteral("colors"), QJsonObject{{QStringLiteral("canvas"), kShellCanvas.name()}}}});
    world.waitFor([&world] { return world.theme().loaded() && drawnCanvas(world) == kShellCanvas; }, QStringLiteral("the shell theme to load"));
  });
  step(QStringLiteral("a theme manager writes a new canvas color into the shell theme file"), [](World& world, const Captures&, const Table&) {
    writeThemeFile(world, QJsonObject{{QStringLiteral("colors"), QJsonObject{{QStringLiteral("canvas"), kShellCanvas.name()}}}});
  });
  step(QStringLiteral("the app uses the new canvas color"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] { return drawnCanvas(world) == kShellCanvas; }, [&world] { return describe(world); });
  });
  step(QStringLiteral("the shell theme file is saved with a syntax error"), [](World& world, const Captures&, const Table&) {
    writeThemeFile(world, QByteArray("{ \"colors\": { \"canvas\": "));
    world.waitFor([&world] { return !world.theme().lastError().isEmpty(); }, QStringLiteral("the shell to read the broken file"));
  });
  step(QStringLiteral("the app keeps the previous colors"), [](World& world, const Captures&, const Table&) {
    expect(drawnCanvas(world) == kShellCanvas, describe(world));
  });
  step(QStringLiteral("the error is available to the user's shell layout"), [](World& world, const Captures&, const Table&) {
    // `Theme.lastError` in QML.
    expect(world.theme().lastError().startsWith(QLatin1String("theme.json")), world.theme().lastError());
  });
  step(QStringLiteral("the shell theme file is deleted"), [](World& world, const Captures&, const Table&) {
    QFile::remove(themeFile(world));
  });
  step(QStringLiteral("the app uses its own selected theme again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] {
      return !world.theme().loaded() && drawnCanvas(world) == publishedCanvas(world);
    }, [&world] { return describe(world); });
  });
  step(QStringLiteral("the shell theme has a light variant with a different canvas"), [](World& world, const Captures&, const Table&) {
    shellRunning(world);
    writeThemeFile(world, QJsonObject{
                              {QStringLiteral("appearance"), QStringLiteral("dark")},
                              {QStringLiteral("colors"), QJsonObject{{QStringLiteral("canvas"), kShellCanvas.name()}}},
                              {QStringLiteral("variants"), QJsonObject{{QStringLiteral("light"), QJsonObject{{QStringLiteral("canvas"), QStringLiteral("#eeeeee")}}}}},
                              {QStringLiteral("window"), QJsonObject{{QStringLiteral("followSystemAppearance"), true}}},
                          });
    world.waitFor([&world] { return world.theme().loaded(); }, QStringLiteral("the shell theme to load"));
  });
  step(QStringLiteral("the light variant's canvas is used"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] { return drawnCanvas(world) == QColor(QStringLiteral("#eeeeee")); }, [&world] { return describe(world); });
  });
  step(QStringLiteral("the user's saved theme choice is unchanged"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!QFile::exists(QDir(world.configDir()).filePath(QStringLiteral("preferences.json"))) &&
               settings(world)->deviceSettings().isEmpty() && fakeConfig(world.mc).writes.isEmpty(),
           QStringLiteral("this device holds %1").arg(show(settings(world)->deviceSettings().toVariantMap())));
  });
  // Settings → Appearance and the appearance shortcut.
  step(QStringLiteral("the user chooses the (System|Light|Dark) appearance"), [](World& world, const Captures& c, const Table&) {
    expect(themes(world)->setMode(appearanceWord(c[0])), settings(world)->deviceError());
  });
  step(QStringLiteral("the appearance becomes (Light|Dark|System)"), [](World& world, const Captures& c, const Table&) {
    expect(themes(world)->setMode(appearanceWord(c[0])), settings(world)->deviceError());
  });
  step(QStringLiteral("the app is drawn in the operating system's appearance"), [](World& world, const Captures&, const Table&) {
    for (const bool dark : {true, false}) {
      themes(world)->setSystemDark(dark);
      drawn(world, dark ? QStringLiteral("dark") : QStringLiteral("light"));
    }
  });
  step(QStringLiteral("the user presses the appearance shortcut"), [](World& world, const Captures&, const Table&) {
    // The keybinding and the command palette both send this.
    world.bridge().dispatch(QStringLiteral("appearance.cycle"), {});
  });
  step(QStringLiteral("the user chooses the %1 theme in Settings → Appearance").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureTheme(world, c[0]);
    choose(world, c[0]);
  });
  step(QStringLiteral("the user picks %1 for light and %1 for dark").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureTheme(world, c[0]);
    ensureTheme(world, c[1]);
    expect(themes(world)->chooseHalf(QStringLiteral("light"), c[0]) && themes(world)->chooseHalf(QStringLiteral("dark"), c[1]),
           settings(world)->deviceError());
  });
  step(QStringLiteral("%1 only has a dark palette").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureTheme(world, c[0], {QStringLiteral("dark")});
  });
  step(QStringLiteral("the user chooses %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (modelPickerChooses(world, c[0])) return;
    // The welcome wizard's Select all / Select none.
    if (onboardingChooses(world, c[0])) return;
    // From an open command palette (its Change theme submenu among them): its
    // entry of that title.
    if (auto* palette = world.native().controller<CommandPaletteController>(); palette && palette->isOpen()) {
      for (int row = 0; row < palette->rowCount(); ++row) {
        if (palette->index(row).data(CommandPaletteController::TitleRole) == c[0]) {
          palette->run(row);
          world.sync();
          return;
        }
      }
      fail(QStringLiteral("the command palette does not list \"%1\"").arg(c[0]));
    }
    choose(world, c[0]);
  });
  step(QStringLiteral("the light theme is unchanged"), [](World& world, const Captures&, const Table&) {
    expect(!themes(world)->halves().contains(QStringLiteral("light")) && themes(world)->themeId().isEmpty(),
           QStringLiteral("the theme is %1, the halves %2").arg(themes(world)->themeId(), show(themes(world)->halves())));
  });
  step(QStringLiteral("the theme choice cannot be saved"), [](World& world, const Captures&, const Table&) { blockDevice(world); });
  step(QStringLiteral("the user chooses a theme"), [](World& world, const Captures&, const Table&) {
    expect(!themes(world)->choose(QStringLiteral("grove")), QStringLiteral("the choice was saved"));
  });

  // This device's own themes (the theme editor).
  step(QStringLiteral("the active theme is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // As an outcome, only what the window draws.
    if (!world.checking) {
      ensureTheme(world, c[0]);
      choose(world, c[0]);
    }
    usesTheme(world, c[0]);
  });
  step(QStringLiteral("the user creates a theme"), [](World& world, const Captures&, const Table&) {
    // As Settings' "New theme" does: the active theme's colors, as a new theme.
    world.themeDraft = themes(world)->draft();
    world.themeDraft.insert(QStringLiteral("id"), QString());
  });
  step(QStringLiteral("the theme editor opens with (\\w+)'s colors"), [](World& world, const Captures& c, const Table&) {
    const QVariantMap& draft = world.themeDraft;
    expect(draft.value(QStringLiteral("label")) == c[0] && QColor(at(draft, QStringLiteral("colors.canvas")).toString()) == drawnCanvas(world),
           QStringLiteral("the editor holds %1; %2").arg(show(draft), describe(world)));
  });
  step(QStringLiteral("the user changed colors in the theme editor"), [](World& world, const Captures&, const Table&) {
    world.themeDraft = themes(world)->draft();
    QVariantMap colors = world.themeDraft.value(QStringLiteral("colors")).toMap();
    colors.insert(QStringLiteral("canvas"), QStringLiteral("#203040"));
    world.themeDraft.insert(QStringLiteral("colors"), colors);
    world.themeDraft.insert(QStringLiteral("label"), QStringLiteral("Edited"));
  });
  step(QStringLiteral("the user saves the changes"), [](World& world, const Captures&, const Table&) {
    const QString id = themes(world)->saveCustom(world.themeDraft);
    expect(!id.isEmpty(), settings(world)->deviceError());
    world.themeDraft.insert(QStringLiteral("id"), id);
  });
  step(QStringLiteral("the app uses the edited theme"), [](World& world, const Captures&, const Table&) {
    usesTheme(world, world.themeDraft.value(QStringLiteral("id")).toString());
    expect(drawnCanvas(world) == QColor(QStringLiteral("#203040")), describe(world));
  });
  step(QStringLiteral("the user duplicates %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureTheme(world, c[0]);
    expect(!themes(world)->duplicate(c[0]).isEmpty(), settings(world)->deviceError());
  });
  step(QStringLiteral("an editable copy of %1 is added").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto copy = offered(world, c[0] + QStringLiteral(" copy"));
    expect(copy && copy->value(QStringLiteral("source")) == QLatin1String("custom"),
           QStringLiteral("the themes offered are %1").arg(show(themes(world)->available())));
    const QVariantMap original = themes(world)->draft(c[0]);
    const QVariantMap duplicate = themes(world)->draft(copy->value(QStringLiteral("id")).toString());
    expect(duplicate.value(QStringLiteral("colors")) == original.value(QStringLiteral("colors")),
           QStringLiteral("the copy draws %1, the original %2").arg(show(duplicate), show(original)));
  });
  step(QStringLiteral("the theme cannot be removed"), [](World& world, const Captures&, const Table&) {
    ensureTheme(world, QStringLiteral("My Theme"));
    world.themeDraft = themes(world)->draft(QStringLiteral("My Theme"));
    blockDevice(world);
  });
  step(QStringLiteral("the user removes it"), [](World& world, const Captures&, const Table&) {
    if (removeViewedAttachment(world)) return;
    expect(!themes(world)->removeCustom(world.themeDraft.value(QStringLiteral("id")).toString()), QStringLiteral("the theme was removed"));
    expect(offered(world, QStringLiteral("My Theme")).has_value(), QStringLiteral("the theme is no longer offered"));
  });
});

}  // namespace
