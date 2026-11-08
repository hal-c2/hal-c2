// Where the phone's composer names a thread's permissions: on the toolbar only
// when they differ from the default, in a new thread's context strip, and in
// the model control's footer (features/composer/model-and-mode.feature). The
// composer is the desktop's brick; these are its steps with a finger.

#include <algorithm>

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "FakeThreads.h"
#include "Harness.h"
#include "NativeShell.h"
#include "Phone.h"
#include "SettingsController.h"
#include "World.h"

namespace {

using S = QString;

QVariantMap composer(World& world) {
  return world.state(S("composer")).toMap();
}

// The composer's part `name`, on screen or not.
QQuickItem* part(World& world, const QString& name) {
  const std::function<QQuickItem*(QQuickItem*)> within = [&](QQuickItem* item) -> QQuickItem* {
    if (item->objectName() == name) return item;
    for (QQuickItem* child : item->childItems())
      if (QQuickItem* found = within(child)) return found;
    return nullptr;
  };
  QQuickItem* found = nullptr;
  world.waitFor([&] { return (found = within(world.item(S("composer")))) != nullptr; }, [&] { return S("the composer to hold %1").arg(name); });
  return found;
}

bool shown(World& world, const QString& name) {
  return part(world, name)->isVisible();
}

QObject* popupOf(QQuickItem* control) {
  QObject* popup = control->property("popup").value<QObject*>();
  expect(popup != nullptr, S("%1 has no popup").arg(control->objectName()));
  return popup;
}

// The permissions by the names the composer gives them.
QString modeOf(const QString& label) {
  static const QHash<QString, QString> modes{{S("Supervised"), S("approval-required")},
                                             {S("Auto-accept edits"), S("auto-accept-edits")},
                                             {S("Auto"), S("auto")},
                                             {S("Full access"), S("full-access")}};
  expect(modes.contains(label), S("no permissions are called %1").arg(label));
  return modes.value(label);
}

// Codex and Claude, ready, with models.
void offerCodexAndClaude(World& world) {
  const auto model = [](const QString& slug, const QString& name) {
    return QJsonObject{{S("slug"), slug}, {S("name"), name}, {S("isCustom"), false}};
  };
  const auto provider = [](const QString& id, const QString& name, const QJsonArray& models) {
    return QJsonObject{{S("instanceId"), id}, {S("driver"), id},       {S("displayName"), name}, {S("enabled"), true},
                       {S("installed"), true}, {S("status"), S("ready")}, {S("models"), models}};
  };
  offerProviders(world.mc, {provider(S("codex"), S("Codex"), {model(S("gpt-5"), S("GPT-5"))}),
                            provider(S("claudeAgent"), S("Claude"), {model(S("claude-sonnet"), S("Sonnet")), model(S("claude-opus"), S("Opus"))})});
  world.sync();
}

// Taps `combo` open, unless it is, and taps its row `label`.
void choose(World& world, QQuickItem* combo, const QString& label) {
  QObject* popup = popupOf(combo);
  if (!popup->property("opened").toBool()) world.tap(combo);
  world.waitFor([&] { return popup->property("opened").toBool(); }, [&] { return S("%1 to open").arg(combo->objectName()); });
  QQuickItem* row = nullptr;
  world.waitFor(
      [&] {
        row = world.findWhere([&](QQuickItem* item) {
          QQuickItem* list = item->parentItem() ? item->parentItem()->parentItem() : nullptr;
          return item->inherits("QQuickItemDelegate") && item->property("text").toString() == label && list && list->objectName() == QLatin1String("comboRows");
        });
        return row != nullptr;
      },
      [&] { return S("%1 to offer %2; it offers %3").arg(combo->objectName(), label, combo->property("model").toStringList().join(u", ")); });
  world.tap(row);
  world.sync();
}

// The MC was told the thread's permissions are `mode`, and its row says so.
void applied(World& world, const QString& mode) {
  world.waitFor(
      [&] {
        return std::any_of(world.mc.commands.cbegin(), world.mc.commands.cend(), [&](const QJsonObject& command) {
          return command.value(QLatin1String("type")) == QLatin1String("thread.runtime-mode.set") && command.value(QLatin1String("runtimeMode")) == mode;
        });
      },
      [&] { return S("the MC to be told the thread runs in %1").arg(mode); });
  updateRow(world.mc, world.thread, {{S("runtimeMode"), mode}});
  world.sync();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(S("a project with an open thread on Codex"), [](World& world, const Captures&, const Table&) {
    pairWithEnvironment(world);
    offerCodexAndClaude(world);
    world.thread = haveThread(world, S("Tax line"));
    openThread(world, S("Tax line"));
    updateRow(world.mc, world.thread, {{S("modelSelection"), QJsonObject{{S("instanceId"), S("codex")}, {S("model"), S("gpt-5")}}}});
    world.sync();
    world.waitFor([&] { return composer(world).value(S("selectedModel")) == QLatin1String("gpt-5") && world.item(S("modelPicker"))->isEnabled(); },
                  [&] { return S("the composer on gpt-5; it shows %1").arg(show(composer(world))); });
  });

  // Settings → Project defaults; the MC keeps them.
  step(S("the default permissions (?:for new threads )?are (.+)"), [](World& world, const Captures& c, const Table&) {
    const QString mode = modeOf(c[0]);
    pairWithEnvironment(world);
    saveOwnSetting(world.mc, S("defaultRuntimeMode"), mode);
    world.waitFor([&] { return world.native().controller<SettingsController>()->value(S("defaultRuntimeMode")) == mode; },
                  S("the phone to read the default permissions"));
  });
  step(S("the open thread runs in (.+)"), [](World& world, const Captures& c, const Table&) {
    const QString mode = modeOf(c[0]);
    updateRow(world.mc, world.thread, {{S("runtimeMode"), mode}});
    world.sync();
    world.waitFor([&] { return composer(world).value(S("runtimeMode")) == mode; },
                  [&] { return S("the thread in %1; the composer shows %2").arg(c[0], show(composer(world))); });
  });
  step(S("the user looks at the composer"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(S("the composer does not name the permissions"), [](World& world, const Captures&, const Table&) {
    expect(composer(world).value(S("runtimeMode")) == composer(world).value(S("defaultRuntimeMode")),
           S("the thread's permissions are not the default; the composer shows %1").arg(show(composer(world))));
    QQuickItem* chip = part(world, S("runtimeModePicker"));
    expect(!chip->property("present").toBool() && !chip->isVisible() && !shown(world, S("contextPermissions")), S("the composer names the permissions"));
  });
  step(S("the user sets the thread's permissions to (.+) from the effort menu"), [](World& world, const Captures& c, const Table&) {
    QQuickItem* picker = part(world, S("modelPicker"));
    world.tap(picker);
    world.waitFor([&] { return popupOf(picker)->property("opened").toBool(); }, S("the model control to open"));
    choose(world, part(world, S("modelPickerPermissions")), c[0]);
    applied(world, modeOf(c[0]));
  });
  // Beside the model on the toolbar, or in its menu when the phone's toolbar
  // has folded it away.
  step(S("the composer names %1 beside the model").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* chip = part(world, S("runtimeModePicker"));
    world.waitFor([&] { return chip->property("present").toBool() && chip->property("displayText") == c[0]; },
                  [&] { return S("the toolbar to name %1; the composer shows %2").arg(c[0], show(composer(world))); });
    expect(chip->parentItem() == part(world, S("toolbarChips")), S("the permissions are not on the toolbar"));
  });

  // A new thread names them in its context strip.
  step(S("the draft says it will run in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor(
        [&] {
          QQuickItem* named = part(world, S("contextPermissions"));
          return composer(world).value(S("routeKind")) == QLatin1String("draft") && named->isVisible() && named->property("displayText") == c[0];
        },
        [&] { return S("the draft to name %1; the composer shows %2").arg(c[0], show(composer(world))); });
    expect(!shown(world, S("runtimeModePicker")), S("the toolbar names the permissions too"));
  });
  step(S("the user chooses the permissions it names"), [](World& world, const Captures&, const Table&) { world.tap(part(world, S("contextPermissions"))); });
  step(S("the user can pick other permissions for the thread"), [](World& world, const Captures&, const Table&) {
    QQuickItem* named = part(world, S("contextPermissions"));
    world.waitFor([&] { return popupOf(named)->property("opened").toBool(); }, S("the permissions menu to open"));
    expect(!popupOf(part(world, S("modelPicker")))->property("visible").toBool(), S("the model list opened first"));
    choose(world, named, S("Supervised"));
    world.waitFor([&] { return composer(world).value(S("runtimeMode")) == QLatin1String("approval-required"); },
                  [&] { return S("the draft in Supervised; the composer shows %1").arg(show(composer(world))); });
  });

  // The phone's back steps out of the menu before the model control.
  step(S("the user opens the permissions in the model control"), [](World& world, const Captures&, const Table&) {
    QQuickItem* picker = part(world, S("modelPicker"));
    world.tap(picker);
    world.waitFor([&] { return popupOf(picker)->property("opened").toBool(); }, S("the model control to open"));
    QQuickItem* permissions = part(world, S("modelPickerPermissions"));
    world.tap(permissions);
    world.waitFor([&] { return popupOf(permissions)->property("opened").toBool(); }, S("the permissions menu to open"));
  });
  step(S("the user presses the system's back"), [](World& world, const Captures&, const Table&) {
    world.back();
    world.sync();
  });
  step(S("the permissions menu closes and the model control stays open"), [](World& world, const Captures&, const Table&) {
    QObject* menu = popupOf(part(world, S("modelPickerPermissions")));
    world.waitFor([&] { return !menu->property("visible").toBool(); }, S("the permissions menu to close"));
    expect(popupOf(part(world, S("modelPicker")))->property("visible").toBool(), S("the model control closed too"));
  });
  step(S("the model control closes"), [](World& world, const Captures&, const Table&) {
    QObject* popup = popupOf(part(world, S("modelPicker")));
    world.waitFor([&] { return !popup->property("visible").toBool(); }, S("the model control to close"));
  });
});

}  // namespace
