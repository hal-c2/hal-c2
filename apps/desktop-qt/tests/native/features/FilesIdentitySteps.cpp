// Project and environment identity (features/files/project-identity.feature):
// the icons IdentityController publishes, the pickers as the window draws
// them (ProjectIconPicker.qml in Settings → Projects, EnvironmentIconPicker.qml),
// and an environment theme. The MC's side: `assets.createUrl` for a project's
// favicon and `/api/auth/session` for what this session may do.

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickItem>
#include <QTcpSocket>
#include <QTest>

#include "Brick.h"
#include "FakeConfig.h"
#include "FakeFiles.h"
#include "FilesIdentity.h"
#include "Harness.h"
#include "McClient.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ThemeController.h"
#include "World.h"

namespace {

struct FakeIdentity {
  // What this session may do, as `/api/auth/session` lists it.
  QJsonArray scopes{QStringLiteral("orchestration:read"), QStringLiteral("orchestration:operate")};
  // The environment the scenario's pickers are for.
  QString project;
};

const FakeMc::Extension extension([](FakeMc& mc) {
  // A favicon the project has or the user picked, else the MC's "none" (apps/server-ex attachments.ex).
  mc.onRpc(QStringLiteral("assets.createUrl"), [&mc](const FakeMc::Rpc& rpc) {
    const QJsonObject resource = rpc.payload.value(QLatin1String("resource")).toObject();
    if (resource.value(QLatin1String("_tag")) != QLatin1String("project-favicon")) {
      mc.passOn(rpc);
      return;
    }
    const QString path = resource.value(QLatin1String("path")).toString();
    const bool served = !path.isEmpty() && fakeFiles(mc).files.contains(path);
    mc.reply(rpc, QJsonObject{{QStringLiteral("relativeUrl"), QStringLiteral("/api/assets/token/") +
                                                                    (served ? QStringLiteral("v1-") + path.section(QLatin1Char('/'), -1)
                                                                            : QStringLiteral("project-favicon-missing"))},
                                {QStringLiteral("expiresAt"), 1790000000000.0}});
  });
  mc.onRaw(QStringLiteral("/api/auth/session"), [&mc](QTcpSocket* socket, const QByteArray& head) {
    socket->read(head.size());
    const QByteArray body = QJsonDocument(QJsonObject{{QStringLiteral("authenticated"), true}, {QStringLiteral("scopes"), mc.part<FakeIdentity>().scopes}})
                                .toJson(QJsonDocument::Compact);
    socket->write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " + QByteArray::number(body.size()) +
                  "\r\n\r\n" + body);
    socket->disconnectFromHost();
  });
});

QVariantMap iconOf(World& world, const QString& project) {
  return world.state(QStringLiteral("projectIcons")).toMap().value(world.mc.environmentId + QLatin1Char(':') + project).toMap();
}

QJsonObject savedIcon(World& world, const QString& project) {
  return world.mc.projects.value(project).value(QLatin1String("projectIcon")).toObject();
}

QVariantMap picker(World& world) {
  return world.state(QStringLiteral("projectIconPicker")).toMap();
}

QVariantMap machine(World& world, const QString& environment) {
  return world.state(QStringLiteral("environmentIcons")).toMap().value(environment).toMap();
}

// What a ProjectIcon draws of `icon`: "monogram SH", "emoji 🛒", "symbol rocket" or "image <url>".
QString drawn(World& world, const QString& project) {
  Brick brick(world, QStringLiteral("import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\n"
                                    "ProjectIcon { size: 32; icon: Shell.state.projectIcons?.[\"%1:%2\"] ?? null }\n")
                         .arg(world.mc.environmentId, project).toUtf8(),
              QSize(32, 32));
  const auto part = [&](const char* name) { return brick.root()->findChild<QQuickItem*>(QLatin1String(name)); };
  if (part("projectIconMonogram")->isVisible()) return QStringLiteral("monogram ") + part("projectIconMonogram")->childItems().first()->property("text").toString();
  if (part("projectIconEmoji")->isVisible()) return QStringLiteral("emoji ") + part("projectIconEmoji")->property("text").toString();
  if (part("projectIconSymbol")->isVisible()) return QStringLiteral("symbol ") + part("projectIconSymbol")->property("name").toString();
  return QStringLiteral("image ") + part("projectIconImage")->property("source").toString();
}

// Settings → Projects on `project`, with the picker the window keeps over it.
void manage(World& world, const QString& project) {
  world.mc.part<FakeIdentity>().project = project;
  world.native().controller<NavigationController>()->open(NavigationController::Route::settings(QStringLiteral("/settings/projects")));
  QString key;
  world.waitFor([&] {
    for (const QVariant& row : world.state(QStringLiteral("settingsScope")).toMap().value(QStringLiteral("projects")).toList()) {
      if (row.toMap().value(QStringLiteral("title")) == project) key = row.toMap().value(QStringLiteral("key")).toString();
    }
    return !key.isEmpty();
  }, [&] { return QStringLiteral("%1 to be offered; the scope is %2").arg(project, show(world.state(QStringLiteral("settingsScope")))); });
  world.bridge().dispatch(QStringLiteral("settingsScope.project"), QVariantMap{{QStringLiteral("key"), key}});
  world.waitFor([&] {
    const QVariantMap panel = world.state(QStringLiteral("projectSettings")).toMap();
    return panel.value(QStringLiteral("status")) == QLatin1String("ready") && panel.value(QStringLiteral("name")) == project;
  }, [&] { return QStringLiteral("%1 to be managed; the panel is %2").arg(project, show(world.state(QStringLiteral("projectSettings")))); });
  world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nItem {\n  ProjectSettings { anchors.fill: parent }\n  ProjectIconPicker {}\n}\n",
                                        QSize(900, 800));
}

void openPicker(World& world, const QString& project) {
  manage(world, project);
  world.brick->click(QStringLiteral("choose"));
  world.waitFor([&] { return !picker(world).isEmpty(); }, QStringLiteral("the icon picker to open"));
  world.waitFor([&] { return world.brick->root()->findChild<QObject*>(QStringLiteral("projectIconPicker"))->property("opened").toBool(); },
                QStringLiteral("the icon picker to show"));
}

void type(World& world, const QString& field, const QString& text) {
  world.brick->click(field);
  QQuickItem* item = world.brick->item(field);
  expect(item->hasActiveFocus(), QStringLiteral("%1 did not take the keyboard").arg(field));
  QMetaObject::invokeMethod(item, "selectAll");
  for (const QChar character : text) QTest::keyClick(&world.brick->window(), character.toLatin1());
}

void waitForIcon(World& world, const QString& project, const std::function<bool(const QVariantMap&)>& matches) {
  world.waitFor([&] { return matches(iconOf(world, project)); },
                [&] { return QStringLiteral("the icon of %1; it is %2 (the MC keeps %3)").arg(project, show(iconOf(world, project)), show(savedIcon(world, project).toVariantMap())); });
}

// "the monogram "SH" in rose" and its kin, as the outline words them.
void pick(World& world, const QString& project, const QString& what) {
  static const QRegularExpression symbol(QStringLiteral("^the \"([^\"]+)\" symbol in (\\w+)$"));
  static const QRegularExpression emoji(QStringLiteral("^the emoji \"([^\"]+)\"$"));
  static const QRegularExpression monogram(QStringLiteral("^the monogram \"([^\"]+)\" in (\\w+)$"));
  static const QRegularExpression image(QStringLiteral("^the image file \"([^\"]+)\"$"));
  openPicker(world, project);
  if (const auto match = symbol.match(what); match.hasMatch()) {
    world.brick->click(QStringLiteral("projectIconMode-lucide"));
    world.brick->click(QStringLiteral("projectIconColor-") + match.captured(2));
    world.brick->click(QStringLiteral("projectIconSymbol-") + match.captured(1));
    world.brick->click(QStringLiteral("projectIconSave"));
  } else if (const auto match = emoji.match(what); match.hasMatch()) {
    world.brick->click(QStringLiteral("projectIconMode-emoji"));
    // An emoji comes from the system's picker, not from keys.
    world.bridge().dispatch(QStringLiteral("projectIcon.set"), QVariantMap{{QStringLiteral("emoji"), match.captured(1)}});
    world.brick->click(QStringLiteral("projectIconSave"));
  } else if (const auto match = monogram.match(what); match.hasMatch()) {
    world.brick->click(QStringLiteral("projectIconMode-monogram"));
    world.brick->click(QStringLiteral("projectIconColor-") + match.captured(2));
    type(world, QStringLiteral("projectIconLetters"), match.captured(1));
    world.brick->click(QStringLiteral("projectIconSave"));
  } else if (const auto match = image.match(what); match.hasMatch()) {
    fakeFiles(world.mc).files.insert(match.captured(1), QStringLiteral("PNG"));
    world.brick->click(QStringLiteral("projectIconMode-image"));
    type(world, QStringLiteral("projectIconSearch"), match.captured(1).section(QLatin1Char('/'), -1).section(QLatin1Char('.'), 0, 0));
    world.waitFor([&] { return picker(world).value(QStringLiteral("images")).toStringList().contains(match.captured(1)); },
                  [&] { return QStringLiteral("%1 to be offered; the picker is %2").arg(match.captured(1), show(picker(world))); });
    world.brick->click(QStringLiteral("projectIconImage-") + match.captured(1));
  } else {
    fail(QStringLiteral("these steps do not know the icon \"%1\"").arg(what));
  }
  world.sync();
}

void expectShown(World& world, const QString& project, const QString& what) {
  static const QRegularExpression symbol(QStringLiteral("^the \"([^\"]+)\" symbol in (\\w+)$"));
  static const QRegularExpression emoji(QStringLiteral("^the emoji \"([^\"]+)\"$"));
  static const QRegularExpression monogram(QStringLiteral("^the monogram \"([^\"]+)\" in (\\w+)$"));
  static const QRegularExpression image(QStringLiteral("^the image file \"([^\"]+)\"$"));
  QString wanted;
  if (const auto match = symbol.match(what); match.hasMatch()) {
    waitForIcon(world, project, [&](const QVariantMap& icon) {
      return icon.value(QStringLiteral("kind")) == QLatin1String("lucide") && icon.value(QStringLiteral("name")) == match.captured(1) &&
             icon.value(QStringLiteral("color")) == match.captured(2);
    });
    wanted = QStringLiteral("symbol ") + match.captured(1);
  } else if (const auto match = emoji.match(what); match.hasMatch()) {
    waitForIcon(world, project, [&](const QVariantMap& icon) { return icon.value(QStringLiteral("kind")) == QLatin1String("emoji") && icon.value(QStringLiteral("emoji")) == match.captured(1); });
    wanted = QStringLiteral("emoji ") + match.captured(1);
  } else if (const auto match = monogram.match(what); match.hasMatch()) {
    waitForIcon(world, project, [&](const QVariantMap& icon) {
      return icon.value(QStringLiteral("kind")) == QLatin1String("monogram") && icon.value(QStringLiteral("text")) == match.captured(1) &&
             icon.value(QStringLiteral("color")) == match.captured(2) && !icon.value(QStringLiteral("automatic")).toBool();
    });
    wanted = QStringLiteral("monogram ") + match.captured(1);
  } else if (const auto match = image.match(what); match.hasMatch()) {
    waitForIcon(world, project, [&](const QVariantMap& icon) { return icon.value(QStringLiteral("kind")) == QLatin1String("image") && icon.value(QStringLiteral("path")) == match.captured(1); });
    expect(world.mc.projects.value(project).value(QLatin1String("faviconPath")) == match.captured(1) && savedIcon(world, project).isEmpty(),
           QStringLiteral("the MC keeps %1").arg(show(world.mc.projects.value(project).toVariantMap())));
    wanted = QStringLiteral("image ") + world.mc.origin().toString() + QStringLiteral("/api/assets/token/v1-") + match.captured(1).section(QLatin1Char('/'), -1);
  } else {
    fail(QStringLiteral("these steps do not know the icon \"%1\"").arg(what));
  }
  // Every list draws a project through the one brick.
  const QString shown = drawn(world, project);
  expect(shown == wanted, QStringLiteral("%1 is drawn as \"%2\"").arg(project, shown));
  // The settings page's own word for it follows.
  const auto row = [&] { return world.state(QStringLiteral("projectSettings")).toMap().value(QStringLiteral("icon")).toMap(); };
  world.waitFor([&] { return row().value(QStringLiteral("custom")).toBool(); }, [&] { return QStringLiteral("settings to show it; they show %1").arg(show(row())); });
}

// The MC's `environment` descriptor of its own config, announced as it changes.
void describeEnvironment(World& world, const QString& machineKind, bool keepsIcon) {
  QJsonObject descriptor{{QStringLiteral("environmentId"), world.mc.environmentId},
                         {QStringLiteral("capabilities"), keepsIcon ? QJsonObject{{QStringLiteral("environmentIcon"), true}} : QJsonObject()}};
  if (!machineKind.isEmpty()) descriptor.insert(QStringLiteral("platform"), QJsonObject{{QStringLiteral("machine"), machineKind}});
  FakeConfig& fake = fakeConfig(world.mc);
  fake.config.insert(QStringLiteral("environment"), descriptor);
  QJsonObject config = fake.config;
  config.insert(QStringLiteral("settings"), fake.settings);
  for (const int id : world.mc.subscribers(QStringLiteral("config"))) {
    if (world.mc.shapeOf(id).value(QLatin1String("environment")) != world.mc.environmentId) continue;
    world.mc.send({{QStringLiteral("t"), QStringLiteral("config")}, {QStringLiteral("id"), id}, {QStringLiteral("config"), config}});
  }
  world.sync();
}

// Picks `kind` in the environment's picker, as Settings → Connections shows it.
void mark(World& world, const QString& environment, const QString& kind) {
  world.waitFor([&] { return machine(world, environment).value(QStringLiteral("lock")).toString().isEmpty() && !machine(world, environment).isEmpty(); },
                [&] { return QStringLiteral("the icon of %1 to be changeable; it is %2").arg(environment, show(machine(world, environment))); });
  world.brick = std::make_unique<Brick>(world, QStringLiteral("import QtQuick\nimport HalC2.Bricks\nEnvironmentIconPicker { environmentId: \"%1\" }\n").arg(environment).toUtf8(),
                                        QSize(520, 60));
  QQuickItem* combo = world.brick->item(QStringLiteral("environmentIconKind"));
  const QVariantList kinds = machine(world, environment).value(QStringLiteral("kinds")).toList();
  int index = -1;
  for (int row = 0; row < kinds.size(); ++row) {
    if (kinds.at(row).toMap().value(QStringLiteral("kind")) == kind) index = row;
  }
  expect(index >= 0 && combo->isEnabled(), QStringLiteral("%1 cannot be picked; the picker is %2").arg(kind, show(machine(world, environment))));
  QMetaObject::invokeMethod(combo, "activated", Q_ARG(int, index));
  world.sync();
}

int settingsWrites(World& world) {
  return int(fakeConfig(world.mc).writes.size());
}

}  // namespace

bool disconnectOwnEnvironment(World& world, const QString& environment) {
  if (environment != world.mc.environmentId) return false;
  world.mc.stopAccepting();
  world.mc.drop();
  world.waitFor([&world] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to see the drop"));
  return true;
}

bool checkIconImageOffered(World& world, const QString& path, bool offered) {
  if (picker(world).isEmpty()) return false;
  const QStringList images = picker(world).value(QStringLiteral("images")).toStringList();
  expect(images.contains(path) == offered, QStringLiteral("the picker offers %1").arg(images.join(u", ")));
  // As the picker lists them.
  if (offered) expect(world.brick->item(QStringLiteral("projectIconImage-") + path)->isVisible(), QStringLiteral("%1 is not listed").arg(path));
  return true;
}

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  // Monograms.
  step(QStringLiteral("the project %1 has no icon").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject row{{QStringLiteral("id"), c[0]}, {QStringLiteral("title"), c[0]}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + c[0]},
                          {QStringLiteral("createdAt"), QStringLiteral("2026-09-01T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-01T09:00:00Z")},
                          {QStringLiteral("scripts"), QJsonArray()}};
    world.mc.projects.insert(c[0], row);
    world.mc.sendRow(c[0], row, QStringLiteral("project"));
    world.sync();
  });
  step(QStringLiteral("the user looks at the project list"), [](World& world, const Captures&, const Table&) {
    world.sync();  // the rows have arrived
    world.sync();  // and the MC has said none of them has a favicon
  });
  step(QStringLiteral("%1 shows the monogram %1 in a colour derived from its name").arg(q), [](World& world, const Captures& c, const Table&) {
    // The colour each of these names derives.
    static const QHash<QString, QString> colours{{QStringLiteral("Nebula"), QStringLiteral("red")},
                                                 {QStringLiteral("Silver Orchard"), QStringLiteral("sky")},
                                                 {QStringLiteral("M7 Forge"), QStringLiteral("emerald")}};
    expect(colours.contains(c[0]), QStringLiteral("these steps do not know the colour of %1").arg(c[0]));
    waitForIcon(world, c[0], [&](const QVariantMap& icon) {
      return icon.value(QStringLiteral("kind")) == QLatin1String("monogram") && icon.value(QStringLiteral("text")) == c[1] &&
             icon.value(QStringLiteral("color")) == colours.value(c[0]) && icon.value(QStringLiteral("automatic")).toBool();
    });
    expect(drawn(world, c[0]) == QStringLiteral("monogram ") + c[1], QStringLiteral("%1 is drawn as \"%2\"").arg(c[0], drawn(world, c[0])));
  });

  // The picker.
  step(QStringLiteral("the user sets? the icon of %1 to (.+)").arg(q), [](World& world, const Captures& c, const Table&) { pick(world, c[0], c[1]); });
  step(QStringLiteral("%1 shows (.+) everywhere it is listed").arg(q), [](World& world, const Captures& c, const Table&) { expectShown(world, c[0], c[1]); });
  step(QStringLiteral("the user resets the icon of %1").arg(q), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.brick->item(QStringLiteral("automatic"))->isVisible(); }, QStringLiteral("settings to offer the automatic icon"));
    world.brick->click(QStringLiteral("automatic"));
    world.sync();
  });
  step(QStringLiteral("the user types %1 as the monogram of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openPicker(world, c[1]);
    world.brick->click(QStringLiteral("projectIconMode-monogram"));
    type(world, QStringLiteral("projectIconLetters"), c[0]);
    world.brick->click(QStringLiteral("projectIconSave"));
    world.sync();
  });
  step(QStringLiteral("the monogram is saved as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString project = world.mc.part<FakeIdentity>().project;
    waitForIcon(world, project, [&](const QVariantMap& icon) { return icon.value(QStringLiteral("kind")) == QLatin1String("monogram") && icon.value(QStringLiteral("text")) == c[0]; });
    expect(savedIcon(world, project).value(QLatin1String("monogramText")) == c[0] && picker(world).isEmpty(),
           QStringLiteral("the MC keeps %1").arg(show(savedIcon(world, project).toVariantMap())));
  });
  step(QStringLiteral("the monogram cannot be saved"), [](World& world, const Captures&, const Table&) {
    const QString project = world.mc.part<FakeIdentity>().project;
    expect(picker(world).value(QStringLiteral("error")) == QLatin1String("Use one or two letters or numbers.") &&
               world.brick->shows(QStringLiteral("Use one or two letters or numbers.")) && savedIcon(world, project).isEmpty() &&
               iconOf(world, project).value(QStringLiteral("automatic")).toBool(),
           QStringLiteral("the picker is %1 and the MC keeps %2").arg(show(picker(world)), show(savedIcon(world, project).toVariantMap())));
  });
  step(QStringLiteral("%1 runs an older server that only knows symbol icons").arg(q), [](World& world, const Captures& c, const Table&) {
    // Such a server reads `kind`, `name` and `color` and carries the rest along.
    expect(world.mc.environmentId == c[0], QStringLiteral("the environment is %1").arg(world.mc.environmentId));
  });
  step(QStringLiteral("the user sets the monogram %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    pick(world, c[1], QStringLiteral("the monogram \"%1\" in rose").arg(c[0]));
  });
  step(QStringLiteral("%1 keeps a folder symbol with the letters %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString project = world.mc.part<FakeIdentity>().project;
    world.waitFor([&] { return !savedIcon(world, project).isEmpty(); }, QStringLiteral("the icon to be saved"));
    const QJsonObject wanted{{QStringLiteral("kind"), QStringLiteral("lucide")}, {QStringLiteral("name"), QStringLiteral("folder-code")},
                             {QStringLiteral("color"), QStringLiteral("rose")}, {QStringLiteral("monogramText"), c[1]}};
    expect(savedIcon(world, project) == wanted, QStringLiteral("%1 keeps %2").arg(c[0], show(savedIcon(world, project).toVariantMap())));
    // And this desktop draws the letters.
    waitForIcon(world, project, [&](const QVariantMap& icon) { return icon.value(QStringLiteral("text")) == c[1]; });
  });
  step(QStringLiteral("the user searches the project for an icon image named %1").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(QStringLiteral("assets/%1.png").arg(c[0]), QStringLiteral("PNG"));
    fakeFiles(world.mc).files.insert(QStringLiteral("src/%1.ts").arg(c[0]), QStringLiteral("export {};\n"));
    openPicker(world, QStringLiteral("shop"));
    world.brick->click(QStringLiteral("projectIconMode-image"));
    type(world, QStringLiteral("projectIconSearch"), c[0]);
    world.waitFor([&] { return picker(world).value(QStringLiteral("query")) == c[0] && !picker(world).value(QStringLiteral("searching")).toBool(); },
                  [&] { return QStringLiteral("the search to finish; the picker is %1").arg(show(picker(world))); });
  });

  // Environment icons.
  step(QStringLiteral("%1 is detected as a (laptop|server|desktop)").arg(q), [](World& world, const Captures& c, const Table&) {
    describeEnvironment(world, c[1], true);
    world.waitFor([&] { return machine(world, c[0]).value(QStringLiteral("detected")) == c[1] && machine(world, c[0]).value(QStringLiteral("kind")) == c[1]; },
                  [&] { return QStringLiteral("%1 to be a %2; it is %3").arg(c[0], c[1], show(machine(world, c[0]))); });
  });
  step(QStringLiteral("the user marks %1 as a (laptop|server|desktop)(?:, its detected kind)?").arg(q), [](World& world, const Captures& c, const Table&) {
    mark(world, c[0], c[1]);
  });
  step(QStringLiteral("the user marked %1 as a (server|desktop)").arg(q), [](World& world, const Captures& c, const Table&) {
    describeEnvironment(world, QStringLiteral("laptop"), true);
    mark(world, c[0], c[1]);
    world.waitFor([&] { return machine(world, c[0]).value(QStringLiteral("kind")) == c[1]; }, [&] { return show(machine(world, c[0])); });
  });
  step(QStringLiteral("%1 shows a (server|laptop|desktop) icon").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return machine(world, c[0]).value(QStringLiteral("kind")) == c[1]; },
                  [&] { return QStringLiteral("%1 to show a %2; it is %3").arg(c[0], c[1], show(machine(world, c[0]))); });
    expect(fakeConfig(world.mc).settings.value(QLatin1String("environmentIcon")) == c[1] && machine(world, c[0]).value(QStringLiteral("chosen")).toBool(),
           QStringLiteral("the MC keeps %1").arg(show(fakeConfig(world.mc).settings.toVariantMap())));
    // As the picker draws it.
    expect(world.brick->item(QStringLiteral("environmentIcon"))->property("name") == machine(world, c[0]).value(QStringLiteral("icon")),
           QStringLiteral("the picker draws %1").arg(world.brick->item(QStringLiteral("environmentIcon"))->property("name").toString()));
  });
  step(QStringLiteral("%1 follows its detected kind again").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !machine(world, c[0]).value(QStringLiteral("chosen")).toBool(); },
                  [&] { return QStringLiteral("the choice to go; %1 is %2").arg(c[0], show(machine(world, c[0]))); });
    expect(machine(world, c[0]).value(QStringLiteral("kind")) == machine(world, c[0]).value(QStringLiteral("detected")) &&
               !fakeConfig(world.mc).settings.contains(QLatin1String("environmentIcon")),
           QStringLiteral("the MC keeps %1").arg(show(fakeConfig(world.mc).settings.toVariantMap())));
  });
  step(QStringLiteral("%1 runs a server too old to keep one").arg(q), [](World& world, const Captures&, const Table&) {
    describeEnvironment(world, QStringLiteral("laptop"), false);
  });
  step(QStringLiteral("the user's session cannot change settings"), [](World& world, const Captures&, const Table&) {
    describeEnvironment(world, QStringLiteral("laptop"), true);
    world.mc.part<FakeIdentity>().scopes = QJsonArray{QStringLiteral("orchestration:read")};
  });
  step(QStringLiteral("the user tries to change the icon of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const int writes = settingsWrites(world);
    world.bridge().dispatch(QStringLiteral("environmentIcon.set"), QVariantMap{{QStringLiteral("environmentId"), c[0]}, {QStringLiteral("kind"), QStringLiteral("server")}});
    // Told as a toast, which "the user is told" reads; nothing is saved.
    world.waitFor([&] { return !at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList().isEmpty(); }, QStringLiteral("the user to be told"));
    expect(settingsWrites(world) == writes, QStringLiteral("the settings were written"));
  });

  // An environment's theme.
  step(QStringLiteral("%1 offers the theme %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonArray list{QJsonObject{{QStringLiteral("id"), c[1]}, {QStringLiteral("name"), c[1]}, {QStringLiteral("appearance"), QStringLiteral("dark")},
                                      {QStringLiteral("canvas"), QStringLiteral("#1b1626")}, {QStringLiteral("accent"), QStringLiteral("#ff8800")}}};
    publishThemes(world.mc, c[0], list);
    auto* settings = world.native().controller<SettingsController>();
    world.waitFor([&] { return settings->themes() == list; }, QStringLiteral("the shell to hear of the theme"));
    const QVariantList offered = world.native().controller<ThemeController>()->available();
    expect(std::any_of(offered.cbegin(), offered.cend(), [&](const QVariant& theme) { return theme.toMap().value(QStringLiteral("id")) == c[1]; }),
           QStringLiteral("the themes offered are %1").arg(show(offered)));
  });
  step(QStringLiteral("the user picks the theme %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // A dark theme, seen in the dark.
    world.native().controller<ThemeController>()->setSystemDark(true);
    expect(world.native().controller<ThemeController>()->choose(c[0]), QStringLiteral("%1 cannot be chosen").arg(c[0]));
  });
  step(QStringLiteral("the app uses the colours of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    auto* themes = world.native().controller<ThemeController>();
    world.waitFor([&] { return themes->resolvedId() == c[0] && world.theme().color(QStringLiteral("canvas"), QColor()) == QColor(QStringLiteral("#1b1626")); },
                  [&] { return QStringLiteral("%1; the shell resolved %2 and draws %3").arg(c[0], themes->resolvedId(), world.theme().color(QStringLiteral("canvas"), QColor()).name()); });
  });
});

}  // namespace
