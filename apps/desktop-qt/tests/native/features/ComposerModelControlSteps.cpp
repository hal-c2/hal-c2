// The model control: the model picker with the chosen model's efforts and
// options beside it and speed and permissions below, as upstream's one
// model-and-effort control (features/composer/model-and-mode.feature).

#include <algorithm>

#include <QInputMethodEvent>
#include <QJsonArray>
#include <QJsonObject>
#include <QPointer>
#include <QQuickItem>
#include <QTest>

#include "Brick.h"
#include "ComposerBrick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "SettingsController.h"
#include "Stream.h"
#include "Turn.h"
#include "World.h"

using namespace stream;

namespace {

using S = QString;

// What the When steps saw after each pick, for the Then that follows.
struct Picks {
  QStringList left;
  QString searched;
  qreal height = 0;
};

QVariantMap composer(World& world) {
  return world.state(S("composer")).toMap();
}

QJsonObject choice(const QString& id, const QString& label) {
  return {{S("id"), id}, {S("label"), label}};
}

QJsonObject select(const QString& id, const QString& label, const QJsonArray& choices, const QString& current) {
  return {{S("id"), id}, {S("label"), label}, {S("type"), S("select")}, {S("options"), choices}, {S("currentValue"), current}};
}

QJsonObject toggle(const QString& id, const QString& label, bool current) {
  return {{S("id"), id}, {S("label"), label}, {S("type"), S("boolean")}, {S("currentValue"), current}};
}

QJsonObject model(const QString& slug, const QString& name, const QJsonArray& descriptors) {
  return {{S("slug"), slug}, {S("name"), name}, {S("capabilities"), QJsonObject{{S("optionDescriptors"), descriptors}}}};
}

QJsonObject provider(const QString& id, const QString& driver, const QString& name, const QJsonArray& models) {
  return {{S("instanceId"), id}, {S("driver"), driver}, {S("displayName"), name}, {S("enabled"), true},
          {S("installed"), true}, {S("status"), S("ready")}, {S("models"), models}};
}

QJsonArray efforts(const QString& current) {
  return {select(S("reasoningEffort"), S("Reasoning"), {choice(S("low"), S("Low")), choice(S("medium"), S("Medium")), choice(S("high"), S("High"))}, current),
          toggle(S("fastMode"), S("Fast mode"), false)};
}

QJsonObject codex() {
  return provider(S("codex"), S("codex"), S("Codex"), {model(S("gpt-5.4"), S("GPT-5.4"), efforts(S("medium"))), model(S("gpt-5.5"), S("GPT-5.5"), efforts(S("high")))});
}

QJsonObject claude() {
  return provider(S("claudeAgent"), S("claudeAgent"), S("Claude"), {model(S("claude-haiku"), S("Claude Haiku"), {})});
}

// The thread on `slug` of `instanceId` in its default permissions; the
// toolbar names them and the permissions key opens the model control.
void onModel(World& world, const QJsonArray& providers, const QString& instanceId, const QString& slug) {
  publishProviders(world.mc, providers);
  openTurnThread(world);
  composerBrick(world);
  world.waitFor([&] { return !composer(world).value(S("defaultRuntimeMode")).toString().isEmpty(); },
                [&] { return S("the composer to know the default permissions; it shows %1").arg(show(composer(world))); });
  QJsonObject& row = world.mc.threads[kThread];
  row.insert(S("modelSelection"), QJsonObject{{S("instanceId"), instanceId}, {S("model"), slug}});
  row.insert(S("runtimeMode"), composer(world).value(S("defaultRuntimeMode")).toString());
  world.mc.sendRow(kThread, row);
  world.sync();
  world.waitFor([&] { return composer(world).value(S("selectedModel")) == slug && !composer(world).value(S("options")).toList().isEmpty(); },
                [&] { return S("the composer on %1; it shows %2").arg(slug, show(composer(world))); });
}

void codexThread(World& world) {
  onModel(world, {codex(), claude()}, S("codex"), S("gpt-5.4"));
}

QQuickItem* picker(World& world) {
  QQuickItem* item = composerPart(world, S("modelPicker"));
  expect(item != nullptr, S("the composer has no model control"));
  return item;
}

QObject* popupOf(QQuickItem* control) {
  QObject* popup = control->property("popup").value<QObject*>();
  expect(popup != nullptr, S("%1 has no popup").arg(control->objectName()));
  return popup;
}

bool controlOpen(World& world) {
  return popupOf(picker(world))->property("opened").toBool();
}

QQuickItem* focused(World& world) {
  return composerBrick(world).window().activeFocusItem();
}

QString focusName(World& world) {
  QQuickItem* item = focused(world);
  return item ? item->objectName() : S("nothing");
}

// Whether the keyboard is in the open model control.
bool focusInControl(World& world) {
  QQuickItem* content = popupOf(picker(world))->property("contentItem").value<QQuickItem*>();
  QQuickItem* item = focused(world);
  return content && item && (item == content || content->isAncestorOf(item));
}

void click(World& world, QQuickItem* item) {
  Brick& brick = composerBrick(world);
  expect(item->isVisible(), S("%1 is not on screen").arg(item->objectName()));
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item));
  world.sync();
}

QString optionValue(World& world, const QString& id) {
  for (const QVariant& option : composer(world).value(S("options")).toList()) {
    if (option.toMap().value(S("id")) == id) return option.toMap().value(S("value")).toString();
  }
  return {};
}

QString effortValue(World& world) {
  for (const QVariant& option : composer(world).value(S("options")).toList()) {
    if (option.toMap().value(S("effort")).toBool()) return option.toMap().value(S("value")).toString();
  }
  return {};
}

QStringList effortIds(World& world) {
  QStringList ids;
  for (QQuickItem* row : modelControlEfforts(world)) ids.append(row->objectName().section(u':', 1));
  return ids;
}

// The row of `slug` in its provider's list, from the rail.
QQuickItem* modelRow(World& world, const QString& instanceId, const QString& slug) {
  const QString name = S("modelPickerRow:%1:%2").arg(instanceId, slug);
  if (!composerPart(world, name)) click(world, modelControlPart(world, S("modelPickerProvider:") + instanceId));
  return modelControlPart(world, name);
}

QRectF sceneRect(QQuickItem* item) {
  return item->mapRectToScene(QRectF(0, 0, item->width(), item->height()));
}

// A press of `key` where the keyboard is, as ShellWindow's Shortcut takes it.
void pressShortcut(World& world, const QString& key) {
  auto* keys = world.native().controller<KeybindingController>();
  const QString sequence = keybindings::sequence(*keybindings::parseShortcut(key), keys->mac());
  QQuickItem* item = focused(world);
  const bool inComposer = item && composerItem(world)->isAncestorOf(item);
  const bool editable = item && (item->inherits("QQuickTextInput") || item->inherits("QQuickTextEdit"));
  const QVariantMap focus{{S("composer"), inComposer}, {S("editable"), editable || inComposer}};
  expect(keys->press(sequence, focus), S("%1 runs nothing with the keyboard on %2").arg(key, focusName(world)));
  world.sync();
}

void waitOnEffort(World& world) {
  world.waitFor([&] { return controlOpen(world) && focusName(world) == S("modelControlEffort:") + effortValue(world); },
                [&] { return S("the model control open on the %1 effort; the keyboard is on %2").arg(effortValue(world), focusName(world)); });
}

void waitOnPermissions(World& world) {
  QQuickItem* permissions = modelControlPart(world, S("modelPickerPermissions"));
  world.waitFor([&] { return controlOpen(world) && popupOf(permissions)->property("opened").toBool(); },
                [&] { return S("the model control open on its permissions; the keyboard is on %1").arg(focusName(world)); });
}

void composing(World& world, const QString& preedit) {
  QInputMethodEvent event(preedit, {});
  QCoreApplication::sendEvent(focused(world), &event);
  world.sync();
}

void commit(World& world, const QString& text) {
  QInputMethodEvent event;
  event.setCommitString(text);
  QCoreApplication::sendEvent(focused(world), &event);
  world.sync();
}

QString searchText(World& world) {
  return modelControlPart(world, S("modelPickerSearch"))->property("text").toString();
}

const Steps steps([] {
  // One control: the models, the chosen model's efforts beside them, and
  // speed and permissions below.
  step(S("the user opens the model control in the composer"), [](World& world, const Captures&, const Table&) {
    codexThread(world);
    openModelControl(world);
  });
  step(S("the models are listed with the chosen model's efforts beside them, and speed and permissions below"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return effortIds(world) == QStringList{S("low"), S("medium"), S("high")}; },
                  [&] { return S("the model control to list low, medium and high; it lists %1").arg(effortIds(world).join(u", ")); });
    const QRectF list = sceneRect(modelRow(world, S("codex"), S("gpt-5.4")));
    const QRectF effort = sceneRect(modelControlEfforts(world).first());
    expect(effort.left() >= list.right(), S("the efforts are not beside the models"));
    const QRectF speed = sceneRect(modelControlPart(world, S("modelControlSpeed")));
    const QRectF permissions = sceneRect(modelControlPart(world, S("modelPickerPermissions")));
    expect(speed.top() >= list.bottom() && permissions.top() >= list.bottom() && speed.top() >= effort.bottom(),
           S("speed and permissions are not below the models and efforts"));
    expect(modelControlPart(world, S("modelControlSpeed:true"))->property("text") == S("Fast"), S("the speed offers no Fast"));
  });
  step(S("the user picks a model that has efforts"), [](World& world, const Captures&, const Table&) {
    click(world, modelRow(world, S("codex"), S("gpt-5.5")));
    world.waitFor([&] { return composer(world).value(S("selectedModel")) == S("gpt-5.5"); },
                  [&] { return S("the composer on GPT-5.5; it shows %1").arg(show(composer(world))); });
  });
  step(S("the picker stays open on that model's current effort"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return effortValue(world) == S("high"); }, [&] { return S("GPT-5.5's effort to be high; it is %1").arg(effortValue(world)); });
    waitOnEffort(world);
  });
  step(S("picking a model without efforts chooses it at once"), [](World& world, const Captures&, const Table&) {
    click(world, modelRow(world, S("claudeAgent"), S("claude-haiku")));
    world.waitFor([&] { return composer(world).value(S("selectedModel")) == S("claude-haiku") && !controlOpen(world); },
                  [&] { return S("Claude Haiku chosen and the control shut; the composer is on %1, the control %2")
                                   .arg(composer(world).value(S("selectedModel")).toString(), controlOpen(world) ? S("open") : S("shut")); });
  });

  // The effort and permissions keys open the control at their part.
  step(S("the user presses (mod\\+shift\\+[ea]) while typing in the composer"), [](World& world, const Captures& c, const Table&) {
    codexThread(world);
    expect(!controlOpen(world), S("the model control is open already"));
    QMetaObject::invokeMethod(composerItem(world), "focusInput");
    world.sync();
    pressShortcut(world, c[0]);
  });
  step(S("the model control opens on the current effort"), [](World& world, const Captures&, const Table&) { waitOnEffort(world); });
  step(S("the model control opens on the permissions"), [](World& world, const Captures&, const Table&) { waitOnPermissions(world); });
  step(S("pressing it while the control is open moves there"), [](World& world, const Captures&, const Table&) {
    // Elsewhere in the control first: the search.
    Brick& brick = composerBrick(world);
    QQuickItem* permissions = modelControlPart(world, S("modelPickerPermissions"));
    const bool onPermissions = popupOf(permissions)->property("opened").toBool();
    if (onPermissions) QTest::keyClick(&brick.window(), Qt::Key_Escape);
    world.waitFor([&] { return !popupOf(permissions)->property("opened").toBool(); }, S("the permissions menu to close"));
    click(world, modelControlPart(world, S("modelPickerSearch")));
    world.waitFor([&] { return controlOpen(world) && focusName(world) == S("modelPickerSearch"); },
                  [&] { return S("the keyboard in the search; it is on %1").arg(focusName(world)); });
    pressShortcut(world, onPermissions ? S("mod+shift+a") : S("mod+shift+e"));
    if (onPermissions) {
      waitOnPermissions(world);
    } else {
      waitOnEffort(world);
    }
  });

  // A pick leaves the control open.
  step(S("the user opened the model control"), [](World& world, const Captures&, const Table&) {
    codexThread(world);
    openModelControl(world);
  });
  step(S("the user picks an effort, turns fast mode on or changes the permissions"), [](World& world, const Captures&, const Table&) {
    Picks& picks = world.mc.part<Picks>();
    const auto check = [&](const QString& pick) {
      world.sync();
      if (!controlOpen(world) || !focusInControl(world)) picks.left.append(S("%1 (the keyboard on %2)").arg(pick, focusName(world)));
    };
    click(world, modelControlPart(world, S("modelControlEffort:high")));
    world.waitFor([&] { return effortValue(world) == S("high"); }, [&] { return S("the effort to be high; it is %1").arg(effortValue(world)); });
    check(S("the effort"));
    world.waitFor([&] { return focusName(world) == S("modelControlEffort:high"); },
                  [&] { return S("the keyboard on the picked effort; it is on %1").arg(focusName(world)); });
    click(world, modelControlPart(world, S("modelControlSpeed:true")));
    world.waitFor([&] { return optionValue(world, S("fastMode")) == S("true"); }, [&] { return S("fast mode on; it is %1").arg(optionValue(world, S("fastMode"))); });
    check(S("fast mode"));
    // The permissions from their menu, by the keyboard.
    Brick& brick = composerBrick(world);
    QQuickItem* permissions = modelControlPart(world, S("modelPickerPermissions"));
    const int from = permissions->property("currentIndex").toInt();
    click(world, permissions);
    world.waitFor([&] { return popupOf(permissions)->property("opened").toBool(); }, S("the permissions menu to open"));
    QTest::keyClick(&brick.window(), from == 0 ? Qt::Key_Down : Qt::Key_Up);
    QTest::keyClick(&brick.window(), Qt::Key_Return);
    world.waitFor([&] {
      return std::any_of(world.mc.commands.cbegin(), world.mc.commands.cend(),
                         [](const QJsonObject& command) { return command.value(QLatin1String("type")) == QLatin1String("thread.runtime-mode.set"); });
    }, [&] { return S("the permissions change; the MC has %1").arg(world.describeCommands()); });
    world.waitFor([&] { return !popupOf(permissions)->property("opened").toBool(); }, S("the permissions menu to close"));
    check(S("the permissions"));
  });
  step(S("the control stays open with the focus in it"), [](World& world, const Captures&, const Table&) {
    const Picks& picks = world.mc.part<Picks>();
    expect(picks.left.isEmpty(), S("the control closed or lost the keyboard after %1").arg(picks.left.join(u", ")));
    expect(controlOpen(world) && focusInControl(world), S("the control is shut or the keyboard is on %1").arg(focusName(world)));
  });
  step(S("Escape or a click outside closes it"), [](World& world, const Captures&, const Table&) {
    Brick& brick = composerBrick(world);
    QTest::keyClick(&brick.window(), Qt::Key_Escape);
    world.waitFor([&] { return !controlOpen(world); }, S("Escape to close the model control"));
    world.waitFor([&] { return focusName(world) == S("modelPicker"); }, [&] { return S("the keyboard back on the control; it is on %1").arg(focusName(world)); });
    openModelControl(world);
    // Anywhere the popup and its trigger are not: a small window puts the
    // popup over the editor.
    QQuickItem* content = popupOf(picker(world))->property("contentItem").value<QQuickItem*>();
    const QRectF popupRect = content->parentItem()->mapRectToScene(QRectF(0, 0, content->parentItem()->width(), content->parentItem()->height()));
    const QRectF triggerRect = picker(world)->mapRectToScene(QRectF(0, 0, picker(world)->width(), picker(world)->height()));
    const QSize size = brick.window().size();
    QPoint outside(-1, -1);
    for (const QPoint candidate : {QPoint(4, 4), QPoint(size.width() - 4, 4), QPoint(4, size.height() - 4), QPoint(size.width() - 4, size.height() - 4)})
      if (!popupRect.contains(candidate) && !triggerRect.contains(candidate)) {
        outside = candidate;
        break;
      }
    expect(outside.x() >= 0, S("the popup covers the window"));
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, outside);
    world.sync();
    world.waitFor([&] { return !controlOpen(world); }, S("a click outside to close the model control"));
  });

  // An ACP agent's own options: its thinking levels are the efforts, each
  // other option one row.
  step(S("an ACP agent offers a long model name, a session mode, auto-approve and its own thinking levels"), [](World& world, const Captures&, const Table&) {
    QJsonObject thinking = select(S("thought_level"), S("Thinking"), {choice(S("low"), S("Low")), choice(S("medium"), S("Medium")), choice(S("high"), S("High"))}, S("medium"));
    thinking.insert(S("role"), S("reasoning"));
    const QJsonArray options{
        select(S("mode"), S("Session Mode"), {choice(S("default"), S("Default")), choice(S("plan"), S("Plan")), choice(S("bypassPermissions"), S("Bypass Permissions"))}, S("bypassPermissions")),
        thinking,
        toggle(S("autoApprove"), S("Auto-approve tools"), false),
        toggle(S("fastMode"), S("Fast mode"), true),
        select(S("contextWindow"), S("Context window"), {choice(S("200k"), S("200K")), choice(S("1m"), S("1M"))}, S("1m")),
    };
    const QJsonObject agent = provider(S("gemini"), S("acpRegistry"), S("Gemini CLI"),
                                       {model(S("gemini-long"), S("Gemini 3.1 Pro Preview with the Extended Long Context Window"), options)});
    onModel(world, {agent, codex()}, S("gemini"), S("gemini-long"));
    // Appearance's Bars, so the levels are drawn.
    world.native().controller<SettingsController>()->set(S("effortDisplay"), S("bars"));
    world.waitFor([&] { return composer(world).value(S("effortDisplay")) == S("bars"); }, S("the composer to draw the effort as bars"));
  });
  step(S("the user opens the model control"), [](World& world, const Captures&, const Table&) {
    QQuickItem* control = openModelControl(world);
    world.mc.part<Picks>().height = popupOf(control)->property("height").toReal();
  });
  step(S("the agent's thinking levels are the efforts, shown as rising bars"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return effortIds(world) == QStringList{S("low"), S("medium"), S("high")}; },
                  [&] { return S("the thinking levels as the efforts; the control lists %1").arg(effortIds(world).join(u", ")); });
    expect(modelControlPart(world, S("modelControlHeader"))->property("text") == S("Thinking"), S("the efforts are not named Thinking"));
    QQuickItem* bars = composerPart(world, S("modelPickerEffortBars"));
    world.waitFor([&] { return bars && bars->isVisible() && bars->property("count").toInt() == 3 && bars->property("filled").toInt() == 2; },
                  [&] { return S("two of three bars filled; %1 of %2 are").arg(bars ? bars->property("filled").toInt() : -1).arg(bars ? bars->property("count").toInt() : -1); });
    // Rising: each bar taller than the one before.
    qreal last = 0;
    for (QQuickItem* bar : bars->childItems()) {
      if (!bar->isVisible() || !bar->inherits("QQuickRectangle")) continue;
      expect(bar->height() > last, S("the bars do not rise"));
      last = bar->height();
    }
    expect(last > 0, S("the bars draw nothing"));
  });
  step(S("each other option is one row naming its value, opening its choices beside it, and an on or off option is a switch"), [](World& world, const Captures&, const Table&) {
    QQuickItem* mode = modelControlPart(world, S("modelControlOption:mode"));
    expect(mode->property("text") == S("Session Mode") && mode->property("detail") == S("Bypass Permissions"),
           S("the mode row reads %1, %2").arg(mode->property("text").toString(), mode->property("detail").toString()));
    expect(!composerPart(world, S("modelControlEffort:plan")), S("the mode's choices are among the efforts"));
    click(world, mode);
    // Picking rebuilds the rows, the menu with them.
    const QPointer<QObject> choices = mode->findChild<QObject*>(S("modelControlChoices:mode"));
    expect(choices != nullptr, S("the mode row has no choices"));
    world.waitFor([&] { return choices->property("opened").toBool(); }, S("the mode's choices to open"));
    QQuickItem* plan = modelControlPart(world, S("modelControlChoice:mode:plan"));
    expect(sceneRect(plan).left() >= sceneRect(mode).right() - 1, S("the mode's choices do not open beside it"));
    click(world, plan);
    world.waitFor([&] { return optionValue(world, S("mode")) == S("plan") && (!choices || !choices->property("opened").toBool()); },
                  [&] { return S("the mode set to plan; it is %1").arg(optionValue(world, S("mode"))); });
    world.waitFor([&] { return modelControlPart(world, S("modelControlOption:mode"))->property("detail") == S("Plan"); }, S("the mode row to read Plan"));
    // Auto-approve is a switch, and so is fast mode left out for the speed.
    QQuickItem* approve = modelControlPart(world, S("modelControlSwitch:autoApprove"));
    expect(approve->property("switchRow").toBool() && !approve->property("switchOn").toBool(), S("auto-approve is not an off switch"));
    click(world, approve);
    world.waitFor([&] { return optionValue(world, S("autoApprove")) == S("true"); }, S("auto-approve to turn on"));
    world.waitFor([&] { return modelControlPart(world, S("modelControlSwitch:autoApprove"))->property("switchOn").toBool(); }, S("the switch to show it on"));
    expect(controlOpen(world), S("the picks closed the model control"));
  });
  step(S("the composer names only the model, cut short when long, with its effort, fast mode and context window"), [](World& world, const Captures&, const Table&) {
    QQuickItem* title = composerPart(world, S("modelPickerTitle"));
    // The short name: the picker drops the provider's own brand.
    expect(title && title->property("text").toString().contains(S("3.1 Pro Preview")), S("the trigger names %1").arg(title ? title->property("text").toString() : S("nothing")));
    world.waitFor([&] { return title->property("truncated").toBool(); }, S("the long name to be cut short"));
    expect(composerPart(world, S("modelPickerEffortBars"))->isVisible(), S("the trigger shows no effort"));
    expect(composerPart(world, S("modelPickerFast"))->isVisible(), S("the trigger shows no fast mode"));
    expect(composerPart(world, S("modelPickerContextWindow"))->property("text") == S("1M"), S("the trigger shows no context window"));
    // Nothing else: the mode and auto-approve stay in the control.
    for (const QString& chip : {S("optionPicker:mode"), S("optionToggle:autoApprove"), S("effortPicker")}) {
      QQuickItem* item = composerPart(world, chip);
      expect(!item || !item->isVisible(), S("the toolbar shows %1").arg(chip));
    }
  });
  step(S("the picker keeps one height while the user moves between providers"), [](World& world, const Captures&, const Table&) {
    QObject* popup = popupOf(picker(world));
    const qreal height = world.mc.part<Picks>().height;
    expect(height > 0, S("the control's height was not taken"));
    for (const QString& instance : {S("codex"), S("gemini"), S("codex")}) {
      click(world, modelControlPart(world, S("modelPickerProvider:") + instance));
      world.waitFor([&] { return composerPart(world, S("modelPickerRow:%1:%2").arg(instance, instance == S("codex") ? S("gpt-5.4") : S("gemini-long"))) != nullptr; },
                    [&] { return S("%1's models listed").arg(instance); });
      expect(qFuzzyCompare(popup->property("height").toReal(), height), S("the control is %1 tall on %2, not %3").arg(popup->property("height").toReal()).arg(instance).arg(height));
    }
  });

  // An input method's Enter and Escape are its own.
  step(S("the user is searching the models with a Japanese input method"), [](World& world, const Captures&, const Table&) {
    codexThread(world);
    openModelControl(world);
    world.waitFor([&] { return focusName(world) == S("modelPickerSearch"); }, [&] { return S("the keyboard in the search; it is on %1").arg(focusName(world)); });
  });
  step(S("the user presses Enter to confirm the composed text, or Escape to cancel it"), [](World& world, const Captures&, const Table&) {
    Brick& brick = composerBrick(world);
    Picks& picks = world.mc.part<Picks>();
    QQuickItem* search = modelControlPart(world, S("modelPickerSearch"));
    // げん, confirmed as 現 with Enter.
    composing(world, S("げん"));
    expect(search->property("inputMethodComposing").toBool(), S("the search is not composing"));
    QTest::keyClick(&brick.window(), Qt::Key_Return);
    if (!controlOpen(world)) picks.left.append(S("Enter"));
    commit(world, S("現"));
    // ご, then cancelled with Escape.
    composing(world, S("ご"));
    QTest::keyClick(&brick.window(), Qt::Key_Escape);
    if (!controlOpen(world)) picks.left.append(S("Escape"));
    composing(world, QString());
    picks.searched = S("現");
  });
  step(S("the picker stays open with the search text as the input method left it"), [](World& world, const Captures&, const Table&) {
    const Picks& picks = world.mc.part<Picks>();
    expect(picks.left.isEmpty(), S("the picker closed on %1").arg(picks.left.join(u", ")));
    expect(controlOpen(world), S("the picker closed"));
    world.waitFor([&] { return searchText(world) == picks.searched && picker(world)->property("query") == picks.searched; },
                  [&] { return S("the search to read %1; it reads %2").arg(picks.searched, searchText(world)); });
    expect(composer(world).value(S("selectedModel")) == S("gpt-5.4"), S("a model was chosen"));
  });
  step(S("Enter outside composition still chooses the highlighted model, and Escape closes the picker"), [](World& world, const Captures&, const Table&) {
    Brick& brick = composerBrick(world);
    QQuickItem* search = modelControlPart(world, S("modelPickerSearch"));
    QTest::keyClick(&brick.window(), Qt::Key_Backspace);
    for (const char key : "haiku") if (key) QTest::keyClick(&brick.window(), key);
    world.waitFor([&] { return search->property("text") == S("haiku"); }, [&] { return S("the search to read haiku; it reads %1").arg(search->property("text").toString()); });
    QTest::keyClick(&brick.window(), Qt::Key_Return);
    world.waitFor([&] { return composer(world).value(S("selectedModel")) == S("claude-haiku") && !controlOpen(world); },
                  [&] { return S("Enter to choose Claude Haiku; the composer is on %1").arg(composer(world).value(S("selectedModel")).toString()); });
    openModelControl(world);
    world.waitFor([&] { return focusName(world) == S("modelPickerSearch"); }, [&] { return S("the keyboard in the search; it is on %1").arg(focusName(world)); });
    QTest::keyClick(&brick.window(), Qt::Key_Escape);
    world.waitFor([&] { return !controlOpen(world); }, S("Escape to close the picker"));
  });
});

}  // namespace
