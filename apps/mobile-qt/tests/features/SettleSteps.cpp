// Settling on the phone (features/threads/settle.feature): from a thread's
// long-press menu on the home screen, what settling clears (a pin, a snooze,
// the questions the agent is waiting on), the thread's own auto-settle
// switch in the same menu, a merged pull request's settle, and the
// environments' auto-settle rules in Settings → General.

#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include <algorithm>

#include "FakeThreads.h"
#include "Harness.h"
#include "NativeShell.h"
#include "Phone.h"
#include "SettingsController.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"
#include "World.h"

namespace {

using S = QString;

const QString kDays = QStringLiteral("sidebarAutoSettleAfterDays");
const QString kOnMerge = QStringLiteral("sidebarAutoSettleOnMerge");
const QString kAt = QStringLiteral("2026-09-23T10:00:00Z");

QString screenTexts(World& world) {
  return world.texts().join(QStringLiteral(" | "));
}

// What the MC does with the commands of settling (orchestration.ex): a
// settled thread leaves its pin, its place and its snooze, and the questions
// the agent asked in the background are dismissed unanswered.
void settleOnMc(FakeMc& mc, const QString& id) {
  QJsonObject& row = mc.threads[id];
  row.insert(S("settledOverride"), S("settled"));
  row.insert(S("settledAt"), kAt);
  for (const char* key : {"pinnedAt", "pinOrderKey", "activeOrderKey", "snoozedUntil", "snoozedAt"}) row.remove(QLatin1String(key));
  const QMap<QString, QJsonObject> entities = mc.part<FakeStreams>().threads.value(id);
  bool dismissed = false;
  for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
    const QJsonObject& request = *it;
    if (!it.key().startsWith(S("runtime-request\n")) || request.value(QLatin1String("status")) != QLatin1String("pending") ||
        request.value(QLatin1String("responseCapability")).toObject().value(QLatin1String("type")) != QLatin1String("message")) {
      continue;
    }
    const QString requestId = request.value(QLatin1String("id")).toString();
    changeEntity(mc, id, S("runtime-request"), requestId, {{S("s"), QJsonObject{{S("status"), S("cancelled")}, {S("resolvedAt"), kAt}}}});
    const QString item = request.value(QLatin1String("nodeId")).toString().mid(5);  // "node:<item>"
    changeEntity(mc, id, S("turn-item"), item,
                 {{S("s"), QJsonObject{{S("status"), S("cancelled")}, {S("completedAt"), kAt}, {S("updatedAt"), kAt}}}});
    dismissed = true;
  }
  if (dismissed) row.remove(S("hasPendingUserInput"));
  mc.sendRow(id, row);
}

// The settle sweep after a quiet spell (orchestration/settlement.ex), for
// the threads whose auto-settle is on.
void sweep(FakeMc& mc) {
  for (auto it = mc.threads.begin(); it != mc.threads.end(); ++it) {
    if (it->contains(QLatin1String("settledOverride")) || it->contains(QLatin1String("autoSettleDisabledAt"))) continue;
    settleOnMc(mc, it.key());
  }
}

const FakeMc::Extension settling([](FakeMc& mc) {
  mc.effects.append([&mc](const QJsonObject& command) {
    const QString type = command.value(QLatin1String("type")).toString();
    const QString id = command.value(QLatin1String("threadId")).toString();
    if (!mc.threads.contains(id)) return;
    if (type == QLatin1String("thread.settle")) {
      settleOnMc(mc, id);
    } else if (type == QLatin1String("thread.auto-settle.set")) {
      QJsonObject& row = mc.threads[id];
      if (command.value(QLatin1String("enabled")).toBool()) {
        row.remove(S("autoSettleDisabledAt"));
      } else if (!row.contains(QLatin1String("autoSettleDisabledAt"))) {
        row.insert(S("autoSettleDisabledAt"), kAt);
      }
      mc.sendRow(id, row);
    }
  });
});

// The section of the home screen's list the thread is in, "" when none.
QString sectionOf(World& world, const QString& title) {
  const QVariantMap state = world.state(S("sidebar")).toMap();
  for (const QString& section : {S("pinned"), S("active"), S("snoozed"), S("settled")}) {
    for (const QVariant& row : state.value(section).toList()) {
      if (row.toMap().value(S("title")) == title) return section;
    }
  }
  return {};
}

QString idOf(World& world, const QString& title) {
  for (auto it = world.mc.threads.cbegin(); it != world.mc.threads.cend(); ++it) {
    if (it->value(QLatin1String("title")).toString() == title) return it.key();
  }
  fail(S("the MC has no thread %1").arg(title));
  return {};
}

int commandsOf(World& world, const QString& type) {
  return int(std::count_if(world.mc.commands.cbegin(), world.mc.commands.cend(),
                           [&](const QJsonObject& command) { return command.value(QLatin1String("type")) == type; }));
}

// The thread's menu, held open from its row on the home screen.
void openMenu(World& world, const QString& title) {
  if (world.find(S("threadScreen")) != nullptr) {
    world.back();
    world.item(S("homeScreen"));
  }
  threadList(world);
  world.hold(threadRow(world, title), [&] { return world.popupShowing(S("mobileMenu")); }, S("the menu of %1").arg(title));
  world.awaitPopup(S("mobileMenu"));
}

void choose(World& world, const QString& id) {
  QQuickItem* item = nullptr;
  world.waitFor([&] { return (item = world.find(S("mobileMenuItem:") + id)) != nullptr; },
                [&] { return S("%1 in the menu; the screen says: %2").arg(id, screenTexts(world)); });
  world.tap(item);
  world.awaitPopup(S("mobileMenu"), false);
}

// The menu item `id`, as the menu shows it: the sheet lists a submenu's
// children under it.
QVariantMap menuItem(World& world, const QString& id) {
  QQuickItem* item = nullptr;
  world.waitFor([&] { return (item = world.find(S("mobileMenuItem:") + id)) != nullptr; },
                [&] { return S("%1 in the menu; the screen says: %2").arg(id, screenTexts(world)); });
  return item->property("modelData").toMap();
}

// The sheet dismissed without a choice, as a tap beside it does.
void closeMenu(World& world) {
  world.bridge().dispatch(S("menu.select"), QVariantMap{{S("requestId"), world.state(S("menu")).toMap().value(S("requestId"))}, {S("id"), QVariant()}});
  world.awaitPopup(S("mobileMenu"), false);
  world.sync();
}

void settle(World& world, const QString& title) {
  const int before = commandsOf(world, S("thread.settle"));
  openMenu(world, title);
  choose(world, S("settle"));
  world.waitFor([&] { return commandsOf(world, S("thread.settle")) > before; }, S("the settle to reach the MC"));
  world.sync();
}

void turnAutoSettle(World& world, const QString& title, bool on) {
  openMenu(world, title);
  // The submenu's choice the thread is on is checked.
  expect(menuItem(world, S("auto-settle:enabled")).value(S("checked")).toBool() != on,
         S("auto-settle is already %1 for %2").arg(on ? S("on") : S("off"), title));
  choose(world, on ? S("auto-settle:enabled") : S("auto-settle:disabled"));
  const QString id = idOf(world, title);
  world.waitFor([&] { return world.mc.threads.value(id).contains(QLatin1String("autoSettleDisabledAt")) != on; },
                S("auto-settle to turn %1 on the MC").arg(on ? S("on") : S("off")));
  world.sync();
}

void expectSection(World& world, const QString& title, const QString& section) {
  world.waitFor([&] { return sectionOf(world, title) == section; },
                [&] { return S("%1 in the %2 section; it is in \"%3\"").arg(title, section, sectionOf(world, title)); });
}

// Settings → General, from the home screen's bar, with the scope on
// `environment` ("" for every environment), ready on `targets` environments.
void openGeneral(World& world, const QString& environment, int targets) {
  if (world.find(S("settingsSections")) == nullptr && world.find(S("settingsRow:") + kDays) == nullptr) {
    world.item(S("homeScreen"));
    world.tap(S("settings"));
    world.item(S("settingsSections"));
  }
  if (world.find(S("settingsRow:") + kDays) == nullptr) {
    QQuickItem* general = nullptr;
    world.waitFor(
        [&] {
          general = world.findWhere([](QQuickItem* candidate) {
            return candidate->objectName().startsWith(QLatin1String("settingsRow")) &&
                   candidate->property("modelData").toMap().value(S("to")).toString() == QLatin1String("/settings/general");
          });
          return general != nullptr;
        },
        [&] { return S("General among the settings; the screen says: %1").arg(screenTexts(world)); });
    world.tap(general);
  }
  const auto scope = [&] { return world.state(S("settingsScope")).toMap(); };
  QString id;
  if (!environment.isEmpty()) {
    world.waitFor(
        [&] {
          for (const QVariant& row : scope().value(S("environments")).toList()) {
            if (row.toMap().value(S("label")) == environment) id = row.toMap().value(S("id")).toString();
          }
          return !id.isEmpty();
        },
        [&] { return S("%1 to be offered; the scope is %2").arg(environment, show(scope())); });
  }
  // As the scope sentence's environment box does.
  world.bridge().dispatch(S("settingsScope.environment"), QVariantMap{{S("id"), id}});
  auto* controller = world.native().controller<SettingsScopeController>();
  world.waitFor(
      [&] {
        const int known = controller->read([](const QJsonObject& settings, const QString&) { return QJsonValue(settings); }).known;
        return scope().value(S("editable")).toBool() && controller->targets().size() == targets && known == targets;
      },
      [&] { return S("the rules of %1 environments; the scope is %2").arg(targets).arg(show(scope())); });
}

// The settings row `key`, scrolled to as the user would.
QQuickItem* settingsRow(World& world, const QString& key) {
  // The page is taller than the phone: scrolled down until the row is there.
  QQuickItem* row = nullptr;
  world.waitFor(
      [&] {
        if ((row = world.find(S("settingsRow:") + key)) != nullptr) return true;
        QQuickItem* first = world.find(S("settingsRow:sidebarShowSettledPluginThreads"));
        QQuickItem* flick = first;
        while (flick && !flick->inherits("QQuickFlickable")) flick = flick->parentItem();
        if (flick) {
          const double end = std::max(0.0, flick->property("contentHeight").toDouble() - flick->height());
          flick->setProperty("contentY", std::min(end, flick->property("contentY").toDouble() + flick->height() / 2));
        }
        return false;
      },
      [&] { return S("%1 among the general settings; the screen says: %2").arg(key, screenTexts(world)); });
  QQuickItem* page = row->parentItem();
  while (page && !page->inherits("QQuickFlickable")) page = page->parentItem();
  expect(page != nullptr, S("the general settings do not scroll"));
  QQuickItem* content = page->property("contentItem").value<QQuickItem*>();
  page->setProperty("contentY", std::max(0.0, row->mapToItem(content, QPointF(0, 0)).y() - page->height() / 2));
  return row;
}

QQuickItem* childNamed(QQuickItem* row, const QString& name) {
  for (QQuickItem* child : row->findChildren<QQuickItem*>()) {
    if (child->objectName() == name && child->isVisible()) return child;
  }
  return nullptr;
}

// Another machine of the cluster, settling after three days and not on merge.
void addEnvironment(World& world, const QString& name) {
  if (world.mc.members.contains(name)) return;
  settingsOf(world.mc, name) = {{{kDays, 3}, {kOnMerge, false}}, 0, {{S("threadAutoSettlement"), true}}};
  world.mc.join(name);
}

QJsonObject documentFor(World& world, const QString& environment) {
  return environment.isEmpty() ? ownSettings(world.mc) : settingsOf(world.mc, environment).settings;
}

// The rule a step changed, for the outcome to look for.
struct ChangedRule {
  QString key;
  QJsonValue value;
};

const Steps steps([] {
  const QString q = kQuoted;

  // The thread, idle, in an environment whose rules settle threads after
  // three days and not on merge, and which lets a thread turn them off.
  step(S("a connected environment with the idle thread %1 in the project %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.mc.projects.contains(c[1]), S("the MC has no project %1").arg(c[1]));
    world.mc.threads.clear();
    world.mc.capabilities.insert(S("threadAutoSettlement"), true);
    world.mc.capabilities.insert(S("threadAutoSettleOptOut"), true);
    saveOwnSetting(world.mc, kDays, 3);
    saveOwnSetting(world.mc, kOnMerge, false);
    world.thread = haveThread(world, c[0]);
    world.mc.threads[world.thread].insert(S("projectId"), c[1]);
    pairWithEnvironment(world);
    threadRow(world, c[0]);
  });

  step(S("%1 is pinned").arg(q), [](World& world, const Captures& c, const Table&) {
    updateRow(world.mc, idOf(world, c[0]), {{S("pinnedAt"), S("2026-09-23T09:30:00Z")}, {S("pinOrderKey"), S("a0")}});
    expectSection(world, c[0], S("pinned"));
  });
  step(S("%1 is snoozed until tomorrow").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString until = QDateTime::currentDateTimeUtc().addDays(1).toString(Qt::ISODate);
    updateRow(world.mc, idOf(world, c[0]), {{S("snoozedUntil"), until}, {S("snoozedAt"), S("2026-09-23T09:30:00Z")}});
    expectSection(world, c[0], S("snoozed"));
  });
  step(S("%1 has auto-settle turned off").arg(q), [](World& world, const Captures& c, const Table&) {
    updateRow(world.mc, idOf(world, c[0]), {{S("autoSettleDisabledAt"), S("2026-09-20T09:00:00Z")}});
    world.sync();
  });

  // A question waiting on the user while the turn waits, seen once and left.
  step(S("the agent in %1 asked a question in the background").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOf(world, c[0]);
    FakeStreams& fake = world.mc.part<FakeStreams>();
    world.run = S("run-%1").arg(fake.ordinal + 1);
    setEntity(world.mc, id, S("run"), world.run,
              {{S("id"), world.run}, {S("ordinal"), ++fake.ordinal}, {S("status"), S("running")},
               {S("requestedAt"), S("2026-09-23T09:50:00Z")}, {S("startedAt"), S("2026-09-23T09:50:00Z")}});
    const QString item = S("question-1");
    setEntity(world.mc, id, S("turn-item"), item,
              {{S("id"), item}, {S("type"), S("user_input_request")}, {S("runId"), world.run}, {S("ordinal"), ++fake.ordinal},
               {S("status"), S("running")}, {S("requestId"), S("request-1")}, {S("updatedAt"), S("2026-09-23T09:55:00Z")},
               {S("questions"), QJsonArray{QJsonObject{{S("id"), S("q1")}, {S("header"), S("Database")}, {S("question"), S("Which database?")}}}}});
    setEntity(world.mc, id, S("runtime-request"), S("request-1"),
              {{S("id"), S("request-1")}, {S("status"), S("pending")}, {S("nodeId"), S("node:") + item},
               {S("responseCapability"), QJsonObject{{S("type"), S("message")}}}});
    updateRow(world.mc, id, {{S("activeRunId"), world.run}, {S("latestRunId"), world.run}, {S("hasPendingUserInput"), true}});
    openThread(world, c[0]);
    world.waitFor([&] { return !world.state(S("turn")).toMap().value(S("questions")).toList().isEmpty(); },
                  [&] { return S("the question to be asked; the screen says: %1").arg(screenTexts(world)); });
    world.back();
    world.item(S("homeScreen"));
  });

  step(S("the user settles %1").arg(q), [](World& world, const Captures& c, const Table&) { settle(world, c[0]); });

  step(S("%1 is settled and no longer (pinned|snoozed)").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSection(world, c[0], S("settled"));
    const QJsonObject row = world.mc.threads.value(idOf(world, c[0]));
    expect(!row.contains(c[1] == QLatin1String("pinned") ? S("pinnedAt") : S("snoozedUntil")), S("the MC still has %1 %2").arg(c[0], c[1]));
  });
  step(S("%1 moves to the settled section").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSection(world, c[0], S("settled"));
  });

  // The question is gone from the thread, and the thread waits on nobody.
  step(S("the question is dismissed"), [](World& world, const Captures&, const Table&) {
    expectSection(world, world.mc.threads.value(world.thread).value(QLatin1String("title")).toString(), S("settled"));
    openThread(world, world.mc.threads.value(world.thread).value(QLatin1String("title")).toString());
    world.waitFor([&] { return world.state(S("turn")).toMap().value(S("questions")).toList().isEmpty(); },
                  [&] { return S("the question to go; the composer has %1").arg(show(world.state(S("turn")).toMap().value(S("questions")))); });
    world.sync();
    expect(!world.shows(S("Which database?"), false), S("the thread still asks; the screen says: %1").arg(screenTexts(world)));
  });

  // A pull request the MC settles the thread for when it merges.
  step(S("%1 is linked to a pull request").arg(q), [](World& world, const Captures& c, const Table&) {
    updateRow(world.mc, idOf(world, c[0]),
              {{S("linkedPullRequest"), QJsonObject{{S("number"), 42}, {S("state"), S("open")}, {S("url"), S("https://github.com/shop/shop/pull/42")}}}});
    expectSection(world, c[0], S("active"));
  });
  step(S("the pull request is merged on GitHub"), [](World& world, const Captures&, const Table&) {
    QJsonObject pr = world.mc.threads.value(world.thread).value(QLatin1String("linkedPullRequest")).toObject();
    pr.insert(S("state"), S("merged"));
    updateRow(world.mc, world.thread, {{S("linkedPullRequest"), pr}, {S("settledOverride"), S("settled")}, {S("settledAt"), kAt}});
  });
  step(S("%1 is shown as settled on the phone").arg(q), [](World& world, const Captures& c, const Table&) {
    expectSection(world, c[0], S("settled"));
    // The home screen lists it under Settled, not among the active threads.
    threadList(world);
    QQuickItem* row = threadRow(world, c[0]);
    expect(row->property("item").toMap().value(S("settled")).toBool() ||
               sectionOf(world, c[0]) == QLatin1String("settled"),
           S("the row of %1 does not say it is settled").arg(c[0]));
    expect(commandsOf(world, S("thread.settle")) == 0, S("the phone settled %1 itself").arg(c[0]));
  });

  // The thread's own auto-settle, from its menu.
  step(S("the user turns auto-settle (off|on) for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    turnAutoSettle(world, c[1], c[0] == QLatin1String("on"));
  });
  step(S("%1 stays out of automatic settling").arg(q), [](World& world, const Captures& c, const Table&) {
    openMenu(world, c[0]);
    expect(menuItem(world, S("auto-settle:disabled")).value(S("checked")).toBool(), S("the menu does not show auto-settle off"));
    closeMenu(world);
    sweep(world.mc);
    world.sync();
    expect(sectionOf(world, c[0]) == QLatin1String("active"), S("%1 is in the %2 section").arg(c[0], sectionOf(world, c[0])));
  });
  step(S("%1 settles automatically again after a quiet spell").arg(q), [](World& world, const Captures& c, const Table&) {
    openMenu(world, c[0]);
    expect(menuItem(world, S("auto-settle:enabled")).value(S("checked")).toBool(), S("the menu does not show auto-settle on"));
    closeMenu(world);
    sweep(world.mc);
    expectSection(world, c[0], S("settled"));
  });

  // The environments' rules, in Settings → General.
  step(S("the user sets auto-settle to (after 7 days|never on inactivity|when the PR merges) for (the environment \"home\"|all environments)"),
       [](World& world, const Captures& c, const Table&) {
         for (const QString& name : {S("home"), S("work")}) addEnvironment(world, name);
         const bool all = c[1] == QLatin1String("all environments");
         openGeneral(world, all ? QString() : S("home"), all ? 3 : 1);
         if (c[0] == QLatin1String("after 7 days")) {
           QQuickItem* days = childNamed(settingsRow(world, kDays), S("days"));
           expect(days != nullptr, S("the quiet spell has no number of days"));
           days->setProperty("value", 7);
           QMetaObject::invokeMethod(days, "valueModified");
           world.mc.part<ChangedRule>() = {kDays, 7};
         } else if (c[0] == QLatin1String("never on inactivity")) {
           QQuickItem* control = childNamed(settingsRow(world, kDays), S("control"));
           expect(control != nullptr && control->property("checked").toBool(), S("the quiet spell is not on"));
           world.tap(control);
           world.mc.part<ChangedRule>() = {kDays, QJsonValue(QJsonValue::Null)};
         } else {
           QQuickItem* control = childNamed(settingsRow(world, kOnMerge), S("control"));
           expect(control != nullptr && !control->property("checked").toBool(), S("settling on merge is already on"));
           world.tap(control);
           world.mc.part<ChangedRule>() = {kOnMerge, true};
         }
         world.sync();
       });
  step(S("threads on (\"home\" only|every environment) follow the new rule"), [](World& world, const Captures& c, const Table&) {
    const ChangedRule changed = world.mc.part<ChangedRule>();
    const auto has = [&](const QString& environment) {
      const QJsonObject document = documentFor(world, environment);
      return document.contains(changed.key) && document.value(changed.key) == changed.value;
    };
    world.waitFor([&] { return has(S("home")); }, [&] {
      return S("home to take the rule; it has %1, the phone shows %2").arg(show(documentFor(world, S("home")).toVariantMap()), show(world.state(S("toasts"))));
    });
    world.sync();
    const bool everywhere = c[0] == QLatin1String("every environment");
    expect(has(S("work")) == everywhere && has(QString()) == everywhere,
           S("work has %1, this machine %2").arg(show(documentFor(world, S("work")).toVariantMap()), show(documentFor(world, QString()).toVariantMap())));
  });

  step(S("%1 settles after (\\d+) days and %1 settles after (\\d+) days").arg(q), [](World& world, const Captures& c, const Table&) {
    addEnvironment(world, c[0]);
    addEnvironment(world, c[2]);
    settingsOf(world.mc, c[0]).settings.insert(kDays, c[1].toInt());
    settingsOf(world.mc, c[2]).settings.insert(kDays, c[3].toInt());
  });
  step(S("the user looks at the auto-settle rules for all environments"), [](World& world, const Captures&, const Table&) { openGeneral(world, {}, 3); });
  step(S("the quiet spell is shown as mixed"), [](World& world, const Captures&, const Table&) {
    QQuickItem* row = settingsRow(world, kDays);
    world.waitFor([&] { return childNamed(row, S("mixed")) != nullptr; }, [&] { return S("\"Mixed\" by the quiet spell; the screen says: %1").arg(screenTexts(world)); });
    QQuickItem* onMerge = settingsRow(world, kOnMerge);
    expect(childNamed(onMerge, S("mixed")) == nullptr, S("settling on merge is shown as mixed too"));
  });

  step(S("the environment %1 is offline").arg(q), [](World& world, const Captures& c, const Table&) {
    settingsOf(world.mc, c[0]).capabilities = {{S("threadAutoSettlement"), true}};
    world.mc.offline.insert(c[0]);
    world.mc.join(c[0]);
  });
  step(S("the user changes the auto-settle rules for all environments"), [](World& world, const Captures&, const Table&) {
    addEnvironment(world, S("home"));
    // "work" is out of reach: this machine and "home" take the change.
    openGeneral(world, {}, 2);
    QQuickItem* days = childNamed(settingsRow(world, kDays), S("days"));
    expect(days != nullptr, S("the quiet spell has no number of days"));
    days->setProperty("value", 7);
    QMetaObject::invokeMethod(days, "valueModified");
    world.sync();
  });
  step(S("%1 keeps its previous rules").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return documentFor(world, S("home")).value(kDays) == QJsonValue(7); }, S("home to take the rule"));
    world.sync();
    expect(!settingsOf(world.mc, c[0]).settings.contains(kDays), S("%1 has %2").arg(c[0], show(settingsOf(world.mc, c[0]).settings.toVariantMap())));
  });
  step(S("the user can see %1 was not updated").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString title = S("Not updated: ") + c[0];
    world.waitFor([&] { return world.shows(title, false); }, [&] { return S("%1 on screen; the screen says: %2").arg(title, screenTexts(world)); });
    const QStringList unreachable = world.native().controller<SettingsController>()->unreachable();
    expect(unreachable == QStringList{c[0]}, S("the rules are out of reach on %1").arg(unreachable.join(S(", "))));
  });
});

}  // namespace
