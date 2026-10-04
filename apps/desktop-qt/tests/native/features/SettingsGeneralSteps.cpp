// Settings → General as the desktop draws it (qml/HalC2/Bricks/GeneralSettings.qml),
// and what each of its rows changes elsewhere in the shell: the sidebar's
// grouping and clock, how a diff opens, proactive panels, the composer's keys,
// the questions asked before a thread goes, and the quit shortcut
// (features/settings/general.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QLocale>
#include <QQuickItem>
#include <QTest>

#include "Brick.h"
#include "ComposerController.h"
#include "DiffModel.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "Panel.h"
#include "Quit.h"
#include "QuitController.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "SettingsRows.h"
#include "SidebarController.h"
#include "Stream.h"
#include "ThreadDiff.h"
#include "ThreadList.h"
#include "Turn.h"
#include "World.h"

namespace {

using namespace stream;

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

// What the scenario is in the middle of.
struct General {
  QString prompt;  // "single line" or "multiline"
  QString thread;  // the thread the scenario acts on, by key
  QString action;  // unpins, archives or deletes
  int diffCalls = 0;
};

General& general(World& world) {
  return world.mc.part<General>();
}

// The titles the scenarios use for rows, by the row's key.
const QHash<QString, QString>& rowKeys() {
  static const QHash<QString, QString> keys{
      {QStringLiteral("Hide whitespace changes"), QStringLiteral("diffIgnoreWhitespace")},
      {QStringLiteral("Default diff file state"), QStringLiteral("diffFilesCollapsed")},
      {QStringLiteral("Diff layout"), QStringLiteral("diffLayout")},
      {QStringLiteral("Confirm thread unpinning"), QStringLiteral("confirmThreadUnpin")},
      {QStringLiteral("Confirm thread archiving"), QStringLiteral("confirmThreadArchive")},
      {QStringLiteral("Confirm thread deletion"), QStringLiteral("confirmThreadDelete")},
  };
  return keys;
}

QVariantList sidebarProjects(World& world) {
  return at(world.state(QStringLiteral("sidebar")), QStringLiteral("projects")).toList();
}

QString describeProjects(World& world) {
  return QStringLiteral("the sidebar's projects are %1").arg(show(sidebarProjects(world)));
}

QJsonObject projectRow(const QString& id) {
  return {{QStringLiteral("id"), id},
          {QStringLiteral("title"), id},
          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + id},
          {QStringLiteral("scripts"), QJsonArray()},
          {QStringLiteral("repositoryIdentity"),
           QJsonObject{{QStringLiteral("canonicalKey"), QStringLiteral("github.com/acme/") + id}, {QStringLiteral("name"), id}}}};
}

// A thread of "shop" the scenario opens: its row as given, then its stream.
void openThreadWith(World& world, const QString& id, const QJsonObject& fields) {
  world.mc.projects.insert(kProject, projectRow(kProject));
  world.mc.sendRow(kProject, world.mc.projects.value(kProject), QStringLiteral("project"));
  QJsonObject row{{QStringLiteral("id"), id}, {QStringLiteral("title"), QStringLiteral("Tax line")}, {QStringLiteral("projectId"), kProject},
                  {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  world.mc.threads.insert(id, row);
  world.mc.sendRow(id, row);
  world.sync();
  FakeStreams& fake = world.mc.part<FakeStreams>();
  fake.thread = id;
  fake.environment = world.mc.environmentId;
  look(world, world.mc.environmentId + QLatin1Char(':') + id);
}

QVariantMap panelState(World& world) {
  return world.state(QStringLiteral("panel")).toMap();
}

QString describePanel(World& world) {
  return QStringLiteral("the panel is %1").arg(show(panelState(world)));
}

ThreadDiff& diff(World& world) {
  return *world.native().controller<RightPanelController>()->diff();
}

QString describeDiff(World& world) {
  DiffModel& model = *diff(world).model();
  QStringList files;
  for (int file = 0; file < model.fileCount(); ++file) {
    files.append(QStringLiteral("%1 (%2)").arg(model.path(file), model.expanded(file) ? QStringLiteral("expanded") : QStringLiteral("collapsed")));
  }
  return QStringLiteral("the diff is %1, %2, whitespace %3: %4")
      .arg(diff(world).status(), model.split() ? QStringLiteral("split") : QStringLiteral("stacked"),
           diff(world).ignoreWhitespace() ? QStringLiteral("hidden") : QStringLiteral("shown"), files.join(QStringLiteral(", ")));
}

QString patchOf(const QString& path) {
  return QStringLiteral("diff --git a/%1 b/%1\n--- a/%1\n+++ b/%1\n@@ -1,2 +1,2 @@\n-export const rate = 1;\n+export const rate = 2;\n export const done = true;\n").arg(path);
}

// The thread's latest turn changed two files; its diff is opened from the panel.
void openDiff(World& world) {
  openTurnThread(world);
  finishTurnWithPatch(world, 1, patchOf(QStringLiteral("src/rates.ts")) + patchOf(QStringLiteral("src/cart.ts")));
  world.bridge().dispatch(QStringLiteral("panel.open"), QVariantMap{{QStringLiteral("tab"), QStringLiteral("diff")}, {QStringLiteral("turn"), -1}});
  world.waitFor([&] { return diff(world).status() == QLatin1String("ready"); }, [&] { return describeDiff(world); });
}

QList<QJsonObject> commandsOf(World& world, const QString& type) {
  QList<QJsonObject> found;
  for (const QJsonObject& command : world.mc.commands) {
    if (command.value(QLatin1String("type")).toString() == type) found.append(command);
  }
  return found;
}

QVariantMap composer(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

QVariantMap question(World& world) {
  world.sync();
  return world.state(QStringLiteral("confirmation")).toMap();
}

const QString kThreadCommand = QStringLiteral("thread.%1");

QString commandOf(const QString& action) {
  return kThreadCommand.arg(action == QLatin1String("unpins") ? QStringLiteral("unpin")
                            : action == QLatin1String("archives") ? QStringLiteral("archive")
                                                                  : QStringLiteral("delete"));
}

const Steps steps([] {
  const QString q = kQuoted;

  // Project grouping.
  step(QStringLiteral("project grouping combines matching repositories across environments"), [](World& world, const Captures&, const Table&) {
    // The same repository checked out on this machine and on a linked one.
    world.mc.projects.insert(kProject, projectRow(kProject));
    world.mc.sendRow(kProject, world.mc.projects.value(kProject), QStringLiteral("project"));
    world.mc.join(kPeerEnvironment);
    world.mc.sendPeerRow(kPeerEnvironment, kProject, projectRow(kProject), QStringLiteral("project"));
    world.waitFor([&] {
      const QVariantList projects = sidebarProjects(world);
      return projects.size() == 1 && settingOn(world, QStringLiteral("sidebarProjectGroupingMode"));
    }, [&] { return describeProjects(world); });
  });
  step(QStringLiteral("the user turns project grouping off"), [](World& world, const Captures&, const Table&) {
    turnRow(world, QStringLiteral("sidebarProjectGroupingMode"), false);
  });
  step(QStringLiteral("the sidebar lists each environment's copy of a repository as its own project"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QVariantList projects = sidebarProjects(world);
      return projects.size() == 2 && at(projects.at(0), QStringLiteral("environmentId")) != at(projects.at(1), QStringLiteral("environmentId"));
    }, [&] { return describeProjects(world); });
  });
  step(QStringLiteral("the user had grouped projects by repository and then turned grouping off"), [](World& world, const Captures&, const Table&) {
    expect(settings(world)->setting(QStringLiteral("sidebarProjectGroupingMode")) == QLatin1String("repository"),
           QStringLiteral("projects are not grouped by repository"));
    turnRow(world, QStringLiteral("sidebarProjectGroupingMode"), false);
    expect(settings(world)->setting(QStringLiteral("sidebarProjectGroupingMode")) == QLatin1String("separate"),
           QStringLiteral("grouping is %1").arg(show(settings(world)->setting(QStringLiteral("sidebarProjectGroupingMode")))));
  });
  step(QStringLiteral("the user turns project grouping on again"), [](World& world, const Captures&, const Table&) {
    turnRow(world, QStringLiteral("sidebarProjectGroupingMode"), true);
  });
  step(QStringLiteral("projects are grouped by repository again"), [](World& world, const Captures&, const Table&) {
    expect(settings(world)->setting(QStringLiteral("sidebarProjectGroupingMode")) == QLatin1String("repository"),
           QStringLiteral("grouping is %1").arg(show(settings(world)->setting(QStringLiteral("sidebarProjectGroupingMode")))));
  });

  // The time format, as the sidebar's snooze times read (10:00 now; this evening is 18:00).
  step(QStringLiteral("the user sets the time format to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    chooseRow(world, QStringLiteral("timestampFormat"), c[0]);
  });
  step(QStringLiteral("timestamps are shown (the way the system clock is configured|with AM and PM|on a 24-hour clock)"),
       [](World& world, const Captures& c, const Table&) {
         QString evening;
         for (const sidebar::SnoozePreset& preset : world.native().sidebar()->snoozePresets()) {
           if (preset.id == QLatin1String("evening")) evening = preset.whenLabel;
         }
         const QString wanted = c[0].startsWith(QLatin1String("the way"))
                                    ? QLocale(QLocale::English, QLocale::UnitedStates).toString(QTime(18, 0), QLocale::ShortFormat)
                                    : c[0].startsWith(QLatin1String("with AM")) ? QStringLiteral("6:00 PM")
                                                                                 : QStringLiteral("18:00");
         expect(evening == wanted, QStringLiteral("this evening reads \"%1\", not \"%2\"").arg(evening, wanted));
       });

  // Diffs.
  step(QStringLiteral("the user sets \"(Hide whitespace changes|Default diff file state|Diff layout)\" to %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         const QString key = rowKeys().value(c[0]);
         if (c[1] == QLatin1String("on") || c[1] == QLatin1String("off")) return turnRow(world, key, c[1] == QLatin1String("on"));
         chooseRow(world, key, c[1]);
       });
  step(QStringLiteral("the user opens a diff"), [](World& world, const Captures&, const Table&) { openDiff(world); });
  step(QStringLiteral("the diff opens (without whitespace-only edits|with every file collapsed|with every file expanded|side by side|stacked)"),
       [](World& world, const Captures& c, const Table&) {
         DiffModel& model = *diff(world).model();
         expect(model.fileCount() == 2, describeDiff(world));
         if (c[0].startsWith(QLatin1String("without"))) {
           // The MC leaves them out of the patch when asked to.
           QJsonObject asked;
           for (const FakeMc::Rpc& rpc : world.mc.calls) {
             if (rpc.method == QLatin1String("orchestration.getTurnDiff")) asked = rpc.payload;
           }
           expect(diff(world).ignoreWhitespace() && asked.value(QLatin1String("ignoreWhitespace")).toBool(),
                  QStringLiteral("%1; the MC was asked %2").arg(describeDiff(world), show(asked.toVariantMap())));
         } else if (c[0].endsWith(QLatin1String("collapsed"))) {
           expect(!model.expanded(0) && !model.expanded(1), describeDiff(world));
         } else if (c[0].endsWith(QLatin1String("expanded"))) {
           expect(model.allExpanded(), describeDiff(world));
         } else {
           expect(model.split() == (c[0] == QLatin1String("side by side")), describeDiff(world));
         }
       });
  step(QStringLiteral("the diff layout setting is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    chooseRow(world, QStringLiteral("diffLayout"), c[0]);
  });
  step(QStringLiteral("the user switches an open diff to side by side"), [](World& world, const Captures&, const Table&) {
    openDiff(world);
    expect(!diff(world).model()->split(), describeDiff(world));
    // As the diff's toolbar does (DiffPanel.qml).
    diff(world).model()->setProperty("split", true);
  });
  step(QStringLiteral("the diff layout setting reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString shown = rowText(world, QStringLiteral("diffLayout"));
    expect(shown == c[0], QStringLiteral("the row reads \"%1\"").arg(shown));
  });

  // Proactive panels.
  step(QStringLiteral("proactive panels are (on|off)"), [](World& world, const Captures& c, const Table&) {
    turnRow(world, QStringLiteral("proactivePanelsEnabled"), c[0] == QLatin1String("on"));
  });
  step(QStringLiteral("the user opens a thread with a linked pull request"), [](World& world, const Captures&, const Table&) {
    const QJsonArray links{QJsonObject{{QStringLiteral("host"), QStringLiteral("github.com")}, {QStringLiteral("repository"), QStringLiteral("acme/shop")},
                                       {QStringLiteral("number"), 7}, {QStringLiteral("url"), QStringLiteral("https://github.com/acme/shop/pull/7")},
                                       {QStringLiteral("source"), QStringLiteral("agent")}, {QStringLiteral("snapshot"), QJsonValue()}}};
    openThreadWith(world, QStringLiteral("thread-pr"), {{QStringLiteral("pullRequests"), links}});
    world.sync();
  });
  step(QStringLiteral("the user opens a thread whose working tree changed at least 3 files"), [](World& world, const Captures&, const Table&) {
    openThreadWith(world, QStringLiteral("thread-diff"), {});
    QJsonArray files;
    QString patch;
    for (const char* path : {"src/rates.ts", "src/cart.ts", "src/tax.ts"}) {
      files.append(QJsonObject{{QStringLiteral("path"), QLatin1String(path)}, {QStringLiteral("additions"), 1}, {QStringLiteral("deletions"), 1}});
      patch += patchOf(QLatin1String(path));
    }
    finishTurnWithPatch(world, 1, patch, files);
    world.sync();
  });
  step(QStringLiteral("the pull request panel opens with the thread"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QVariantMap panel = panelState(world);
      return panel.value(QStringLiteral("isOpen")).toBool() && panel.value(QStringLiteral("activeId")).toString().contains(QLatin1String("pull-request"));
    }, [&] { return describePanel(world); });
  });
  step(QStringLiteral("the working tree diff opens with the thread"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] {
      const QVariantMap panel = panelState(world);
      return panel.value(QStringLiteral("isOpen")).toBool() && panel.value(QStringLiteral("activeId")) == QLatin1String("diff") &&
             diff(world).status() == QLatin1String("ready");
    }, [&] { return QStringLiteral("%1; %2").arg(describePanel(world), describeDiff(world)); });
    expect(diff(world).model()->fileCount() == 3, describeDiff(world));
  });
  step(QStringLiteral("no side panel opens by itself"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const QVariantMap panel = panelState(world);
    expect(panel.value(QStringLiteral("threadKey")).toString().endsWith(QLatin1String(":thread-pr")) && panel.contains(QStringLiteral("isOpen")) &&
               !panel.value(QStringLiteral("isOpen")).toBool() && panel.value(QStringLiteral("tabs")).toList().isEmpty(),
           describePanel(world));
  });

  // The send shortcut. The page words the modifier as this platform's key.
  step(QStringLiteral("the send shortcut is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    chooseRow(world, QStringLiteral("sendShortcut"), QString(c[0]).replace(QLatin1String("Modifier and Enter"), QLatin1String("Ctrl + Enter")));
  });
  step(QStringLiteral("the user presses Enter in a (single line|multiline) prompt"), [](World& world, const Captures& c, const Table&) {
    openTurnThread(world);
    General& state = general(world);
    state.prompt = c[0] == QLatin1String("multiline") ? QStringLiteral("first line\nsecond line") : QStringLiteral("one line");
    const QString target = world.native().controller<NavigationController>()->threadKey();
    world.bridge().dispatch(QStringLiteral("composer.text.set"),
                            QVariantMap{{QStringLiteral("target"), target}, {QStringLiteral("text"), state.prompt}, {QStringLiteral("cursor"), state.prompt.size()}});
    // What the composer does with a bare Enter (Composer.qml enterIntent): send
    // as the table says, else leave the key to the editor.
    const QString table = c[0] == QLatin1String("multiline") ? QStringLiteral("multiline") : QStringLiteral("singleLine");
    const QVariantMap intents = at(composer(world), QStringLiteral("enterIntents.") + table).toMap();
    const QString intent = intents.value(QString()).toString();
    if (intent.isEmpty()) {
      state.prompt += QLatin1Char('\n');
      world.bridge().dispatch(QStringLiteral("composer.text.set"),
                              QVariantMap{{QStringLiteral("target"), target}, {QStringLiteral("text"), state.prompt}, {QStringLiteral("cursor"), state.prompt.size()}});
    } else {
      world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), state.prompt}, {QStringLiteral("intent"), intent}});
    }
    world.sync();
  });
  step(QStringLiteral("the prompt (is sent|gets a new line)"), [](World& world, const Captures& c, const Table&) {
    const General& state = general(world);
    const QList<QJsonObject> sent = commandsOf(world, QStringLiteral("message.dispatch"));
    if (c[0] == QLatin1String("is sent")) {
      expect(sent.size() == 1 && sent.first().value(QLatin1String("text")) == state.prompt, QStringLiteral("the MC has %1").arg(world.describeCommands()));
      return;
    }
    const QString kept = world.native().controller<ComposerController>()->draft(world.native().controller<NavigationController>()->threadKey());
    expect(sent.isEmpty() && kept == state.prompt && kept.endsWith(QLatin1Char('\n')),
           QStringLiteral("the prompt reads %1; the MC has %2").arg(show(kept), world.describeCommands()));
  });

  // Follow-ups.
  step(QStringLiteral("the follow-up behaviour is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    chooseRow(world, QStringLiteral("followUpBehavior"), c[0]);
  });
  step(QStringLiteral("the user sends a message while the agent is running"), [](World& world, const Captures&, const Table&) {
    startWorkingTurn(world);
    world.bridge().dispatch(QStringLiteral("composer.submit"),
                            QVariantMap{{QStringLiteral("text"), QStringLiteral("also update the docs")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    world.sync();
  });
  step(QStringLiteral("the message (waits until the run ends|is sent into the current run)"), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject> sent = commandsOf(world, QStringLiteral("message.dispatch"));
    expect(sent.size() == 1 && sent.first().value(QLatin1String("text")) == QLatin1String("also update the docs"),
           QStringLiteral("the MC has %1").arg(world.describeCommands()));
    const QJsonObject message = sent.first();
    const QString mode = message.value(QLatin1String("dispatchMode")).toObject().value(QLatin1String("type")).toString();
    const bool steers = message.value(QLatin1String("deliveryIntent")) == QLatin1String("steer") && mode == QLatin1String("start_immediately");
    const bool queues = !message.contains(QLatin1String("deliveryIntent")) && mode == QLatin1String("queue_after_active");
    expect(c[0].startsWith(QLatin1String("waits")) ? queues : steers, QStringLiteral("the MC was sent %1").arg(show(message.toVariantMap())));
  });

  // Confirmations.
  step(QStringLiteral("\"(Confirm thread unpinning|Confirm thread archiving|Confirm thread deletion)\" is (on|off)"),
       [](World& world, const Captures& c, const Table&) { turnRow(world, rowKeys().value(c[0]), c[1] == QLatin1String("on")); });
  step(QStringLiteral("the user (unpins|archives|deletes) a thread"), [](World& world, const Captures& c, const Table&) {
    projectThreadCommands(world);
    openTurnThread(world);
    General& state = general(world);
    state.action = c[0];
    state.thread = world.mc.environmentId + QLatin1Char(':') + kThread;
    if (c[0] == QLatin1String("unpins")) {
      updateThreadRow(world, kThread, [](QJsonObject& row) {
        row.insert(QStringLiteral("pinnedAt"), QStringLiteral("2026-09-23T09:30:00Z"));
        row.insert(QStringLiteral("pinOrderKey"), QStringLiteral("a0"));
      });
      world.waitFor([&] { return sidebarSectionOf(world, state.thread) == QLatin1String("pinned"); }, QStringLiteral("the thread to be pinned"));
    }
    // From the thread's menu, as the sidebar offers it.
    world.bridge().dispatch(QStringLiteral("thread.menu"), QVariantMap{{QStringLiteral("key"), state.thread}, {QStringLiteral("x"), 40}, {QStringLiteral("y"), 120}});
    const QVariant menu = world.state(QStringLiteral("menu"));
    expect(menu.typeId() == QMetaType::QVariantMap, QStringLiteral("no menu opened for the thread"));
    world.bridge().dispatch(QStringLiteral("menu.select"),
                            QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))},
                                        {QStringLiteral("id"), c[0] == QLatin1String("unpins") ? QStringLiteral("unpin")
                                                               : c[0] == QLatin1String("archives") ? QStringLiteral("archive")
                                                                                                   : QStringLiteral("delete")}});
    world.sync();
  });
  step(QStringLiteral("the user is asked before the (?:thread is unpinned|history is deleted)"), [](World& world, const Captures&, const Table&) {
    const General& state = general(world);
    const QVariantMap asked = question(world);
    const QString title = state.action == QLatin1String("unpins") ? QStringLiteral("Unpin thread \"Tax line\"?") : QStringLiteral("Delete thread \"Tax line\"?");
    expect(asked.value(QStringLiteral("title")) == title && commandsOf(world, commandOf(state.action)).isEmpty(),
           QStringLiteral("the question is %1; the MC has %2").arg(show(asked), world.describeCommands()));
    if (state.action == QLatin1String("deletes")) {
      expect(asked.value(QStringLiteral("description")).toString().contains(QLatin1String("clears conversation history")),
             QStringLiteral("the question is %1").arg(show(asked)));
    }
  });
  step(QStringLiteral("the archive action must be chosen a second time"), [](World& world, const Captures&, const Table&) {
    // The menu's Archive only asks; the question's own Archive archives.
    const QVariantMap asked = question(world);
    expect(asked.value(QStringLiteral("confirmLabel")) == QLatin1String("Archive") && commandsOf(world, QStringLiteral("thread.archive")).isEmpty(),
           QStringLiteral("the question is %1; the MC has %2").arg(show(asked), world.describeCommands()));
    world.bridge().dispatch(QStringLiteral("confirmation.answer"),
                            QVariantMap{{QStringLiteral("requestId"), asked.value(QStringLiteral("requestId"))}, {QStringLiteral("accepted"), true}});
    world.waitFor([&] { return commandsOf(world, QStringLiteral("thread.archive")).size() == 1; },
                  [&] { return QStringLiteral("the thread to be archived; the MC has %1").arg(world.describeCommands()); });
  });
  step(QStringLiteral("the thread is (?:unpinned|archived|deleted) straight away"), [](World& world, const Captures&, const Table&) {
    const General& state = general(world);
    expect(question(world).isEmpty(), QStringLiteral("the user was asked %1").arg(show(question(world))));
    world.waitFor([&] { return commandsOf(world, commandOf(state.action)).size() == 1; },
                  [&] { return QStringLiteral("%1; the MC has %2").arg(commandOf(state.action), world.describeCommands()); });
  });

  // The quit shortcut.
  step(QStringLiteral("the quit shortcut behaviour is \"(direct|hold|double-click)\""), [](World& world, const Captures& c, const Table&) {
    const QString label = c[0] == QLatin1String("direct") ? QStringLiteral("Direct")
                          : c[0] == QLatin1String("hold") ? QStringLiteral("Hold")
                                                          : QStringLiteral("Double press");
    chooseRow(world, QStringLiteral("confirmQuit"), label);
    expect(settings(world)->setting(QStringLiteral("confirmQuit")) == c[0],
           QStringLiteral("the quit shortcut is %1").arg(show(settings(world)->setting(QStringLiteral("confirmQuit")))));
    expect(quitRequests(world) == 0, QStringLiteral("the app was asked to quit"));
  });
  step(QStringLiteral("the user presses the quit shortcut"), [](World& world, const Captures&, const Table&) { pressQuitShortcut(world, 80); });
  step(QStringLiteral("the app quits at once"), [](World& world, const Captures&, const Table&) {
    expect(quitRequests(world) == 1, QStringLiteral("the app was asked to quit %1 times").arg(quitRequests(world)));
  });
  step(QStringLiteral("the app quits only after the shortcut is held"), [](World& world, const Captures&, const Table&) {
    expect(quitRequests(world) == 0, QStringLiteral("a quick press quit the app"));
    // Long after the quick press, so this is not a second press of two.
    advanceQuitClock(world, 5000);
    pressQuitShortcut(world, QuitController::kHoldMs + 40);
    expect(quitRequests(world) == 1, QStringLiteral("holding asked the app to quit %1 times").arg(quitRequests(world)));
  });
  step(QStringLiteral("the app quits only after the shortcut is pressed twice"), [](World& world, const Captures&, const Table&) {
    expect(quitRequests(world) == 0, QStringLiteral("one press quit the app"));
    advanceQuitClock(world, 220);
    pressQuitShortcut(world, 80);
    expect(quitRequests(world) == 1, QStringLiteral("the second press asked the app to quit %1 times").arg(quitRequests(world)));
  });
  step(QStringLiteral("the user presses the quit shortcut twice quickly"), [](World& world, const Captures&, const Table&) {
    pressQuitShortcut(world, 80, false);
    advanceQuitClock(world, 220);
    pressQuitShortcut(world, 80);
  });

  // Legacy features.
  step(QStringLiteral("the legacy features section is folded"), [](World& world, const Captures&, const Table&) {
    for (const char* key : {"planModeEnabled", "contextWindowMeterEnabled", "legacySidebarEnabled"}) {
      expect(!rowShown(world, QLatin1String(key)), QStringLiteral("%1 is shown").arg(QLatin1String(key)));
    }
    expect(generalPage(world).shows(QStringLiteral("Legacy features")), QStringLiteral("the page has no legacy features section"));
  });
  step(QStringLiteral("the user unfolds it"), [](World& world, const Captures&, const Table&) {
    Brick& page = generalPage(world);
    QQuickItem* fold = pageItem(world, QStringLiteral("settingsSection:Legacy features"), QStringLiteral("fold"));
    QTest::mouseClick(&page.window(), Qt::LeftButton, Qt::NoModifier, page.at(fold));
  });
  step(QStringLiteral("the legacy plan mode, context window indicator and per-project sidebar can be turned on"), [](World& world, const Captures&, const Table&) {
    for (const char* key : {"planModeEnabled", "contextWindowMeterEnabled", "legacySidebarEnabled"}) {
      expect(rowShown(world, QLatin1String(key)) && !settingOn(world, QLatin1String(key)), QStringLiteral("%1 is not offered").arg(QLatin1String(key)));
      turnRow(world, QLatin1String(key), true);
    }
  });
});

}  // namespace
