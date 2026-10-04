// UI plugins on the desktop (features/plugins/ui-plugins.feature,
// plugin-catalog.feature): plugin files in the shell's config directory,
// loaded into the real DefaultShell window by the bricks' PluginRegistry, and
// the plugin controller's list, switches and URL installs.

#include <QDir>
#include <QFile>
#include <QJSValue>
#include <QJsonArray>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTcpSocket>
#include <QTest>

#include "Brick.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "PluginController.h"
#include "ShellWindows.h"
#include "World.h"

namespace {

// What the MC's web server hands out as plugin files, and what was asked of it.
struct FakePluginSite {
  QHash<QString, QByteArray> files;
  QStringList requests;
};

struct PluginWorld {
  QString url;
  QString plugin;
  QString draft;
  QQuickWindow* window = nullptr;
};

const FakeMc::Extension site([](FakeMc& mc) {
  mc.onRaw(QStringLiteral("/plugin-files/"), [&mc](QTcpSocket* socket, const QByteArray& head) {
    FakePluginSite& fake = mc.part<FakePluginSite>();
    const QString target = QString::fromUtf8(head.split('\n').value(0).split(' ').value(1));
    socket->read(head.size());
    fake.requests.append(target);
    const QByteArray body = fake.files.value(target.section(QLatin1Char('/'), -1));
    if (body.isEmpty()) {
      socket->write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    } else {
      socket->write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n" + body);
    }
    socket->flush();
    socket->disconnectFromHost();
  });
});

// A plugin as the terminal client's fixtures write one: "[id]" in its slot.
QByteArray pluginSource(const QString& id, const QString& slot, const QString& label = {}) {
  return QStringLiteral("import OpenTUI\nPlugin {\n  pluginId: \"%1\"\n  order: 0\n  Contribution { slot: \"%2\"\n"
                        "    Text { objectName: \"plugin-%1\"; text: \"%3\"; color: \"#9ece6a\" } }\n}\n")
      .arg(id, slot, label.isEmpty() ? QStringLiteral("[%1]").arg(id) : label)
      .toUtf8();
}

QString pluginPath(World& world, const QString& id) {
  return QDir(world.native().controller<PluginController>()->pluginDir()).filePath(id + QStringLiteral(".qml"));
}

void writeFile(const QString& path, const QByteArray& content) {
  QFile file(path);
  expect(file.open(QIODevice::WriteOnly | QIODevice::Truncate), QStringLiteral("cannot write %1").arg(path));
  file.write(content);
}

QVariantMap plugins(World& world) {
  return world.state(QStringLiteral("plugins")).toMap();
}

QVariantMap entry(const QVariantList& list, const QString& id) {
  for (const QVariant& value : list) {
    if (value.toMap().value(QStringLiteral("id")) == id) return value.toMap();
  }
  return {};
}

QVariantMap loaded(World& world, const QString& id) {
  return entry(plugins(world).value(QStringLiteral("items")).toList(), id);
}

QString describe(World& world) {
  QVariantMap state = plugins(world);
  state.remove(QStringLiteral("files"));
  return QStringLiteral("the plugins are %1").arg(show(state));
}

// The desktop's own window, drawn by DefaultShell as the app draws it.
QQuickWindow* shell(World& world) {
  PluginWorld& kept = world.mc.part<PluginWorld>();
  const QString dir = QDir(world.homeDir()).filePath(QStringLiteral("windows"));
  if (!QFile::exists(QDir(dir).filePath(QStringLiteral("shell.qml")))) {
    QDir().mkpath(dir);
    writeFile(QDir(dir).filePath(QStringLiteral("shell.qml")), "import HalC2.Bricks\nDefaultShell { width: 1200; height: 800 }\n");
    // The bricks, from the source tree.
    QFile::link(QStringLiteral(HAL_C2_QML_DIR), QDir(dir).filePath(QStringLiteral("qml")));
  }
  if (world.shellSubscriptions() == 0) {
    // A desktop already set up: a project, so the welcome wizard stays away.
    if (world.mc.projects.isEmpty()) {
      world.mc.projects.insert(QStringLiteral("p1"), {{QStringLiteral("id"), QStringLiteral("p1")}, {QStringLiteral("title"), QStringLiteral("p1")},
                                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/p1")}, {QStringLiteral("scripts"), QJsonArray()}});
    }
    world.connect();
    world.sync();
  }
  // The controllers' singletons (Terminals, Settings…), as main.cpp registers them.
  Brick::registerSingletons();
  world.native().registerQmlSingletons();
  ShellRuntime* runtime = world.showWindows().runtime(world.native().main());
  expect(runtime && runtime->window(), QStringLiteral("the desktop has no window: %1").arg(runtime ? runtime->lastError() : QString()));
  expect(runtime->usingUserShell() && runtime->lastError().isEmpty(), QStringLiteral("the default shell did not load: %1").arg(runtime->lastError()));
  kept.window = runtime->window();
  return kept.window;
}

QQuickItem* find(QQuickItem* item, const QString& objectName) {
  if (item->objectName() == objectName) return item;
  for (QQuickItem* child : item->childItems()) {
    if (QQuickItem* found = find(child, objectName)) return found;
  }
  return nullptr;
}

QQuickItem* item(World& world, const QString& objectName) {
  QQuickItem* found = find(shell(world)->contentItem(), objectName);
  expect(found != nullptr, QStringLiteral("the window has no %1").arg(objectName));
  return found;
}

QString slotObject(const QString& name) {
  static const QHash<QString, QString> objects{{QStringLiteral("sidebar.footer"), QStringLiteral("sidebarFooterSlot")},
                                               {QStringLiteral("composer.actions"), QStringLiteral("composerActionsSlot")},
                                               {QStringLiteral("statusbar"), QStringLiteral("statusbarSlot")}};
  expect(objects.contains(name), QStringLiteral("the desktop has no slot %1").arg(name));
  return objects.value(name);
}

QStringList shownIn(World& world, const QString& slot) {
  QVariant shown = item(world, slotObject(slot))->property("shown");
  if (shown.userType() == qMetaTypeId<QJSValue>()) shown = shown.value<QJSValue>().toVariant();
  return shown.toStringList();
}

bool draws(const QQuickItem* item, const QString& text) {
  if (!item->isVisible()) return false;
  if (item->property("text").toString() == text) return true;
  for (const QQuickItem* child : item->childItems()) {
    if (draws(child, text)) return true;
  }
  return false;
}

bool slotDraws(World& world, const QString& slot, const QString& text) {
  return draws(item(world, slotObject(slot)), text);
}

void waitLoaded(World& world, const QString& id) {
  shell(world);
  world.waitFor([&] { return !loaded(world, id).isEmpty(); }, [&] { return QStringLiteral("%1 to load; %2").arg(id, describe(world)); });
}

void loadPlugin(World& world, const QString& id, const QString& slot) {
  writeFile(pluginPath(world, id), pluginSource(id, slot));
  waitLoaded(world, id);
}

void waitShown(World& world, const QString& slot, const QString& id, const QString& label = {}) {
  const QString text = label.isEmpty() ? QStringLiteral("[%1]").arg(id) : label;
  world.waitFor([&] { return shownIn(world, slot).contains(id) && slotDraws(world, slot, text) && item(world, slotObject(slot))->isVisible(); },
                [&] { return QStringLiteral("%1 to show \"%2\"; it shows %3; %4").arg(slot, text, shownIn(world, slot).join(QStringLiteral(", ")), describe(world)); });
}

void disable(World& world, const QString& id) {
  world.bridge().dispatch(QStringLiteral("plugins.disable"), QVariantMap{{QStringLiteral("id"), id}});
  world.waitFor([&] { return loaded(world, id).isEmpty() && !entry(plugins(world).value(QStringLiteral("disabled")).toList(), id).isEmpty(); },
                [&] { return describe(world); });
}

QVariant question(World& world) {
  return world.state(QStringLiteral("confirmation"));
}

void answer(World& world, bool accepted) {
  expect(question(world).typeId() == QMetaType::QVariantMap, QStringLiteral("no question is asked"));
  world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                          QVariantMap{{QStringLiteral("requestId"), at(question(world), QStringLiteral("requestId"))}, {QStringLiteral("accepted"), accepted}});
}

bool toasted(World& world, const QString& type, const QString& title) {
  for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
    if (toast.toMap().value(QStringLiteral("title")) == title && toast.toMap().value(QStringLiteral("type")) == type) return true;
  }
  return false;
}

// Settings → Plugins, in the window.
QQuickItem* openPluginList(World& world) {
  shell(world);
  world.bridge().dispatch(QStringLiteral("settings.navigate"), QVariantMap{{QStringLiteral("to"), QStringLiteral("/settings/plugins")}});
  QQuickItem* page = nullptr;
  world.waitFor([&] { return (page = find(shell(world)->contentItem(), QStringLiteral("pluginsSettings"))) != nullptr && page->isVisible(); },
                [&] { return QStringLiteral("the plugin list; the window shows %1").arg(show(world.state(QStringLiteral("route")))); });
  return page;
}

void click(World& world, QQuickItem* target) {
  QQuickWindow* window = shell(world);
  window->grabWindow();
  expect(target->isVisible() && target->isEnabled(), QStringLiteral("%1 cannot be clicked").arg(target->objectName()));
  const QPoint at = target->mapToScene(QPointF(target->width() / 2, target->height() / 2)).toPoint();
  QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, at);
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a client whose shell exposes the slots \"sidebar.footer\", \"composer.actions\" and \"statusbar\""), [](World& world, const Captures&, const Table&) {
    for (const QString& name : {QStringLiteral("sidebar.footer"), QStringLiteral("composer.actions"), QStringLiteral("statusbar")}) {
      expect(item(world, slotObject(name))->property("name") == name, QStringLiteral("the shell has no slot %1").arg(name));
    }
    expect(plugins(world).value(QStringLiteral("items")).toList().isEmpty(), describe(world));
  });

  // The same file as the terminal client loads.
  step(QStringLiteral("the plugin %1 contributes to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    writeFile(pluginPath(world, c[0]), pluginSource(c[0], c[1]));
    world.mc.part<PluginWorld>().plugin = c[0];
  });
  step(QStringLiteral("the same plugin file is loaded on the desktop app"), [](World& world, const Captures&, const Table&) {
    waitLoaded(world, world.mc.part<PluginWorld>().plugin);
  });
  step(QStringLiteral("the desktop sidebar footer shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitShown(world, QStringLiteral("sidebar.footer"), c[0]);
    expect(shownIn(world, QStringLiteral("sidebar.footer")) == QStringList{c[0]}, shownIn(world, QStringLiteral("sidebar.footer")).join(QStringLiteral(", ")));
  });
  step(QStringLiteral("the plugin file %1 uses only shared components").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = QString(c[0]).remove(QStringLiteral(".qml"));
    writeFile(pluginPath(world, id), pluginSource(id, QStringLiteral("sidebar.footer")));
    world.mc.part<PluginWorld>().plugin = id;
  });
  // The desktop's part of it; the other surfaces are their runners'.
  step(QStringLiteral("it is loaded on the desktop app, the mobile app and the TUI"), [](World& world, const Captures&, const Table&) {
    waitLoaded(world, world.mc.part<PluginWorld>().plugin);
  });
  step(QStringLiteral("each surface shows %1 in its sidebar footer").arg(q), [](World& world, const Captures& c, const Table&) {
    waitShown(world, QStringLiteral("sidebar.footer"), c[0]);
  });

  step(QStringLiteral("the plugin %1 contributes only to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    writeFile(pluginPath(world, c[0]), pluginSource(c[0], c[1]));
    world.mc.part<PluginWorld>().plugin = c[0];
  });
  step(QStringLiteral("it is loaded on a surface without that slot"), [](World& world, const Captures&, const Table&) {
    waitLoaded(world, world.mc.part<PluginWorld>().plugin);
  });
  step(QStringLiteral("the plugin is listed as loaded with no visible contributions"), [](World& world, const Captures&, const Table&) {
    const QString id = world.mc.part<PluginWorld>().plugin;
    const QVariantMap plugin = loaded(world, id);
    expect(plugin.value(QStringLiteral("slots")).toStringList() == QStringList{QStringLiteral("thread.hovercard")} &&
               plugin.value(QStringLiteral("shown")).toStringList().isEmpty(),
           describe(world));
    for (const QString& slot : {QStringLiteral("sidebar.footer"), QStringLiteral("composer.actions"), QStringLiteral("statusbar")}) {
      expect(shownIn(world, slot).isEmpty() && !slotDraws(world, slot, QStringLiteral("[%1]").arg(id)), QStringLiteral("%1 shows it").arg(slot));
    }
    // And the plugin list says so.
    QQuickItem* page = openPluginList(world);
    QQuickItem* row = nullptr;
    world.waitFor([&] { return (row = find(page, QStringLiteral("plugin:") + id)) != nullptr; }, [&] { return describe(world); });
    const QString detail = find(row, QStringLiteral("pluginDetail"))->property("text").toString();
    expect(detail.startsWith(QLatin1String("Loaded, with nothing shown in this app")), QStringLiteral("the list says \"%1\"").arg(detail));
  });
  step(QStringLiteral("no error is reported"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(plugins(world).value(QStringLiteral("failed")).toList().isEmpty(), describe(world));
    for (const QVariant& toast : at(world.state(QStringLiteral("toasts")), QStringLiteral("items")).toList()) {
      expect(toast.toMap().value(QStringLiteral("type")) != QLatin1String("error"), show(toast));
    }
  });

  // From a pasted address.
  const auto pasteUrl = [](World& world, const QString& url) {
    QQuickItem* page = openPluginList(world);
    QQuickItem* field = find(page, QStringLiteral("pluginUrl"));
    expect(field != nullptr, QStringLiteral("the plugin list has no address field"));
    field->setProperty("text", url);
    click(world, find(page, QStringLiteral("pluginLoad")));
    world.mc.part<PluginWorld>().url = url;
    world.waitFor([&] { return question(world).typeId() == QMetaType::QVariantMap; }, QStringLiteral("the question about the unsigned plugin"));
  };
  const auto serve = [](World& world, const QString& id) {
    world.mc.part<FakePluginSite>().files.insert(id + QStringLiteral(".qml"), pluginSource(id, QStringLiteral("statusbar")));
    world.mc.part<PluginWorld>().plugin = id;
    return world.mc.origin().toString() + QStringLiteral("/plugin-files/") + id + QStringLiteral(".qml");
  };
  step(QStringLiteral("the user pastes the URL of a plugin file and confirms loading it"), [pasteUrl, serve](World& world, const Captures&, const Table&) {
    pasteUrl(world, serve(world, QStringLiteral("team-status")));
    answer(world, true);
  });
  step(QStringLiteral("the plugin is downloaded, checked and loaded"), [](World& world, const Captures&, const Table&) {
    const QString id = world.mc.part<PluginWorld>().plugin;
    world.waitFor([&] { return !loaded(world, id).isEmpty(); }, [&] { return QStringLiteral("%1 to load; %2").arg(id, describe(world)); });
    expect(world.mc.part<FakePluginSite>().requests == QStringList{QStringLiteral("/plugin-files/%1.qml").arg(id)},
           world.mc.part<FakePluginSite>().requests.join(QStringLiteral(", ")));
    QFile kept(pluginPath(world, id));
    expect(kept.open(QIODevice::ReadOnly) && kept.readAll() == pluginSource(id, QStringLiteral("statusbar")), QStringLiteral("%1 is not the file served").arg(kept.fileName()));
    waitShown(world, QStringLiteral("statusbar"), id);
    world.waitFor([&] { return toasted(world, QStringLiteral("success"), QStringLiteral("Plugin \"%1\" loaded.").arg(id)); },
                  [&] { return show(world.state(QStringLiteral("toasts"))); });
  });
  step(QStringLiteral("the plugin is listed with that URL as its source"), [](World& world, const Captures&, const Table&) {
    const PluginWorld& kept = world.mc.part<PluginWorld>();
    expect(loaded(world, kept.plugin).value(QStringLiteral("url")) == kept.url, describe(world));
    QQuickItem* page = openPluginList(world);
    QQuickItem* row = nullptr;
    world.waitFor([&] { return (row = find(page, QStringLiteral("plugin:") + kept.plugin)) != nullptr; }, [&] { return describe(world); });
    const QString detail = find(row, QStringLiteral("pluginDetail"))->property("text").toString();
    expect(detail.endsWith(kept.url), QStringLiteral("the list says \"%1\"").arg(detail));
  });
  step(QStringLiteral("the user pastes a plugin URL that cannot be reached"), [pasteUrl](World& world, const Captures&, const Table&) {
    // Nothing listens there.
    pasteUrl(world, QStringLiteral("http://127.0.0.1:9/gone.qml"));
    answer(world, true);
  });
  step(QStringLiteral("the user is told the plugin could not be downloaded"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return toasted(world, QStringLiteral("error"), QStringLiteral("The plugin could not be downloaded")); },
                  [&] { return show(world.state(QStringLiteral("toasts"))); });
  });
  step(QStringLiteral("nothing is loaded"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(plugins(world).value(QStringLiteral("items")).toList().isEmpty() && !QFile::exists(pluginPath(world, QStringLiteral("gone"))), describe(world));
    expect(shownIn(world, QStringLiteral("statusbar")).isEmpty(), shownIn(world, QStringLiteral("statusbar")).join(QStringLiteral(", ")));
  });
  step(QStringLiteral("the user installs a plugin from a pasted URL"), [serve](World& world, const Captures&, const Table&) {
    shell(world);
    PluginWorld& kept = world.mc.part<PluginWorld>();
    kept.url = serve(world, QStringLiteral("team-status"));
    world.bridge().dispatch(QStringLiteral("plugins.install"), QVariantMap{{QStringLiteral("url"), kept.url}});
  });
  step(QStringLiteral("the user is warned that the plugin is not signed"), [](World& world, const Captures&, const Table&) {
    const QVariantMap asked = question(world).toMap();
    expect(asked.value(QStringLiteral("description")).toString().contains(QLatin1String("not signed")) &&
               asked.value(QStringLiteral("description")).toString().contains(QLatin1String("127.0.0.1")),
           QStringLiteral("the shell asks %1").arg(show(asked)));
  });
  step(QStringLiteral("the plugin loads only after the user confirms"), [](World& world, const Captures&, const Table&) {
    const QString id = world.mc.part<PluginWorld>().plugin;
    world.sync();
    expect(world.mc.part<FakePluginSite>().requests.isEmpty() && loaded(world, id).isEmpty() && !QFile::exists(pluginPath(world, id)),
           QStringLiteral("the plugin was fetched before the answer; %1").arg(describe(world)));
    answer(world, true);
    world.waitFor([&] { return !loaded(world, id).isEmpty(); }, [&] { return QStringLiteral("%1 to load; %2").arg(id, describe(world)); });
    waitShown(world, QStringLiteral("statusbar"), id);
  });

  // Turning one off and on.
  step(QStringLiteral("the plugin %1 is loaded").arg(q), [](World& world, const Captures& c, const Table&) {
    loadPlugin(world, c[0], QStringLiteral("statusbar"));
    waitShown(world, QStringLiteral("statusbar"), c[0]);
  });
  step(QStringLiteral("the user disables %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The plugin list's own switch.
    QQuickItem* page = openPluginList(world);
    QQuickItem* row = nullptr;
    world.waitFor([&] { return (row = find(page, QStringLiteral("plugin:") + c[0])) != nullptr; }, [&] { return describe(world); });
    click(world, find(row, QStringLiteral("pluginToggle")));
    world.sync();
  });
  step(QStringLiteral("\"statusbar\" shows its built-in content"), [](World& world, const Captures&, const Table&) {
    QQuickItem* slot = item(world, QStringLiteral("statusbarSlot"));
    world.waitFor([&] { return shownIn(world, QStringLiteral("statusbar")).isEmpty() && slot->property("builtInVisible").toBool(); },
                  [&] { return QStringLiteral("statusbar shows %1").arg(shownIn(world, QStringLiteral("statusbar")).join(QStringLiteral(", "))); });
    expect(!slotDraws(world, QStringLiteral("statusbar"), QStringLiteral("[clock]")), QStringLiteral("the clock is still drawn"));
  });
  step(QStringLiteral("%1 stays in the installed list as disabled").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !entry(plugins(world).value(QStringLiteral("disabled")).toList(), c[0]).isEmpty() && loaded(world, c[0]).isEmpty(); },
                  [&] { return describe(world); });
    expect(QFile::exists(pluginPath(world, c[0])), QStringLiteral("%1 was deleted").arg(pluginPath(world, c[0])));
    QQuickItem* page = openPluginList(world);
    QQuickItem* row = nullptr;
    world.waitFor([&] { return (row = find(page, QStringLiteral("plugin:") + c[0])) != nullptr &&
                               find(row, QStringLiteral("pluginDetail"))->property("text").toString().startsWith(QLatin1String("Disabled")); },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("the plugin %1 is disabled").arg(q), [](World& world, const Captures& c, const Table&) {
    loadPlugin(world, c[0], QStringLiteral("statusbar"));
    waitShown(world, QStringLiteral("statusbar"), c[0]);
    disable(world, c[0]);
    world.waitFor([&] { return shownIn(world, QStringLiteral("statusbar")).isEmpty(); }, QStringLiteral("the clock to leave the status bar"));
  });
  step(QStringLiteral("the user enables %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* page = openPluginList(world);
    QQuickItem* row = nullptr;
    world.waitFor([&] { return (row = find(page, QStringLiteral("plugin:") + c[0])) != nullptr; }, [&] { return describe(world); });
    click(world, find(row, QStringLiteral("pluginToggle")));
    world.sync();
  });
  step(QStringLiteral("\"statusbar\" shows the clock again"), [](World& world, const Captures&, const Table&) {
    waitShown(world, QStringLiteral("statusbar"), QStringLiteral("clock"));
    expect(plugins(world).value(QStringLiteral("disabled")).toList().isEmpty(), describe(world));
  });
  step(QStringLiteral("the user disabled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    loadPlugin(world, c[0], QStringLiteral("statusbar"));
    disable(world, c[0]);
  });
  step(QStringLiteral("the client restarts"), [](World& world, const Captures&, const Table&) {
    world.restart();
    shell(world);
    world.sync();
  });
  step(QStringLiteral("%1 is still disabled").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !entry(plugins(world).value(QStringLiteral("disabled")).toList(), c[0]).isEmpty(); }, [&] { return describe(world); });
    world.sync();
    expect(loaded(world, c[0]).isEmpty() && shownIn(world, QStringLiteral("statusbar")).isEmpty() &&
               !slotDraws(world, QStringLiteral("statusbar"), QStringLiteral("[%1]").arg(c[0])),
           describe(world));
  });

  // A plugin file saved while the app runs.
  step(QStringLiteral("the client runs in dev mode with the plugin %1 loaded from a file").arg(q), [](World& world, const Captures& c, const Table&) {
    loadPlugin(world, c[0], QStringLiteral("statusbar"));
    waitShown(world, QStringLiteral("statusbar"), c[0]);
    // Something of the shell's to keep: a thread open with words in its draft.
    PluginWorld& kept = world.mc.part<PluginWorld>();
    kept.plugin = c[0];
    kept.draft = show(world.state(QStringLiteral("route")));
  });
  step(QStringLiteral("the developer saves a change to that file"), [](World& world, const Captures&, const Table&) {
    const QString id = world.mc.part<PluginWorld>().plugin;
    writeFile(pluginPath(world, id), pluginSource(id, QStringLiteral("statusbar"), QStringLiteral("[%1 v2]").arg(id)));
  });
  step(QStringLiteral("%1 is replaced by the new version").arg(q), [](World& world, const Captures& c, const Table&) {
    waitShown(world, QStringLiteral("statusbar"), c[0], QStringLiteral("[%1 v2]").arg(c[0]));
    expect(!slotDraws(world, QStringLiteral("statusbar"), QStringLiteral("[%1]").arg(c[0])) && shownIn(world, QStringLiteral("statusbar")) == QStringList{c[0]},
           QStringLiteral("the old version is still drawn"));
    expect(plugins(world).value(QStringLiteral("failed")).toList().isEmpty(), describe(world));
  });
  step(QStringLiteral("the rest of the shell keeps its state"), [](World& world, const Captures&, const Table&) {
    const PluginWorld& kept = world.mc.part<PluginWorld>();
    ShellRuntime* runtime = world.showWindows().runtime(world.native().main());
    expect(runtime->window() == kept.window && show(world.state(QStringLiteral("route"))) == kept.draft && world.native().isActive(),
           QStringLiteral("the window shows %1").arg(show(world.state(QStringLiteral("route")))));
  });
  step(QStringLiteral("the developer saves a version that fails to load"), [](World& world, const Captures&, const Table&) {
    const QString id = world.mc.part<PluginWorld>().plugin;
    writeFile(pluginPath(world, id), "import OpenTUI\nPlugin {\n  pluginId: \"" + id.toUtf8() + "\"\n  Contribution { slot: \"statusbar\"\n    Text { text: \n}\n");
  });
  step(QStringLiteral("a plugin error names %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !entry(plugins(world).value(QStringLiteral("failed")).toList(), c[0]).isEmpty(); }, [&] { return describe(world); });
    const QString message = entry(plugins(world).value(QStringLiteral("failed")).toList(), c[0]).value(QStringLiteral("message")).toString();
    expect(message.contains(QLatin1String("line ")) && message.contains(QLatin1String("the last working version keeps running")), message);
  });
  step(QStringLiteral("the previous version of %1 keeps running").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(!loaded(world, c[0]).isEmpty() && shownIn(world, QStringLiteral("statusbar")) == QStringList{c[0]} &&
               slotDraws(world, QStringLiteral("statusbar"), QStringLiteral("[%1]").arg(c[0])),
           describe(world));
  });

  // What went wrong, where the user looks.
  step(QStringLiteral("the plugin %1 failed to load").arg(q), [](World& world, const Captures& c, const Table&) {
    writeFile(pluginPath(world, c[0]), "import OpenTUI\nText { text: \"not a plugin\" }\n");
    shell(world);
    world.waitFor([&] { return !entry(plugins(world).value(QStringLiteral("failed")).toList(), c[0]).isEmpty(); }, [&] { return describe(world); });
  });
  step(QStringLiteral("the user opens the plugin list"), [](World& world, const Captures&, const Table&) { openPluginList(world); });
  step(QStringLiteral("%1 is shown with its error message").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* page = openPluginList(world);
    QQuickItem* failure = nullptr;
    world.waitFor([&] { return (failure = find(page, QStringLiteral("pluginFailure:") + c[0])) != nullptr && failure->isVisible(); },
                  [&] { return describe(world); });
    const QString text = failure->property("text").toString();
    expect(text == QStringLiteral("%1: the file's root object is not a Plugin").arg(c[0]), QStringLiteral("the list says \"%1\"").arg(text));
    expect(loaded(world, c[0]).isEmpty(), describe(world));
  });
});

}  // namespace
