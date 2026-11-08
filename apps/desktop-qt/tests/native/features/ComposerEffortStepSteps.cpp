// The effort stepped from the keyboard without opening its picker
// (composer.increaseEffort / decreaseEffort), and an effort the prompt asks
// for in its own words (features/composer/model-and-mode.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include "Brick.h"
#include "ComposerBrick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "Keymap.h"
#include "NativeShell.h"
#include "Stream.h"
#include "Turn.h"
#include "World.h"

using namespace stream;

namespace {

using S = QString;

// The keys the scenario gives the two commands, which have none by default.
const QString kUp = S("mod+alt+k");
const QString kDown = S("mod+alt+j");

struct Stepping {
  bool bound = false;
  // The step key is held down after one step: the next is a repeat.
  bool held = false;
  QString effortBefore;
  QString text;
  int cursor = -1;
};

QVariantMap composer(World& world) {
  return world.state(S("composer")).toMap();
}

// The composer's effort: its first choice option.
QVariantMap effort(World& world) {
  for (const QVariant& option : composer(world).value(S("options")).toList()) {
    if (option.toMap().value(S("type")) == QLatin1String("select")) return option.toMap();
  }
  return {};
}

QString effortValue(World& world) {
  return effort(world).value(S("value")).toString();
}

QStringList effortChoices(World& world) {
  QStringList ids;
  for (const QVariant& choice : effort(world).value(S("choices")).toList()) ids.append(choice.toMap().value(S("id")).toString());
  return ids;
}

QQuickItem* effortPicker(World& world) {
  QQuickItem* picker = composerPart(world, S("effortPicker"));
  expect(picker && picker->isVisible(), S("the composer shows no effort picker"));
  return picker;
}

// A press of `key` with the keyboard in the composer, as ShellWindow's
// Shortcut for it takes it: only when the key is the shell's there, and a
// held key again only when the Shortcut repeats.
void pressStep(World& world, const QString& key, bool repeat) {
  auto* keys = world.native().controller<KeybindingController>();
  const QString sequence = keybindings::sequence(*keybindings::parseShortcut(key), keys->mac());
  QVariantMap shortcut;
  for (const QVariant& value : keys->shortcuts()) {
    if (value.toMap().value(S("sequence")) == sequence) shortcut = value.toMap();
  }
  expect(!shortcut.isEmpty(), S("no window shortcut for %1").arg(key));
  expect(shortcut.value(S("composer")).toBool(), S("%1 is not the shell's while the composer has the keyboard").arg(key));
  if (repeat && !shortcut.value(S("autoRepeat")).toBool()) return;
  keys->press(sequence, {{S("composer"), true}, {S("editable"), true}});
  world.sync();
}

void bindSteps(World& world) {
  Stepping& state = world.mc.part<Stepping>();
  if (state.bound) return;
  state.bound = true;
  bindKey(world, kUp, S("composer.increaseEffort"));
  bindKey(world, kDown, S("composer.decreaseEffort"));
  world.sync();
}

void setEffort(World& world, const QString& value) {
  world.bridge().dispatch(S("composer.option.set"), QVariantMap{{S("id"), effort(world).value(S("id"))}, {S("value"), value}});
  world.waitFor([&] { return effortValue(world) == value; }, [&] { return S("the effort to be %1; it is %2").arg(value, show(effort(world))); });
}

QJsonArray providers(World& world) {
  return fakeConfig(world.mc).config.value(QLatin1String("providers")).toArray();
}

void updateThread(World& world, const QJsonObject& fields) {
  QJsonObject& row = world.mc.threads[kThread];
  for (auto it = fields.begin(); it != fields.end(); ++it) row.insert(it.key(), it.value());
  world.mc.sendRow(kThread, row);
  world.sync();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(S("the thread runs on a model whose efforts are low, medium and high"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return effortChoices(world) == QStringList{S("low"), S("medium"), S("high")}; },
                  [&] { return S("the model's efforts to be low, medium and high; they are %1").arg(show(effort(world))); });
  });
  step(S("the effort is (low|medium|high) and the user is typing a draft"), [](World& world, const Captures& c, const Table&) {
    setEffort(world, c[0]);
    composerBrick(world);
    typeInComposer(world, S("fix the tax line"));
    settleComposer(world);
    // The caret mid-word, where the user stopped.
    QQuickItem* editor = composerEditor(world);
    editor->setProperty("cursorPosition", 7);
    Stepping& state = world.mc.part<Stepping>();
    state.text = editor->property("text").toString();
    state.cursor = editor->property("cursorPosition").toInt();
  });

  step(S("the user steps the effort (up|down)"), [](World& world, const Captures& c, const Table&) {
    bindSteps(world);
    Stepping& state = world.mc.part<Stepping>();
    state.effortBefore = effortValue(world);
    pressStep(world, c[0] == QLatin1String("up") ? kUp : kDown, state.held);
  });
  step(S("the effort is (low|medium|high)"), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return effortValue(world) == c[0]; }, [&] { return S("the effort to be %1; it is %2").arg(c[0], show(effort(world))); });
  });
  step(S("the effort is unchanged"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(effortValue(world) == world.mc.part<Stepping>().effortBefore,
           S("the effort went from %1 to %2").arg(world.mc.part<Stepping>().effortBefore, effortValue(world)));
  });
  step(S("the draft and where the user was typing are unchanged"), [](World& world, const Captures&, const Table&) {
    const Stepping& state = world.mc.part<Stepping>();
    QQuickItem* editor = composerEditor(world);
    expect(editor->property("text").toString() == state.text && editor->property("cursorPosition").toInt() == state.cursor,
           S("the draft reads \"%1\" with the caret at %2; it read \"%3\" at %4")
               .arg(editor->property("text").toString())
               .arg(editor->property("cursorPosition").toInt())
               .arg(state.text)
               .arg(state.cursor));
    expect(editor->hasActiveFocus(), S("the editor lost the keyboard"));
  });
  step(S("the effort picker stays closed"), [](World& world, const Captures&, const Table&) {
    QObject* popup = effortPicker(world)->property("popup").value<QObject*>();
    expect(popup && !popup->property("visible").toBool(), S("the effort picker opened"));
  });

  // The prompt's own ultrathink.
  step(S("the effort still reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(effortValue(world) == c[0].toLower(), S("the effort reads %1").arg(show(effort(world))));
  });
  step(S("the effort reads %1 and cannot be changed").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* picker = effortPicker(world);
    world.waitFor([&] { return picker->property("displayText") == c[0]; }, [&] { return S("the effort to read %1; it reads %2").arg(c[0], picker->property("displayText").toString()); });
    const int rows = picker->property("count").toInt();
    const QVariantList disabled = picker->property("disabledRows").toList();
    expect(rows > 0 && disabled.size() == rows, S("%1 of the effort's %2 rows can be chosen").arg(rows - disabled.size()).arg(rows));
    // Not by the controller either.
    world.bridge().dispatch(S("composer.option.set"), QVariantMap{{S("id"), effort(world).value(S("id"))}, {S("value"), S("high")}});
    world.sync();
    expect(picker->property("displayText") == c[0], S("the effort changed to %1").arg(picker->property("displayText").toString()));
  });
  step(S("the user is told \"(Your prompt contains .+)\""), [](World& world, const Captures& c, const Table&) {
    Brick& brick = composerBrick(world);
    QQuickItem* picker = effortPicker(world);
    QObject* popup = picker->property("popup").value<QObject*>();
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(picker));
    world.waitFor([&] { return popup->property("opened").toBool(); }, S("the effort picker to open"));
    QQuickItem* note = nullptr;
    world.waitFor([&] { return (note = composerPart(world, S("comboNote"))) != nullptr && note->isVisible(); }, S("the effort picker to say why"));
    expect(note->property("text") == c[0], S("the effort picker says \"%1\"").arg(note->property("text").toString()));
  });

  // An effort the model does not list (OpenCode's "default").
  step(S("the provider reports an effort the model does not list"), [](World& world, const Captures&, const Table&) {
    // As OpenCode reports "default" for a model it leaves to its own choice.
    QJsonArray list = providers(world);
    for (qsizetype i = 0; i < list.size(); ++i) {
      QJsonObject entry = list.at(i).toObject();
      if (entry.value(QLatin1String("instanceId")) != QLatin1String("codex")) continue;
      QJsonArray models = entry.value(QLatin1String("models")).toArray();
      for (qsizetype m = 0; m < models.size(); ++m) {
        QJsonObject model = models.at(m).toObject();
        QJsonObject capabilities = model.value(QLatin1String("capabilities")).toObject();
        QJsonArray descriptors = capabilities.value(QLatin1String("optionDescriptors")).toArray();
        for (qsizetype d = 0; d < descriptors.size(); ++d) {
          QJsonObject descriptor = descriptors.at(d).toObject();
          if (descriptor.value(QLatin1String("type")) == QLatin1String("select")) descriptor.insert(S("currentValue"), S("default"));
          descriptors.replace(d, descriptor);
        }
        capabilities.insert(S("optionDescriptors"), descriptors);
        model.insert(S("capabilities"), capabilities);
        models.replace(m, model);
      }
      entry.insert(S("models"), models);
      list.replace(i, entry);
    }
    publishProviders(world.mc, list);
    world.waitFor([&] { return effortValue(world) == QLatin1String("default"); },
                  [&] { return S("the composer to hold the provider's \"default\"; it shows %1").arg(show(effort(world))); });
  });
  step(S("the model's default effort is (low|medium|high)"), [](World& world, const Captures& c, const Table&) {
    for (const QVariant& choice : effort(world).value(S("choices")).toList()) {
      if (choice.toMap().value(S("isDefault")).toBool()) {
        expect(choice.toMap().value(S("id")) == c[0], S("the default effort is %1").arg(choice.toMap().value(S("id")).toString()));
        return;
      }
    }
    fail(S("the model marks no default effort: %1").arg(show(effort(world))));
  });

  // Something else owns the composer.
  step(S("an approval is waiting for the user"), [](World& world, const Captures&, const Table&) { awaitTurnApproval(world); });
  step(S("the agent's question is waiting for an answer"), [](World& world, const Captures&, const Table&) { awaitTurnQuestion(world); });
  step(S("the user is editing a queued message"), [](World& world, const Captures&, const Table&) {
    startWorkingTurn(world);
    queueTurnMessage(world, S("then the docs"));
    world.waitFor([&] { return !world.state(S("turn")).toMap().value(S("queue")).toList().isEmpty(); }, S("the message to wait in the queue"));
    world.bridge().dispatch(S("composer.queue.edit"), QVariantMap());
    world.waitFor([&] { return composer(world).value(S("text")) == QLatin1String("then the docs"); },
                  [&] { return S("the composer to edit the queued message; it shows %1").arg(show(composer(world))); });
  });
  step(S("no provider is available"), [](World& world, const Captures&, const Table&) {
    QJsonArray list = providers(world);
    for (qsizetype i = 0; i < list.size(); ++i) {
      QJsonObject entry = list.at(i).toObject();
      entry.insert(S("status"), S("error"));
      list.replace(i, entry);
    }
    publishProviders(world.mc, list);
    world.waitFor([&] { return composer(world).value(S("sendDisabledReason")) == QLatin1String("No provider available"); },
                  [&] { return S("no provider to be ready; the composer shows %1").arg(show(composer(world))); });
  });
  step(S("the user is holding the step key down after one step"), [](World& world, const Captures&, const Table&) {
    bindSteps(world);
    const QString before = effortValue(world);
    pressStep(world, kUp, false);
    world.waitFor([&] { return effortValue(world) != before; }, S("the first step to change the effort"));
    world.mc.part<Stepping>().held = true;
  });
});

}  // namespace
