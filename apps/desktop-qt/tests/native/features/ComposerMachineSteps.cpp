// The machine a thread runs on, as the composer's context strip shows and
// offers it (WorkspaceController::environmentChoices, Composer.qml's
// hostPicker), with the workspace and branch beside it
// (features/composer/model-and-mode.feature). Where a balanced thread starts
// is the MC's to say (LoadBalancingSteps.cpp fakes `hal-c2.placeThread`).

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>
#include <QUrl>

#include "Brick.h"
#include "CommandPaletteController.h"
#include "ComposerBrick.h"
#include "ComposerController.h"
#include "EnvironmentCatalog.h"
#include "FakeConfig.h"
#include "FakeGit.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "Launch.h"
#include "LoadBalancing.h"
#include "NavigationController.h"
#include "SavedEnvironmentsController.h"
#include "SettingsController.h"
#include "Stream.h"
#include "World.h"
#include "WorkspaceController.h"

using namespace stream;

namespace {

const QString kRoot = QStringLiteral("/work/shop");
const QString kOther = QStringLiteral("server");
const QString kPrompt = QStringLiteral("Add tax to the cart");
const QString kWorktree = QStringLiteral("/work/shop-worktrees/tax-line");
const QString kBranch = QStringLiteral("hal-c2/tax-line");
const QString kThreadId = QStringLiteral("t-machine");

// What the scenario said of the machines.
struct Machines {
  // The machine a name scenario looks at.
  QString looked;
  // The project is a plain folder: its checkout says it is no repository.
  bool plainFolder = false;
};

Machines& machines(World& world) {
  return world.mc.part<Machines>();
}

QVariantMap workspace(World& world) {
  return world.state(QStringLiteral("workspace")).toMap();
}

QVariantList environments(World& world) {
  return workspace(world).value(QStringLiteral("environments")).toList();
}

QQuickItem* part(World& world, const QString& objectName) {
  QQuickItem* item = composerPart(world, objectName);
  expect(item != nullptr, QStringLiteral("the composer shows no %1").arg(objectName));
  return item;
}

QQuickItem* hostPicker(World& world) {
  return part(world, QStringLiteral("hostPicker"));
}

// The cluster of the MC's own machine, named `own`, and `other`, both with a
// checkout of "shop".
void twoMachines(World& world, const QString& own, const QString& other) {
  world.mc.label = own;
  world.mc.announceEnvironment();
  world.mc.peerLabels.insert(other, other);
  world.mc.join(QStringLiteral("mc-") + other, other);
  shareProject(world.mc, kProject);
  world.mc.sendRow(kProject, world.mc.projects.value(kProject), QStringLiteral("project"));
  world.sync();
}

// The plain folder's checkout answers that it is no repository.
void sayPlainFolder(World& world) {
  world.waitFor([&] {
    for (const int id : world.mc.subscribers(QStringLiteral("vcs"))) {
      if (world.mc.shapeOf(id).value(QLatin1String("cwd")) == kRoot) return true;
    }
    return false;
  }, QStringLiteral("the shell to follow the folder's checkout"));
  for (const int id : world.mc.subscribers(QStringLiteral("vcs"))) {
    if (world.mc.shapeOf(id).value(QLatin1String("cwd")) != kRoot) continue;
    world.mc.send({{QStringLiteral("t"), QStringLiteral("vcs")},
                   {QStringLiteral("id"), id},
                   {QStringLiteral("event"), QJsonObject{{QStringLiteral("_tag"), QStringLiteral("localUpdated")},
                                                          {QStringLiteral("local"), QJsonObject{{QStringLiteral("isRepo"), false}}}}}});
  }
  world.sync();
}

// The window on a new thread's draft in "shop", the composer on screen.
void newThread(World& world) {
  if (world.native().controller<NavigationController>()->route().kind != QLatin1String("draft")) {
    world.openDraft(kProject);
    world.waitFor([&] { return workspace(world).value(QStringLiteral("isDraft")).toBool(); },
                  [&] { return QStringLiteral("the draft; the header shows %1").arg(show(workspace(world))); });
  }
  if (machines(world).plainFolder) sayPlainFolder(world);
  composerBrick(world);
  world.sync();
}

// The entry of the machine choice the user calls `label`.
int choiceOf(World& world, const QString& label) {
  const QVariantList offered = environments(world);
  for (qsizetype i = 0; i < offered.size(); ++i) {
    if (offered.at(i).toMap().value(QStringLiteral("label")) == label) return int(i);
  }
  fail(QStringLiteral("the composer offers %1").arg(show(offered)));
  return -1;
}

// Opens the machine choice and takes its entry `index` with the keyboard.
void pickMachine(World& world, int index) {
  Brick& brick = composerBrick(world);
  QQuickItem* picker = hostPicker(world);
  QObject* popup = picker->property("popup").value<QObject*>();
  world.waitFor([&] { return !popup->property("visible").toBool(); }, QStringLiteral("the machine choice to be closed"));
  expect(picker->isVisible() && picker->isEnabled(), QStringLiteral("the machine choice cannot be opened; the header shows %1").arg(show(workspace(world))));
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(picker));
  world.waitFor([&] { return popup->property("opened").toBool(); }, QStringLiteral("the machine choice to open"));
  for (int guard = 0; picker->property("highlightedIndex").toInt() != index && guard < 8; ++guard) {
    QTest::keyClick(&brick.window(), picker->property("highlightedIndex").toInt() < index ? Qt::Key_Down : Qt::Key_Up);
  }
  expect(picker->property("highlightedIndex").toInt() == index, QStringLiteral("the machine choice offers no entry %1").arg(index));
  QTest::keyClick(&brick.window(), Qt::Key_Return);
  world.sync();
}

// The project on two machines, balancing on, and a new thread's draft open.
void balancedDraft(World& world) {
  twoMachines(world, QStringLiteral("laptop"), kOther);
  saveElsewhere(world.mc, QStringLiteral("loadBalancingEnabled"), true);
  world.waitFor([&] { return world.native().controller<SettingsController>()->settings().value(QStringLiteral("loadBalancingEnabled")).toBool(); },
                QStringLiteral("the shell to read that balancing is on"));
  // The MC gives the other machine more room.
  world.mc.part<FakePlacement>().elsewhere = kOther;
  newThread(world);
}

void chooseAutoBalance(World& world) {
  pickMachine(world, choiceOf(world, QStringLiteral("Auto balance")));
  world.waitFor([&] { return hostPicker(world)->property("displayText") == QLatin1String("Auto balance"); },
                [&] { return QStringLiteral("Auto balance; the picker reads \"%1\"").arg(hostPicker(world)->property("displayText").toString()); });
}

void sendFirstMessage(World& world) {
  world.bridge().dispatch(QStringLiteral("composer.submit"),
                          QVariantMap{{QStringLiteral("text"), kPrompt}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
}

// A started thread of "shop" on the MC's own machine.
void haveThread(World& world, const QJsonObject& more) {
  QJsonObject row{{QStringLiteral("id"), kThreadId}, {QStringLiteral("title"), QStringLiteral("Tax line")}, {QStringLiteral("projectId"), kProject},
                  {QStringLiteral("latestUserMessageAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                  {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}};
  for (auto it = more.begin(); it != more.end(); ++it) row.insert(it.key(), it.value());
  world.mc.threads.insert(kThreadId, row);
  world.mc.sendRow(kThreadId, row);
  world.sync();
}

// The window on that thread, its context strip kept on screen.
void lookAtThread(World& world) {
  // A started thread's strip stays only with the setting that keeps it.
  world.native().controller<SettingsController>()->set(QStringLiteral("persistComposerContextStrip"), true);
  const QString key = world.mc.environmentId + QLatin1Char(':') + kThreadId;
  if (world.native().controller<NavigationController>()->threadKey() != key) {
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  }
  world.waitFor([&] { return workspace(world).value(QStringLiteral("threadKey")) == key; },
                [&] { return QStringLiteral("the thread; the header shows %1").arg(show(workspace(world))); });
  composerBrick(world);
  world.sync();
}

QString lockedLabel(World& world) {
  return part(world, QStringLiteral("envModeLockedLabel"))->property("text").toString();
}

// The three controls are on screen side by side, none over another.
void separateControls(World& world) {
  const QList<QQuickItem*> controls{hostPicker(world), part(world, QStringLiteral("envModePicker")), part(world, QStringLiteral("branchButton"))};
  world.waitFor([&] {
    return std::all_of(controls.begin(), controls.end(), [](QQuickItem* item) { return item->isVisible() && item->width() > 0; });
  }, [&] {
    return QStringLiteral("the machine, workspace and branch; shown %1 %2 %3, the header shows %4")
        .arg(controls[0]->isVisible()).arg(controls[1]->isVisible()).arg(controls[2]->isVisible()).arg(show(workspace(world)));
  });
  for (qsizetype i = 0; i < controls.size(); ++i) {
    const QRectF a = controls[i]->mapRectToScene(QRectF(0, 0, controls[i]->width(), controls[i]->height()));
    for (qsizetype j = i + 1; j < controls.size(); ++j) {
      const QRectF b = controls[j]->mapRectToScene(QRectF(0, 0, controls[j]->width(), controls[j]->height()));
      expect(!a.intersects(b), QStringLiteral("%1 and %2 overlap").arg(controls[i]->objectName(), controls[j]->objectName()));
    }
  }
}

const Steps steps([] {
  const QString q = kQuoted;

  // The controls side by side (upstream #27114).
  step(QStringLiteral("the project can run on more than one machine"), [](World& world, const Captures&, const Table&) {
    twoMachines(world, QStringLiteral("laptop"), kOther);
    fakeGitRepo(world, kRoot, {QStringLiteral("main")}, QStringLiteral("main"), QStringLiteral("main"));
  });
  step(QStringLiteral("the user starts a new thread at the default chat width"), [](World& world, const Captures&, const Table&) {
    newThread(world);
  });
  step(QStringLiteral("the composer shows the machine, whether it works locally or in a new worktree, and the branch as separate controls"),
       [](World& world, const Captures&, const Table&) { separateControls(world); });
  // The desktop's strip has no folded control: a narrow window keeps the three.
  step(QStringLiteral("only a phone-width composer folds the machine and workspace into one control"), [](World& world, const Captures&, const Table&) {
    composerItem(world)->setWidth(520);
    world.sync();
    separateControls(world);
  });

  // A plain folder (upstream #21404).
  step(QStringLiteral("the project is a plain folder with no Git repository"), [](World& world, const Captures&, const Table&) {
    machines(world).plainFolder = true;
  });
  step(QStringLiteral("the last thread was started in a new worktree, or a saved draft asked for one"), [](World& world, const Captures&, const Table&) {
    saveElsewhere(world.mc, QStringLiteral("defaultThreadEnvMode"), QStringLiteral("worktree"));
    world.sync();
  });
  // "the user starts a new thread in the project" is TurnSteps'.
  step(QStringLiteral("the thread works in the project's folder"), [](World& world, const Captures&, const Table&) {
    newThread(world);
    // The draft asked for a new worktree, which a folder cannot have.
    expect(world.native().controller<WorkspaceController>()->checkout(world.draftId).envMode == QLatin1String("worktree"),
           QStringLiteral("the draft did not ask for a new worktree; the header shows %1").arg(show(workspace(world))));
    world.waitFor([&] { return workspace(world).value(QStringLiteral("envMode")) == QLatin1String("local") && lockedLabel(world) == QLatin1String("Local checkout"); },
                  [&] { return QStringLiteral("the folder; the label reads \"%1\", the header shows %2").arg(lockedLabel(world), show(workspace(world))); });
    const auto where = world.native().controller<WorkspaceController>()->launch(world.draftId);
    expect(where.problem.isEmpty() && where.strategy == QJsonObject{{QStringLiteral("type"), QStringLiteral("root")}},
           QStringLiteral("the thread would start in %1 (%2)").arg(show(where.strategy.toVariantMap()), where.problem));
  });
  step(QStringLiteral("no branch or worktree can be chosen"), [](World& world, const Captures&, const Table&) {
    expect(!part(world, QStringLiteral("envModePicker"))->isVisible() && part(world, QStringLiteral("envModeLocked"))->isVisible() &&
               !part(world, QStringLiteral("branchButton"))->isVisible() && !workspace(world).value(QStringLiteral("envModeChangeable")).toBool() &&
               !workspace(world).value(QStringLiteral("branchChangeable")).toBool(),
           QStringLiteral("the header shows %1").arg(show(workspace(world))));
    // Asking anyway changes nothing.
    world.bridge().dispatch(QStringLiteral("workspace.envMode.set"), QVariantMap{{QStringLiteral("mode"), QStringLiteral("worktree")}});
    world.sync();
    expect(workspace(world).value(QStringLiteral("envMode")) == QLatin1String("local"), QStringLiteral("the header shows %1").arg(show(workspace(world))));
  });

  // A worktree being checked out (upstream #13590).
  step(QStringLiteral("the user started a thread in a new worktree"), [](World& world, const Captures&, const Table&) {
    fakeGitRepo(world, kRoot, {QStringLiteral("main")}, QStringLiteral("main"), QStringLiteral("main"));
    fakeGitRepo(world, kWorktree, {QStringLiteral("main"), kBranch}, kBranch, QStringLiteral("main"));
    haveThread(world, {});
  });
  step(QStringLiteral("the worktree is still being checked out"), [](World& world, const Captures&, const Table&) {
    // The MC holds the run "preparing" until the worktree is there.
    haveThread(world, {{QStringLiteral("status"), QStringLiteral("preparing")}, {QStringLiteral("activeRunId"), QStringLiteral("run-1")}});
    lookAtThread(world);
  });
  step(QStringLiteral("the checkout finishes"), [](World& world, const Captures&, const Table&) {
    haveThread(world, {{QStringLiteral("status"), QStringLiteral("running")}, {QStringLiteral("activeRunId"), QStringLiteral("run-1")},
                       {QStringLiteral("branch"), kBranch}, {QStringLiteral("worktreePath"), kWorktree}});
  });
  step(QStringLiteral("the workspace label reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return part(world, QStringLiteral("envModeLocked"))->isVisible() && lockedLabel(world) == c[0]; },
                  [&] { return QStringLiteral("\"%1\"; the label reads \"%2\", the header shows %3").arg(c[0], lockedLabel(world), show(workspace(world))); });
  });

  // One project for every checkout of a repository (upstream #22242).
  step(QStringLiteral("%1 has checkouts on %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == kProject, QStringLiteral("the open thread's project is %1").arg(kProject));
    twoMachines(world, c[1], c[2]);
  });
  step(QStringLiteral("the user opens the project picker for a new thread"), [](World& world, const Captures&, const Table&) {
    expect(world.native().controller<KeybindingController>()->commands()->run(QStringLiteral("thread.newIn")), QStringLiteral("New thread in... is not a command"));
    world.sync();
  });
  step(QStringLiteral("%1 is listed once").arg(q), [](World& world, const Captures& c, const Table&) {
    auto* palette = world.native().controller<CommandPaletteController>();
    world.waitFor([&] { return palette->isOpen() && palette->submenu() == QLatin1String("New thread in...") && !palette->searching(); },
                  QStringLiteral("the palette's New thread in..."));
    QStringList titles;
    for (int row = 0; row < palette->rowCount(); ++row) titles.append(palette->index(row).data(CommandPaletteController::TitleRole).toString());
    expect(titles.count(c[0]) == 1, QStringLiteral("the palette lists %1").arg(titles.join(u", ")));
    expect(palette->run(int(titles.indexOf(c[0]))), QStringLiteral("%1 cannot be chosen").arg(c[0]));
    world.waitFor([&] { return workspace(world).value(QStringLiteral("isDraft")).toBool() && workspace(world).value(QStringLiteral("projectTitle")) == c[0]; },
                  [&] { return QStringLiteral("a draft in %1; the header shows %2").arg(c[0], show(workspace(world))); });
  });
  step(QStringLiteral("both machines are offered under it"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    world.sync();
    QStringList labels;
    for (const QVariant& choice : environments(world)) labels.append(choice.toMap().value(QStringLiteral("label")).toString());
    expect(labels == QStringList{QStringLiteral("laptop"), kOther} && hostPicker(world)->isVisible() && hostPicker(world)->isEnabled(),
           QStringLiteral("the machine choice offers %1 (shown %2)").arg(labels.join(u", ")).arg(hostPicker(world)->isVisible()));
  });

  // Auto balance.
  step(QStringLiteral("the project exists on two connected machines and load balancing is on"), [](World& world, const Captures&, const Table&) {
    balancedDraft(world);
  });
  step(QStringLiteral("the user (?:chose \"Auto balance\" for a new thread|chooses \"Auto balance\" as the machine a new thread runs on)"), [](World& world, const Captures&, const Table&) {
    balancedDraft(world);
    chooseAutoBalance(world);
  });
  step(QStringLiteral("the thread starts on the machine with the most room when the first message is sent"), [](World& world, const Captures&, const Table&) {
    sendFirstMessage(world);
    const FakeLaunches& launches = world.mc.part<FakeLaunches>();
    world.waitFor([&] { return !launches.calls.isEmpty(); }, QStringLiteral("a launch; the MC got none"));
    const FakePlacement& placement = world.mc.part<FakePlacement>();
    expect(placement.asked.size() == 1 && launches.calls.size() == 1 && launches.machines.constLast() == kOther,
           QStringLiteral("the MC was asked %1 times and the thread launched on %2").arg(placement.asked.size()).arg(launches.machines.join(u", ")));
  });
  step(QStringLiteral("the user chooses the machine %1 instead").arg(q), [](World& world, const Captures& c, const Table&) {
    pickMachine(world, choiceOf(world, c[0]));
    world.waitFor([&] { return hostPicker(world)->property("displayText") == c[0]; },
                  [&] { return QStringLiteral("%1; the picker reads \"%2\"").arg(c[0], hostPicker(world)->property("displayText").toString()); });
    // A machine the user picks is where the thread starts: the MC is not asked.
    world.mc.part<FakePlacement>().tied = true;
  });
  step(QStringLiteral("the draft of a new thread has an attached file"), [](World& world, const Captures&, const Table&) {
    balancedDraft(world);
    const QDir dir(world.homeDir() + QStringLiteral("/documents"));
    expect(dir.mkpath(QStringLiteral(".")), QStringLiteral("could not make %1").arg(dir.path()));
    QFile file(dir.filePath(QStringLiteral("schema.sql")));
    expect(file.open(QIODevice::WriteOnly) && file.write("create table carts (id integer);\n") > 0, QStringLiteral("could not write schema.sql"));
    file.close();
    QMetaObject::invokeMethod(composerItem(world), "attach", Q_ARG(QVariant, QVariant(QVariantList{QUrl::fromLocalFile(file.fileName())})));
    world.waitFor([&] { return world.native().controller<ComposerController>()->holdsFiles(world.draftId); },
                  [&] { return QStringLiteral("the file attached; the composer shows %1").arg(show(world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("attachments")))); });
    world.waitFor([&] { return hostPicker(world)->property("displayText") == QLatin1String("laptop"); },
                  [&] { return QStringLiteral("the draft held on its machine; the picker reads \"%1\"").arg(hostPicker(world)->property("displayText").toString()); });
  });
  step(QStringLiteral("the user is told %1 and to remove them first").arg(q), [](World& world, const Captures& c, const Table&) {
    const auto told = [&] {
      for (const QVariant& toast : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
        if (toast.toMap().value(QStringLiteral("title")) == c[0] &&
            toast.toMap().value(QStringLiteral("description")).toString().startsWith(QLatin1String("Remove attachments before choosing automatic routing"))) {
          return true;
        }
      }
      return false;
    };
    world.waitFor(told, [&] { return QStringLiteral("the notice; the toasts are %1").arg(show(world.state(QStringLiteral("toasts")))); });
  });
  step(QStringLiteral("the thread still runs on the machine it was on"), [](World& world, const Captures&, const Table&) {
    world.sync();
    const auto where = world.native().controller<WorkspaceController>()->launch(world.draftId);
    expect(hostPicker(world)->property("displayText") == QLatin1String("laptop") && where.environmentId == world.mc.environmentId,
           QStringLiteral("the picker reads \"%1\" and the thread would start on %2").arg(hostPicker(world)->property("displayText").toString(), where.environmentId));
  });

  // The machine's name.
  step(QStringLiteral("the machine is (the one being used|another one) and its own name is \"([^\"]*)\" and the user named it \"([^\"]*)\""),
       [](World& world, const Captures& c, const Table&) {
         const bool own = c[0] == QLatin1String("the one being used");
         twoMachines(world, own ? c[1] : QStringLiteral("laptop"), kOther);
         const QString id = own ? world.mc.environmentId : kOther;
         if (!own) {
           world.mc.peerLabels.insert(kOther, c[1]);
           world.mc.join(QStringLiteral("mc-") + kOther, kOther);
           world.sync();
         }
         machines(world).looked = id;
         if (c[2].isEmpty()) return;
         SavedEnvironment saved{id, c[2], QUrl(QStringLiteral("http://127.0.0.1:9")), {}};
         if (const auto refused = world.native().controller<SavedEnvironmentsController>()->catalog()->save(saved, QStringLiteral("token"))) fail(*refused);
       });
  step(QStringLiteral("the user opens the choice of machine for a new thread"), [](World& world, const Captures&, const Table&) {
    newThread(world);
    QQuickItem* picker = hostPicker(world);
    Brick& brick = composerBrick(world);
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(picker));
    QObject* popup = picker->property("popup").value<QObject*>();
    world.waitFor([&] { return popup->property("opened").toBool(); }, QStringLiteral("the machine choice to open"));
  });
  step(QStringLiteral("the machine reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantList offered = environments(world);
    QQuickItem* picker = hostPicker(world);
    for (qsizetype i = 0; i < offered.size(); ++i) {
      if (offered.at(i).toMap().value(QStringLiteral("environmentId")) != machines(world).looked) continue;
      QString label;
      QMetaObject::invokeMethod(picker, "textAt", Q_RETURN_ARG(QString, label), Q_ARG(int, int(i)));
      expect(label == c[0], QStringLiteral("the machine reads \"%1\"").arg(label));
      return;
    }
    fail(QStringLiteral("the machine choice offers %1").arg(show(offered)));
  });

  // Whether the machine is shown, and whether it can change (upstream #19900).
  step(QStringLiteral("the project runs on a remote machine %1 and no other machine is connected").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.label = c[0];
    world.servedFrom(QStringLiteral("machine-") + c[0]);
  });
  step(QStringLiteral("the project runs on the machine being used and no other machine is connected"), [](World& world, const Captures&, const Table&) {
    world.mc.label = QStringLiteral("laptop");
    world.mc.announceEnvironment();
    world.sync();
  });
  step(QStringLiteral("the user looks at a new thread's composer"), [](World& world, const Captures&, const Table&) { newThread(world); });
  step(QStringLiteral("a thread has started on the machine %1 in a project on several machines").arg(q), [](World& world, const Captures& c, const Table&) {
    twoMachines(world, c[0], QStringLiteral("laptop"));
    haveThread(world, {});
  });
  step(QStringLiteral("the user looks at the thread's composer"), [](World& world, const Captures&, const Table&) { lookAtThread(world); });
  step(QStringLiteral("the machine %1 is shown").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return hostPicker(world)->isVisible() && hostPicker(world)->property("displayText") == c[0]; },
                  [&] { return QStringLiteral("%1; shown %2, the picker reads \"%3\", the header shows %4")
                                   .arg(c[0]).arg(hostPicker(world)->isVisible()).arg(hostPicker(world)->property("displayText").toString(), show(workspace(world))); });
  });
  step(QStringLiteral("it cannot be changed"), [](World& world, const Captures&, const Table&) {
    expect(!hostPicker(world)->isEnabled() && !workspace(world).value(QStringLiteral("environmentChangeable")).toBool() && environments(world).size() == 1,
           QStringLiteral("the machine choice offers %1").arg(show(environments(world))));
  });
  step(QStringLiteral("no other machine is offered, by the menu or by the machine shortcut"), [](World& world, const Captures&, const Table&) {
    expect(!hostPicker(world)->isEnabled() && environments(world).size() == 1,
           QStringLiteral("the machine choice offers %1").arg(show(environments(world))));
    expect(world.native().controller<KeybindingController>()->commands()->run(QStringLiteral("composer.host")), QStringLiteral("composer.host is not a command"));
    world.sync();
    QObject* popup = hostPicker(world)->property("popup").value<QObject*>();
    expect(!popup->property("visible").toBool(), QStringLiteral("the machine shortcut opened the machine choice"));
  });
  step(QStringLiteral("no machine is shown"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!hostPicker(world)->isVisible() && !workspace(world).value(QStringLiteral("environmentShown")).toBool(),
           QStringLiteral("the header shows %1").arg(show(workspace(world))));
  });
});

}  // namespace
