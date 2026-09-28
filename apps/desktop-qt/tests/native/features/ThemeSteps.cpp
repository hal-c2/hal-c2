// The theme the shell resolves and draws, the themes the node publishes, and
// the shell theme file over them (features/desktop/native-settings.feature,
// navigation/environment-themes.feature, navigation/appearance.feature).

#include <QColor>
#include <QDir>
#include <QFile>
#include <QJsonDocument>

#include "FakeConfig.h"
#include "Harness.h"
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

// What the shell last handed the page: {id, dark, vars}.
QVariantMap pageTheme(World& world) {
  const QString script = world.theme().injectionScript();
  const QString head = QStringLiteral("const theme = ");
  const qsizetype start = script.indexOf(head);
  const qsizetype end = script.indexOf(QStringLiteral(";  const run"), start);
  if (start < 0 || end < 0) return {};
  return QJsonDocument::fromJson(script.mid(start + head.size(), end - start - head.size()).toUtf8()).object().toVariantMap();
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
  if (world.node.connections.isEmpty()) world.connect();
  world.waitFor([&world] { return settings(world)->ready(); }, QStringLiteral("the shell to read the node's settings"));
}

// The node's published themes in the short form (a canvas and an accent).
QJsonObject published(const QString& id, const QString& canvas) {
  return {{QStringLiteral("id"), id},
          {QStringLiteral("name"), id},
          {QStringLiteral("appearance"), QStringLiteral("dark")},
          {QStringLiteral("canvas"), canvas},
          {QStringLiteral("accent"), QStringLiteral("#ff8800")}};
}

void publish(World& world, const QString& environment, const QJsonArray& list) {
  publishThemes(world.node, environment, list);
  if (environment == world.node.environmentId) {
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
  world.waitFor([&world] { return world.state(QStringLiteral("native")).isValid(); }, QStringLiteral("the shell to take over"));
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
  step(QStringLiteral("the appearance is (Light|Dark)"), [](World& world, const Captures& c, const Table&) {
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
  step(QStringLiteral("the page is drawn in the shell's theme"), [](World& world, const Captures&, const Table&) {
    const QVariantMap page = pageTheme(world);
    expect(page.value(QStringLiteral("id")) == themes(world)->resolvedId() &&
               page.value(QStringLiteral("dark")).toBool() == (themes(world)->appearance() == QLatin1String("dark")) &&
               QColor(at(page, QStringLiteral("vars.--app-theme-canvas")).toString()) == publishedCanvas(world),
           QStringLiteral("the page was handed %1; %2").arg(show(page), describe(world)));
  });
  step(QStringLiteral("%1 is the dark theme").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(themes(world)->halves().value(QStringLiteral("dark")) == c[0], QStringLiteral("the halves are %1").arg(show(themes(world)->halves())));
  });
  step(QStringLiteral("the light theme is still %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!themes(world)->halves().contains(QStringLiteral("light")) && themes(world)->themeId() == c[0],
           QStringLiteral("the theme is %1, the halves %2").arg(themes(world)->themeId(), show(themes(world)->halves())));
  });

  // Published themes.
  step(QStringLiteral("the (?:server|node) publishes %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureConnected(world);
    publish(world, world.node.environmentId, {published(c[0], QStringLiteral("#111111"))});
  });
  step(QStringLiteral("the user selected the published theme %1").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureConnected(world);
    publish(world, world.node.environmentId, {published(c[0], QStringLiteral("#111111"))});
    // A dark theme, seen in the dark.
    themes(world)->setSystemDark(true);
    choose(world, c[0]);
    usesTheme(world, c[0]);
  });
  step(QStringLiteral("the server updates %1").arg(q), [](World& world, const Captures& c, const Table&) {
    publish(world, world.node.environmentId, {published(c[0], QStringLiteral("#222233"))});
  });
  step(QStringLiteral("the server stops publishing %1").arg(q), [](World& world, const Captures&, const Table&) {
    publish(world, world.node.environmentId, {});
  });
  step(QStringLiteral("the app shows the updated colors"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return drawnCanvas(world) == QColor(QStringLiteral("#222233")); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the app uses the published %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&world] { return settings(world)->ready(); }, QStringLiteral("the shell to read the node's settings again"));
    usesTheme(world, c[0]);
    const QJsonArray list = fakeConfig(world.node).themes.value(world.node.environmentId);
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
    world.node.link(QStringLiteral("env-b"));
    publish(world, QStringLiteral("env-b"), {published(c[0], QStringLiteral("#444444"))});
    world.sync();
  });
  step(QStringLiteral("%1 is not offered").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    for (const QVariant& theme : themes(world)->available()) {
      expect(theme.toMap().value(QStringLiteral("id")) != c[0], QStringLiteral("%1 is offered").arg(c[0]));
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
  step(QStringLiteral("the native chrome and the page both use the new canvas color"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] {
      return drawnCanvas(world) == kShellCanvas &&
             QColor(at(pageTheme(world), QStringLiteral("vars.--app-theme-canvas")).toString()) == kShellCanvas;
    }, [&world] { return QStringLiteral("%1; the page was handed %2").arg(describe(world), show(pageTheme(world))); });
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
      return !world.theme().loaded() && drawnCanvas(world) == publishedCanvas(world) &&
             pageTheme(world).value(QStringLiteral("id")) == themes(world)->resolvedId();
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
               settings(world)->deviceSettings().isEmpty() && fakeConfig(world.node).writes.isEmpty(),
           QStringLiteral("this device holds %1").arg(show(settings(world)->deviceSettings().toVariantMap())));
  });
});

}  // namespace
