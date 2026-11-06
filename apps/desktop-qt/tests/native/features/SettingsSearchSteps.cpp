// Settings as the desktop draws them, navigation beside the page it opens
// (qml/HalC2/Bricks/SettingsNav.qml, SettingsHost.qml): the search's ranking
// and its slash key, a result opened twice or in a scope that cannot show it,
// and restoring defaults (features/settings/search-and-navigation.feature).

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QTest>

#include <algorithm>

#include "Brick.h"
#include "FakeConfig.h"
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

const QString kBrowserAccess = QStringLiteral("enableAgentBrowserAccess");
const QString kSettles = QStringLiteral("threadAutoSettlement");

QVariantMap scopeOf(World& world) {
  return world.state(QStringLiteral("settingsScope")).toMap();
}

// A project in the sidebar, added when this machine has none by that name.
void addProject(World& world, const QString& title) {
  const QVariantList projects = at(world.state(QStringLiteral("sidebar")), QStringLiteral("projects")).toList();
  if (std::any_of(projects.cbegin(), projects.cend(), [&](const QVariant& project) { return at(project, QStringLiteral("displayName")) == title; })) return;
  world.mc.projects.insert(title, {{QStringLiteral("id"), title}, {QStringLiteral("title"), title}, {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + title},
                                   {QStringLiteral("scripts"), QJsonArray()}});
  world.mc.sendRow(title, world.mc.projects.value(title), QStringLiteral("project"));
  world.sync();
}

// Settings for one project, as the scope's project picker chooses it.
void pickProject(World& world, const QString& title) {
  addProject(world, title);
  QString key;
  world.waitFor([&] {
    for (const QVariant& row : scopeOf(world).value(QStringLiteral("projects")).toList()) {
      if (row.toMap().value(QStringLiteral("title")) == title) key = row.toMap().value(QStringLiteral("key")).toString();
    }
    return !key.isEmpty();
  }, [&] { return QStringLiteral("%1 to be offered; the scope is %2").arg(title, show(scopeOf(world))); });
  world.bridge().dispatch(QStringLiteral("settingsScope.project"), QVariantMap{{QStringLiteral("key"), key}});
  world.waitFor([&] { return scopeOf(world).value(QStringLiteral("kind")) == QLatin1String("project") && scopeOf(world).value(QStringLiteral("projectLabel")) == title; },
                [&] { return QStringLiteral("the project scope; it is %1").arg(show(scopeOf(world))); });
}

// This machine and another, by label: the environment each is, and the one
// the settings are scoped to.
struct Environments {
  QHash<QString, QString> ids;
  QString scoped;
};

// This machine labelled `here` and a linked machine `other`, each saying
// whether its MC settles threads; both in the settings scope.
void twoEnvironments(World& world, const QString& here, bool hereSettles, const QString& other, bool otherSettles) {
  Environments& environments = world.mc.part<Environments>();
  environments.ids.insert(here, world.mc.environmentId);
  environments.ids.insert(other, other);
  world.mc.label = here;
  world.mc.announceEnvironment();
  announceHere(world, {{kSettles, hereSettles}});
  fakeConfig(world.mc).elsewhere.insert(other, withCapabilities({}, {{kSettles, otherSettles}}));
  documentOf(world.mc, other).settings = {};
  world.mc.join(other);
  const auto settles = [&](const QString& label, bool expected) {
    for (const QVariant& value : scopeOf(world).value(QStringLiteral("environments")).toList()) {
      const QVariantMap environment = value.toMap();
      if (environment.value(QStringLiteral("label")) != label) continue;
      return environment.value(QStringLiteral("online")).toBool() &&
             environment.value(QStringLiteral("capabilities")).toMap().value(kSettles).toBool() == expected &&
             environment.value(QStringLiteral("capabilities")).toMap().contains(kSettles);
    }
    return false;
  };
  world.waitFor([&] { return scopeOf(world).value(QStringLiteral("targets")).toList().size() == 2 && settles(here, hereSettles) && settles(other, otherSettles); },
                [&] { return QStringLiteral("%1 and %2 in the scope; it is %3").arg(here, other, show(scopeOf(world))); });
}

void scopeTo(World& world, const QString& label) {
  const QString id = world.mc.part<Environments>().ids.value(label);
  world.bridge().dispatch(QStringLiteral("settingsScope.environment"), QVariantMap{{QStringLiteral("id"), id}});
  world.waitFor([&] { return scopeOf(world).value(QStringLiteral("environmentId")) == id; }, [&] { return QStringLiteral("the scope on %1; it is %2").arg(label, show(scopeOf(world))); });
}

// The page shows `text` where the opened setting would be.
void expectNotice(World& world, const QString& text) {
  Brick& brick = settingsShell(world);
  world.waitFor([&] {
    const QQuickItem* notice = brick.find(QStringLiteral("settingsNotice"));
    return notice && notice->isVisible() && brick.shows(text);
  }, [&] { return QStringLiteral("the notice \"%1\"; the route is %2, the scope %3").arg(text, show(world.state(QStringLiteral("route"))), show(scopeOf(world))); });
  const QString target = at(world.state(QStringLiteral("route")), QStringLiteral("target")).toString();
  const QQuickItem* setting = brick.find(target);
  expect(setting == nullptr || !setting->isVisible(), QStringLiteral("%1 shows beside the notice").arg(target));
}

struct Opened {
  QString target;
  QString section;
};

const Steps steps([] {
  const QString q = kQuoted;

  // Sections.
  step(QStringLiteral("the user chooses the %1 section").arg(q), [](World& world, const Captures& c, const Table&) {
    // Tall enough to show every section.
    Brick& brick = settingsShell(world, QSize(900, 800));
    const QVariantList list = rows(world);
    for (int index = 0; index < list.size(); ++index) {
      if (list.at(index).toMap().value(QStringLiteral("label")) != c[0]) continue;
      brick.click(QStringLiteral("settingsRow%1").arg(index));
      world.sync();
      return;
    }
    fail(QStringLiteral("no section is named \"%1\"; %2").arg(c[0], describeRows(world)));
  });
  step(QStringLiteral("the Providers settings are shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      return at(world.state(QStringLiteral("route")), QStringLiteral("section")) == QLatin1String("/settings/providers") &&
             settingsShell(world).item(QStringLiteral("host"))->property("brick") == QLatin1String("ProvidersSettings");
    }, [&] { return QStringLiteral("the route is %1").arg(show(world.state(QStringLiteral("route")))); });
  });
  step(QStringLiteral("%1 is marked as the current section").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& brick = settingsShell(world);
    const QVariantList list = rows(world);
    QStringList current;
    for (int index = 0; index < list.size(); ++index) {
      if (brick.item(QStringLiteral("settingsRow%1").arg(index))->property("current").toBool()) current.append(list.at(index).toMap().value(QStringLiteral("label")).toString());
    }
    expect(current == QStringList{c[0]}, QStringLiteral("the current section is %1").arg(current.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the \"General\" section has keyboard focus"), [](World& world, const Captures&, const Table&) {
    Brick& brick = settingsShell(world);
    expect(rows(world).value(0).toMap().value(QStringLiteral("label")) == QLatin1String("General"), describeRows(world));
    QQuickItem* row = brick.item(QStringLiteral("settingsRow0"));
    row->forceActiveFocus(Qt::TabFocusReason);
    expect(row->hasActiveFocus(), QStringLiteral("General did not take the keyboard"));
  });
  step(QStringLiteral("the user moves down and confirms"), [](World& world, const Captures&, const Table&) {
    Brick& brick = settingsShell(world);
    brick.press(QStringLiteral("down"));
    expect(brick.item(QStringLiteral("settingsRow1"))->hasActiveFocus(), QStringLiteral("the next section did not take the keyboard"));
    brick.press(QStringLiteral("enter"));
    world.sync();
  });
  step(QStringLiteral("the next section opens"), [](World& world, const Captures&, const Table&) {
    const QString next = rows(world).value(1).toMap().value(QStringLiteral("to")).toString();
    expect(!next.isEmpty() && next != QLatin1String("/settings/general") && at(world.state(QStringLiteral("route")), QStringLiteral("section")) == next,
           QStringLiteral("the route is %1, the next section %2").arg(show(world.state(QStringLiteral("route"))), next));
  });

  // Searching.
  step(QStringLiteral("the user has searched settings for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& brick = settingsShell(world);
    brick.click(QStringLiteral("search"));
    for (const QChar character : c[0]) QTest::keyClick(&brick.window(), character.toLatin1());
    world.waitFor([&] { return !rows(world).isEmpty() && rows(world).first().toMap().value(QStringLiteral("result")).toBool(); }, [&] { return describeRows(world); });
  });
  step(QStringLiteral("the user opens the first result"), [](World& world, const Captures&, const Table&) {
    const QVariantMap first = rows(world).value(0).toMap();
    world.mc.part<Opened>() = {first.value(QStringLiteral("targetId")).toString(), first.value(QStringLiteral("to")).toString()};
    settingsShell(world).click(QStringLiteral("settingsRow0"));
    world.sync();
  });
  step(QStringLiteral("the section holding that setting opens"), [](World& world, const Captures&, const Table&) {
    const Opened& opened = world.mc.part<Opened>();
    const QVariant route = world.state(QStringLiteral("route"));
    expect(!opened.target.isEmpty() && at(route, QStringLiteral("section")) == opened.section && at(route, QStringLiteral("target")) == opened.target,
           QStringLiteral("the route is %1; the result was %2 in %3").arg(show(route), opened.target, opened.section));
  });
  step(QStringLiteral("the user is told no settings match"), [](World& world, const Captures&, const Table&) {
    Brick& brick = settingsShell(world);
    expect(rows(world).isEmpty() && brick.item(QStringLiteral("noMatches"))->isVisible() && brick.shows(QStringLiteral("No matching settings")), describeRows(world));
  });
  step(QStringLiteral("the user presses escape in the search"), [](World& world, const Captures&, const Table&) {
    Brick& brick = settingsShell(world);
    expect(brick.item(QStringLiteral("search"))->hasActiveFocus(), QStringLiteral("the search does not have the keyboard"));
    brick.press(QStringLiteral("escape"));
  });
  step(QStringLiteral("the search is empty"), [](World& world, const Captures&, const Table&) {
    const QString text = settingsShell(world).item(QStringLiteral("search"))->property("text").toString();
    expect(text.isEmpty(), QStringLiteral("the search holds \"%1\"").arg(text));
  });
  step(QStringLiteral("the list of sections is shown again"), [](World& world, const Captures&, const Table&) {
    const QVariantList list = rows(world);
    expect(!list.isEmpty() && !list.first().toMap().value(QStringLiteral("result")).toBool() && list.first().toMap().value(QStringLiteral("label")) == QLatin1String("General"),
           describeRows(world));
  });

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
    if (world.onSettingsPage.contains(QStringLiteral("openResult"))) return world.onSettingsPage.value(QStringLiteral("openResult"))(c);
    openResult(world, c[0]);
    world.mc.part<Opened>().target = at(world.state(QStringLiteral("route")), QStringLiteral("target")).toString();
  });
  step(QStringLiteral("the page brings the setting into view"), [](World& world, const Captures&, const Table&) {
    if (world.onSettingsPage.contains(QStringLiteral("inView"))) return world.onSettingsPage.value(QStringLiteral("inView"))({});
    const QString target = world.mc.part<Opened>().target;
    expect(!target.isEmpty(), QStringLiteral("no result was opened; the route is %1").arg(show(world.state(QStringLiteral("route")))));
    world.waitFor([&] { return inView(world, target); }, [&] {
      Brick& brick = settingsShell(world);
      const QQuickItem* item = brick.item(target);
      return QStringLiteral("the page to bring %1 into view: it is at %2, %3 tall, in a page %4 tall")
          .arg(target).arg(item->mapToItem(brick.item(QStringLiteral("host")), QPointF(0, 0)).y()).arg(item->height()).arg(brick.item(QStringLiteral("host"))->height());
    });
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
  // Focus.
  step(QStringLiteral("the user has focus in the settings search"), [](World& world, const Captures&, const Table&) {
    Brick& brick = settingsShell(world);
    brick.click(QStringLiteral("search"));
    expect(brick.item(QStringLiteral("search"))->hasActiveFocus(), QStringLiteral("the search did not take the keyboard"));
  });
  step(QStringLiteral("the list of sections has focus, on the current section"), [](World& world, const Captures&, const Table&) {
    QQuickItem* list = settingsShell(world).item(QStringLiteral("sections"));
    const QString current = settingsShell(world).item(QStringLiteral("nav"))->property("currentSection").toString();
    const QVariantMap row = rows(world).value(list->property("currentIndex").toInt()).toMap();
    expect(list->hasActiveFocus() && row.value(QStringLiteral("to")) == current,
           QStringLiteral("the sections %1 the keyboard, at %2; the section showing is %3").arg(list->hasActiveFocus() ? QStringLiteral("have") : QStringLiteral("do not have"),
                                                                                                  show(row), current));
  });
  step(QStringLiteral("the user presses escape on the settings page"), [](World& world, const Captures&, const Table&) {
    Brick& brick = settingsShell(world);
    brick.item(QStringLiteral("host"))->forceActiveFocus();
    brick.press(QStringLiteral("escape"));
    world.sync();
  });

  // The project section.
  step(QStringLiteral("the user is editing (?:settings for )?all projects"), [](World& world, const Captures&, const Table&) {
    settingsShell(world);
    world.bridge().dispatch(QStringLiteral("settingsScope.project"), QVariantMap{{QStringLiteral("key"), QString()}});
    world.waitFor([&] { return scopeOf(world).value(QStringLiteral("kind")) != QLatin1String("project"); },
                  [&] { return QStringLiteral("all projects; the scope is %1").arg(show(scopeOf(world))); });
  });
  step(QStringLiteral("there is no project section"), [](World& world, const Captures&, const Table&) {
    const QVariantList list = rows(world);
    expect(std::none_of(list.cbegin(), list.cend(), [](const QVariant& row) { return row.toMap().value(QStringLiteral("label")) == QLatin1String("Project"); }),
           describeRows(world));
  });
  step(QStringLiteral("the user chooses the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    addProject(world, c[0]);
    pickProject(world, c[0]);
  });
  step(QStringLiteral("the project section is listed first"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return rows(world).value(0).toMap().value(QStringLiteral("label")) == QLatin1String("Project"); }, [&] { return describeRows(world); });
  });

  // What the search finds.
  step(QStringLiteral("no connected environment has provider settings"), [](World& world, const Captures&, const Table&) {
    settingsShell(world);
    world.mc.stopAccepting();
    world.mc.drop();
    world.waitFor([&world] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to see the drop"));
  });
  step(QStringLiteral("%1 is the only result").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return rows(world).size() == 1 && rows(world).first().toMap().value(QStringLiteral("title")) == c[0]; }, [&] { return describeRows(world); });
  });
  step(QStringLiteral("the user searches settings for %1 with an accent on the e").arg(q), [](World& world, const Captures& c, const Table&) {
    // Typed as the keyboard composes it, which key clicks cannot.
    settingsShell(world).item(QStringLiteral("search"))->setProperty("text", c[0]);
    world.sync();
  });
  step(QStringLiteral("%1 is the first result").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return rows(world).value(0).toMap().value(QStringLiteral("title")) == c[0]; }, [&] { return describeRows(world); });
  });
  step(QStringLiteral("the results are the unpin, archive and delete confirmations in that order"), [](World& world, const Captures&, const Table&) {
    QStringList titles;
    for (const QVariant& row : rows(world)) titles.append(row.toMap().value(QStringLiteral("title")).toString());
    expect(titles.mid(0, 3) == QStringList{QStringLiteral("Unpin confirmation"), QStringLiteral("Archive confirmation"), QStringLiteral("Delete confirmation")},
           describeRows(world));
  });
  step(QStringLiteral("the first result is the %1 keybinding").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap first = rows(world).value(0).toMap();
    expect(first.value(QStringLiteral("title")) == c[0] && first.value(QStringLiteral("sectionLabel")) == QLatin1String("Keybindings") &&
               first.value(QStringLiteral("targetId")).toString().startsWith(QLatin1String("keybinding:")),
           describeRows(world));
  });
  step(QStringLiteral("the model picker keybinding is listed after %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantList list = rows(world);
    int setting = -1;
    int command = -1;
    for (int index = 0; index < list.size(); ++index) {
      const QVariantMap row = list.at(index).toMap();
      if (row.value(QStringLiteral("title")) == c[0]) setting = index;
      if (row.value(QStringLiteral("sectionLabel")) == QLatin1String("Keybindings") && row.value(QStringLiteral("title")).toString().contains(QLatin1String("model picker"), Qt::CaseInsensitive))
        command = index;
    }
    expect(setting >= 0 && command > setting, describeRows(world));
  });

  // Where a result opens.
  step(QStringLiteral("the user opens the search result for the %1 command").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& brick = settingsShell(world, QSize(900, 600));
    brick.item(QStringLiteral("search"))->setProperty("text", c[0]);
    world.sync();
    const QVariantList list = rows(world);
    for (int index = 0; index < list.size(); ++index) {
      const QVariantMap row = list.at(index).toMap();
      if (row.value(QStringLiteral("targetId")) != QStringLiteral("keybinding:") + c[0]) continue;
      world.mc.part<Opened>().target = row.value(QStringLiteral("title")).toString();
      brick.click(QStringLiteral("settingsRow%1").arg(index));
      world.sync();
      return;
    }
    fail(QStringLiteral("no result is the %1 command; %2").arg(c[0], describeRows(world)));
  });
  step(QStringLiteral("the Keybindings section opens at that command's row"), [](World& world, const Captures&, const Table&) {
    Brick& brick = settingsShell(world);
    const QString label = world.mc.part<Opened>().target;
    world.waitFor([&] {
      if (at(world.state(QStringLiteral("route")), QStringLiteral("section")) != QLatin1String("/settings/keybindings")) return false;
      const QQuickItem* draft = brick.find(QStringLiteral("keybindingDraft"));
      const QQuickItem* command = brick.find(QStringLiteral("command"));
      return draft && draft->isVisible() && command && command->property("displayText") == label;
    }, [&] {
      const QQuickItem* command = brick.find(QStringLiteral("command"));
      return QStringLiteral("a new keybinding for \"%1\"; the route is %2, the command shows \"%3\"")
          .arg(label, show(world.state(QStringLiteral("route"))), command ? command->property("displayText").toString() : QStringLiteral("(none)"));
    });
  });
  step(QStringLiteral("window capture is off"), [](World& world, const Captures&, const Table&) {
    settingsShell(world, QSize(900, 300));
    world.bridge().dispatch(QStringLiteral("settings.navigate"), QVariantMap{{QStringLiteral("to"), QStringLiteral("/settings/snap-shot")}});
    world.sync();
    QQuickItem* toggle = settingsShell(world).find(QStringLiteral("snapShot:enabled"));
    expect(toggle != nullptr, QStringLiteral("the SnapShots page has no capture toggle"));
    const QQuickItem* control = toggle->findChild<QQuickItem*>(QStringLiteral("control"));
    expect(control && !control->property("checked").toBool(), QStringLiteral("window capture is on"));
  });
  step(QStringLiteral("the window capture toggle is brought into view"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return inView(world, QStringLiteral("snapShot:enabled")); }, QStringLiteral("the capture toggle to come into view"));
  });

  // Settings some environments, or another scope, hold.
  step(QStringLiteral("%1 can settle threads and %1 cannot").arg(q), [](World& world, const Captures& c, const Table&) {
    settingsShell(world, QSize(900, 600));
    twoEnvironments(world, c[0], true, c[1], false);
  });
  step(QStringLiteral("the settings are scoped to %1, which cannot settle threads").arg(q), [](World& world, const Captures& c, const Table&) {
    settingsShell(world, QSize(900, 600));
    world.mc.part<Environments>().scoped = c[0];
  });
  step(QStringLiteral("%1 can settle threads").arg(q), [](World& world, const Captures& c, const Table&) {
    twoEnvironments(world, c[0], true, world.mc.part<Environments>().scoped, false);
    scopeTo(world, world.mc.part<Environments>().scoped);
  });
  step(QStringLiteral("no environment can settle threads"), [](World& world, const Captures&, const Table&) {
    twoEnvironments(world, QStringLiteral("laptop"), false, world.mc.part<Environments>().scoped, false);
    scopeTo(world, world.mc.part<Environments>().scoped);
  });
  step(QStringLiteral("the results are found"), [](World& world, const Captures&, const Table&) {
    const QVariantList list = rows(world);
    QStringList titles;
    for (const QVariant& row : list) titles.append(row.toMap().value(QStringLiteral("title")).toString());
    expect(titles.contains(QStringLiteral("Auto-settle merged threads")) && titles.contains(QStringLiteral("Auto-settle inactive threads")), describeRows(world));
  });
  step(QStringLiteral("choosing one offers %1 and not %1").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& brick = settingsShell(world);
    const QVariantList list = rows(world);
    for (int index = 0; index < list.size(); ++index) {
      if (list.at(index).toMap().value(QStringLiteral("title")) != QLatin1String("Auto-settle merged threads")) continue;
      brick.click(QStringLiteral("settingsRow%1").arg(index));
      world.sync();
      break;
    }
    const Environments& environments = world.mc.part<Environments>();
    const QString offered = QStringLiteral("choose:") + environments.ids.value(c[0]);
    const QString withheld = QStringLiteral("choose:") + environments.ids.value(c[1]);
    world.waitFor([&] {
      const QQuickItem* button = brick.find(offered);
      return button && button->isVisible() && button->property("text") == c[0] && brick.find(withheld) == nullptr;
    }, [&] { return QStringLiteral("%1 offered and not %2; the notice is %3").arg(offered, withheld, show(brick.find(QStringLiteral("settingsNotice")) ? brick.item(QStringLiteral("settingsNotice"))->isVisible() : false)); });
  });
  step(QStringLiteral("the page says %1 in place of the settings").arg(q), [](World& world, const Captures& c, const Table&) {
    expectNotice(world, c[0]);
  });
  step(QStringLiteral("the settings are scoped to the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    settingsShell(world, QSize(900, 600));
    world.bridge().dispatch(QStringLiteral("settingsScope.environment"), QVariantMap{{QStringLiteral("id"), QString()}});
    pickProject(world, c[0]);
  });
  step(QStringLiteral("the user opens the search result of a setting that is set per environment"), [](World& world, const Captures&, const Table&) {
    // Automatic Git fetch interval is one setting for all of an environment's projects.
    world.bridge().dispatch(QStringLiteral("settings.openResult"), QVariantMap{{QStringLiteral("to"), QStringLiteral("/settings/source-control")},
                                                                               {QStringLiteral("targetId"), QStringLiteral("fetchInterval")}});
    world.sync();
  });
  step(QStringLiteral("the page says that setting is not available for the selected target and to choose its owning scope"), [](World& world, const Captures&, const Table&) {
    expectNotice(world, QStringLiteral("Automatic Git fetch interval is not available for the selected target. Choose its owning scope to continue."));
  });
  step(QStringLiteral("the user can choose the scope there to carry on to the setting"), [](World& world, const Captures&, const Table&) {
    Brick& brick = settingsShell(world);
    brick.click(QStringLiteral("choose:allProjects"));
    world.waitFor([&] {
      const QVariant route = world.state(QStringLiteral("route"));
      return scopeOf(world).value(QStringLiteral("kind")) != QLatin1String("project") && !brick.item(QStringLiteral("settingsNotice"))->isVisible() &&
             at(route, QStringLiteral("section")) == QLatin1String("/settings/source-control") && at(route, QStringLiteral("target")) == QLatin1String("fetchInterval");
    }, [&] { return QStringLiteral("the setting in its own scope; the scope is %1, the route %2").arg(show(scopeOf(world)), show(world.state(QStringLiteral("route")))); });
    world.waitFor([&] { return inView(world, QStringLiteral("fetchInterval")); }, QStringLiteral("the setting to come into view"));
  });
  step(QStringLiteral("no environment is the primary one"), [](World& world, const Captures&, const Table&) {
    // Every environment, none of them first.
    settingsShell(world);
    twoEnvironments(world, QStringLiteral("laptop"), false, QStringLiteral("server"), false);
    world.bridge().dispatch(QStringLiteral("settingsScope.environment"), QVariantMap{{QStringLiteral("id"), QString()}});
    world.waitFor([&] { return scopeOf(world).value(QStringLiteral("kind")) == QLatin1String("all"); }, [&] { return show(scopeOf(world)); });
  });

  // Restoring, when there is nothing to restore, and the MC's settings.
  step(QStringLiteral("every setting the restore covers is at its default"), [](World& world, const Captures&, const Table&) {
    const QStringList changed = settingsShell(world).item(QStringLiteral("nav"))->property("changedLabels").toStringList();
    expect(changed.isEmpty(), QStringLiteral("%1 changed").arg(changed.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the user looks at the settings page"), [](World& world, const Captures&, const Table&) {
    settingsShell(world);
    world.sync();
  });
  step(QStringLiteral("restoring default settings cannot be chosen"), [](World& world, const Captures&, const Table&) {
    expect(!settingsShell(world).item(QStringLiteral("restoreDefaults"))->isEnabled(), QStringLiteral("restoring defaults is offered"));
  });
  step(QStringLiteral("the user turned agent browser access off"), [](World& world, const Captures&, const Table&) {
    settingsShell(world);
    world.waitFor([&] { return settings(world)->ready() && settings(world)->disabledReason(kBrowserAccess).isEmpty(); },
                  [&] { return QStringLiteral("the setting to be editable: %1").arg(settings(world)->disabledReason(kBrowserAccess)); });
    settings(world)->set(kBrowserAccess, false);
    world.waitFor([&] { return fakeConfig(world.mc).settings.value(kBrowserAccess) == QJsonValue(false) && settings(world)->setting(kBrowserAccess) == false; },
                  [&] { return QStringLiteral("the MC holds %1").arg(show(fakeConfig(world.mc).settings.toVariantMap())); });
  });
  step(QStringLiteral("the confirmation lists agent browser access among the settings it will reset"), [](World& world, const Captures&, const Table&) {
    const QString text = dialogList(world)->property("text").toString();
    expect(text.contains(QLatin1String("Agent browser access")), QStringLiteral("the question reads \"%1\"").arg(text));
    world.answerQuestion = [&world](bool accepted) { answerRestore(world, accepted); };
  });
  step(QStringLiteral("agents have browser access again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QJsonValue held = fakeConfig(world.mc).settings.value(kBrowserAccess);
      return (held.isUndefined() || held == QJsonValue(true)) && settings(world)->setting(kBrowserAccess) == true;
    }, [&] { return QStringLiteral("the MC holds %1").arg(show(fakeConfig(world.mc).settings.toVariantMap())); });
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
