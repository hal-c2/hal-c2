// The composer brick on screen (ComposerBrick.h): what the user's keys and
// clicks do in the editor and its toolbar, against the scenario's shell
// (features/composer/drafting-and-sending.feature, editors-and-keys.feature,
// qt-scenarios.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include "Brick.h"
#include "CommandPaletteController.h"
#include "ComposerBrick.h"
#include "ComposerController.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "Stream.h"
#include "Turn.h"
#include "World.h"

using namespace stream;

namespace {

// The composer under the window's shortcuts (ShellWindow's Instantiator), so
// a key a shortcut takes never reaches the editor here either.
const QByteArray kComposerQml = R"(
import QtQuick
import HalC2.Bricks
import HalC2.Shell

Item {
    id: root
    objectName: "composerBrick"
    property int windowShortcuts: 0

    Composer {
        objectName: "composer"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: implicitHeight
    }

    Instantiator {
        model: Keybindings.shortcuts

        delegate: Shortcut {
            required property var modelData

            sequence: modelData.sequence
            context: Qt.WindowShortcut
            enabled: modelData.chrome
            onActivated: {
                root.windowShortcuts += 1;
                Keybindings.press(modelData.sequence, { terminal: false, editable: true });
            }
        }
    }
}
)";

// What the last key press in the composer found there.
struct Pressed {
  QString text;
  qsizetype commands = 0;
  int cursor = 0;
};

QString target(World& world) {
  const auto route = world.native().controller<NavigationController>()->route();
  return route.kind == QLatin1String("draft") ? route.draftId : route.threadKey;
}

QVariantMap shown(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

QString editorText(World& world) {
  return composerEditor(world)->property("text").toString();
}

int cursor(World& world) {
  return composerEditor(world)->property("cursorPosition").toInt();
}

QQuickItem* find(QQuickItem* item, const QString& objectName) {
  if (item->objectName() == objectName) return item;
  for (QQuickItem* child : item->childItems()) {
    if (QQuickItem* found = find(child, objectName)) return found;
  }
  return nullptr;
}

QList<QJsonObject> messages(World& world) {
  world.sync();
  QList<QJsonObject> found;
  for (const QJsonObject& command : world.mc.commands) {
    if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) found.append(command);
  }
  return found;
}

void expectNothingSent(World& world) {
  settleComposer(world);
  expect(messages(world).isEmpty(), QStringLiteral("the MC has %1").arg(world.describeCommands()));
}

// The editor holds `text` with the caret at `at`, as typed.
void write(World& world, const QString& text, int at) {
  composerBrick(world);
  world.bridge().dispatch(QStringLiteral("composer.text.set"),
                          QVariantMap{{QStringLiteral("target"), target(world)}, {QStringLiteral("text"), text}, {QStringLiteral("cursor"), at}});
  world.waitFor([&] { return editorText(world) == text; }, [&] { return QStringLiteral("the editor to read \"%1\"; it reads \"%2\"").arg(text, editorText(world)); });
  composerEditor(world)->setProperty("cursorPosition", at);
  settleComposer(world);
}

QQuickItem* vim(World& world) {
  QQuickItem* keys = find(composerBrick(world).root(), QStringLiteral("vimKeys"));
  expect(keys != nullptr, QStringLiteral("the composer has no Vim keys"));
  return keys;
}

void turnOnVim(World& world, bool normal) {
  world.native().controller<SettingsController>()->set(QStringLiteral("composerVimKeys"), true);
  composerBrick(world);
  expect(vim(world)->property("vimEnabled").toBool(), QStringLiteral("the composer's Vim keys are off"));
  if (!normal) return;
  expect(pressInComposer(world, QStringLiteral("Escape")), QStringLiteral("the composer did not take Escape"));
  expect(!vim(world)->property("insertMode").toBool(), QStringLiteral("Escape left the editor in insert mode"));
}

QString otherThread(World& world) {
  const QString id = QStringLiteral("thread-2");
  if (!world.mc.threads.contains(id)) {
    world.mc.threads.insert(id, {{QStringLiteral("id"), id}, {QStringLiteral("title"), QStringLiteral("Other")}, {QStringLiteral("projectId"), kProject},
                                   {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    world.mc.sendRow(id, world.mc.threads.value(id));
    world.sync();
  }
  return world.mc.environmentId + QLatin1Char(':') + id;
}

const Steps steps([] {
  Brick::registerSingletons();
  const QString q = kQuoted;

  // Sending with Enter (drafting-and-sending.feature).
  step(QStringLiteral("the message %1 is sent to the agent").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject> sent = messages(world);
    expect(sent.size() == 1 && sent.first().value(QLatin1String("text")) == c[0] && sent.first().value(QLatin1String("threadId")) == kThread,
           QStringLiteral("the MC has %1").arg(world.describeCommands()));
    world.waitFor([&] { return editorText(world).isEmpty(); }, [&] { return QStringLiteral("the editor to empty; it reads \"%1\"").arg(editorText(world)); });
  });
  step(QStringLiteral("the user presses Shift\\+Enter and types %1").arg(q), [](World& world, const Captures& c, const Table&) {
    composerBrick(world);
    expect(pressInComposer(world, QStringLiteral("Shift+Enter")), QStringLiteral("the composer did not take the key"));
    typeInComposer(world, c[0]);
  });
  step(QStringLiteral("the draft holds two lines"), [](World& world, const Captures&, const Table&) {
    settleComposer(world);
    const QString text = world.native().controller<ComposerController>()->draft(target(world));
    expect(text == QLatin1String("first line\nsecond line") && editorText(world) == text, QStringLiteral("the draft reads \"%1\"").arg(text));
  });
  step(QStringLiteral("nothing (?:has been|is) sent"), [](World& world, const Captures&, const Table&) { expectNothingSent(world); });
  const QHash<QString, QString> shortcuts{{QStringLiteral("Enter"), QStringLiteral("enter")},
                                          {QStringLiteral("Mod+Enter for multiline prompts"), QStringLiteral("mod-enter-multiline")},
                                          {QStringLiteral("Mod+Enter"), QStringLiteral("mod-enter")}};
  step(QStringLiteral("the send shortcut setting is %1").arg(q), [shortcuts](World& world, const Captures& c, const Table&) {
    expect(shortcuts.contains(c[0]), QStringLiteral("no send shortcut setting is called %1").arg(c[0]));
    world.native().controller<SettingsController>()->set(QStringLiteral("sendShortcut"), shortcuts.value(c[0]));
    composerBrick(world);
  });
  step(QStringLiteral("the user has typed two lines"), [](World& world, const Captures&, const Table&) {
    const QString text = QStringLiteral("line one\nline two");
    write(world, text, int(text.size()));
  });
  step(QStringLiteral("the message is sent"), [](World& world, const Captures&, const Table&) {
    const Pressed& pressed = world.mc.part<Pressed>();
    const QList<QJsonObject> sent = messages(world);
    expect(sent.size() == 1 && !pressed.text.isEmpty() && sent.first().value(QLatin1String("text")) == pressed.text,
           QStringLiteral("the draft read \"%1\" and the MC has %2").arg(pressed.text, world.describeCommands()));
    world.waitFor([&] { return editorText(world).isEmpty(); }, [&] { return QStringLiteral("the editor to empty; it reads \"%1\"").arg(editorText(world)); });
  });
  step(QStringLiteral("a new line is added to the draft"), [](World& world, const Captures&, const Table&) {
    const Pressed& pressed = world.mc.part<Pressed>();
    settleComposer(world);
    const QString text = world.native().controller<ComposerController>()->draft(target(world));
    expect(text == pressed.text + QLatin1Char('\n') && editorText(world) == text, QStringLiteral("the draft reads \"%1\"").arg(text));
    expect(messages(world).isEmpty(), QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("a new thread starts with that message in the background"), [](World& world, const Captures&, const Table&) {
    const QString prompt = world.mc.part<Pressed>().text;
    expect(!prompt.isEmpty(), QStringLiteral("the draft was empty"));
    const auto launched = [&] {
      return std::any_of(world.mc.threads.cbegin(), world.mc.threads.cend(),
                         [&](const QJsonObject& row) { return row.value(QLatin1String("title")) == prompt; });
    };
    world.waitFor(launched, [&] { return QStringLiteral("the MC to launch \"%1\"").arg(prompt); });
    world.sync();
    // In the background: the window stays on the draft, emptied for the next prompt.
    const auto route = world.native().controller<NavigationController>()->route();
    expect(route.kind == QLatin1String("draft") && shown(world).value(QStringLiteral("text")).toString().isEmpty(),
           QStringLiteral("the route is %1 and the composer shows %2").arg(show(world.state(QStringLiteral("route"))), show(shown(world))));
  });
  step(QStringLiteral("no window shortcut takes the key instead"), [](World& world, const Captures&, const Table&) {
    const int taken = composerBrick(world).root()->property("windowShortcuts").toInt();
    expect(taken == 0, QStringLiteral("a window shortcut ran %1 times").arg(taken));
  });

  // Drafts and threads.
  step(QStringLiteral("the user has just typed %1 in thread A").arg(q), [](World& world, const Captures& c, const Table&) {
    composerBrick(world);
    typeInComposer(world, c[0]);
    expect(editorText(world) == c[0], QStringLiteral("the editor reads \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("the user switches to thread B before the draft is saved"), [](World& world, const Captures&, const Table&) {
    // The editor's text has not reached the shell yet.
    const QString threadA = target(world);
    expect(world.native().controller<ComposerController>()->draft(threadA).isEmpty(), QStringLiteral("the draft was saved already"));
    look(world, otherThread(world));
  });
  step(QStringLiteral("thread B's draft does not contain %1").arg(q), [](World& world, const Captures& c, const Table&) {
    settleComposer(world);
    const QString draft = world.native().controller<ComposerController>()->draft(otherThread(world));
    expect(target(world) == otherThread(world) && !draft.contains(c[0]) && !editorText(world).contains(c[0]),
           QStringLiteral("thread B's draft reads \"%1\" and its editor \"%2\"").arg(draft, editorText(world)));
  });

  // Vim keys (editors-and-keys.feature).
  step(QStringLiteral("Vim keys are on"), [](World& world, const Captures&, const Table&) { turnOnVim(world, false); });
  step(QStringLiteral("Vim keys are on and the editor is in normal mode"), [](World& world, const Captures&, const Table&) {
    turnOnVim(world, true);
  });
  step(QStringLiteral("the user turns on Vim keys in settings"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    expect(!vim(world)->property("vimEnabled").toBool(), QStringLiteral("Vim keys were on already"));
    // What the General page's switch does (SettingsRow).
    world.native().controller<SettingsController>()->set(QStringLiteral("composerVimKeys"), true);
  });
  step(QStringLiteral("the composer edits with Vim keys"), [](World& world, const Captures&, const Table&) {
    write(world, QStringLiteral("hello world"), 0);
    pressInComposer(world, QStringLiteral("Escape"));
    pressInComposer(world, QStringLiteral("w"));
    expect(editorText(world) == QLatin1String("hello world") && cursor(world) == 6,
           QStringLiteral("the draft reads \"%1\" with the cursor at %2").arg(editorText(world)).arg(cursor(world)));
  });
  step(QStringLiteral("typed letters move the cursor instead of inserting text"), [](World& world, const Captures&, const Table&) {
    const QString before = editorText(world);
    composerEditor(world)->setProperty("cursorPosition", 0);
    pressInComposer(world, QStringLiteral("l"));
    pressInComposer(world, QStringLiteral("l"));
    expect(editorText(world) == before && cursor(world) == 2,
           QStringLiteral("the draft reads \"%1\" with the cursor at %2").arg(editorText(world)).arg(cursor(world)));
  });
  step(QStringLiteral("the draft reads %1 with the cursor at the start").arg(q), [](World& world, const Captures& c, const Table&) {
    write(world, c[0], 0);
  });
  step(QStringLiteral("the cursor moves to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(cursor(world) == editorText(world).indexOf(c[0]) && cursor(world) > 0, QStringLiteral("the cursor is at %1").arg(cursor(world)));
  });
  step(QStringLiteral("the cursor moves to the end of the line"), [](World& world, const Captures&, const Table&) {
    expect(cursor(world) == editorText(world).size(), QStringLiteral("the cursor is at %1").arg(cursor(world)));
  });
  step(QStringLiteral("the user inserts at the end of the line"), [](World& world, const Captures&, const Table&) {
    expect(vim(world)->property("insertMode").toBool() && cursor(world) == editorText(world).size(),
           QStringLiteral("insert mode %1, the cursor at %2").arg(vim(world)->property("insertMode").toBool()).arg(cursor(world)));
    typeInComposer(world, QStringLiteral("!"));
    expect(editorText(world) == QLatin1String("hello world!"), QStringLiteral("the draft reads \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("the user switches to another thread"), [](World& world, const Captures&, const Table&) {
    look(world, otherThread(world));
    settleComposer(world);
  });
  step(QStringLiteral("typed letters insert text"), [](World& world, const Captures&, const Table&) {
    typeInComposer(world, QStringLiteral("hi"));
    expect(editorText(world) == QLatin1String("hi"), QStringLiteral("the draft reads \"%1\"").arg(editorText(world)));
  });

  // Text put into the composer by something else (voice input, a plugin).
  step(QStringLiteral("the draft reads %1 with %1 selected").arg(q), [](World& world, const Captures& c, const Table&) {
    write(world, c[0], int(c[0].size()));
    const int start = int(c[0].indexOf(c[1]));
    QMetaObject::invokeMethod(composerEditor(world), "select", Q_ARG(int, start), Q_ARG(int, start + int(c[1].size())));
    expect(composerEditor(world)->property("selectedText") == c[1], QStringLiteral("the selection is \"%1\"").arg(composerEditor(world)->property("selectedText").toString()));
  });
  const auto insert = [](World& world, const QString& text, const QString& into) {
    QVariant inserted;
    QMetaObject::invokeMethod(composerItem(world), "insertText", Q_RETURN_ARG(QVariant, inserted), Q_ARG(QVariant, text), Q_ARG(QVariant, into));
    return inserted.toBool();
  };
  step(QStringLiteral("text %1 is inserted into the composer").arg(q), [insert](World& world, const Captures& c, const Table&) {
    expect(insert(world, c[0], target(world)), QStringLiteral("the composer refused the text"));
    world.sync();
  });
  step(QStringLiteral("the user is writing in thread B"), [](World& world, const Captures&, const Table&) {
    world.mc.part<Pressed>().text = target(world);  // thread A
    look(world, otherThread(world));
    write(world, QStringLiteral("for thread B"), 12);
  });
  step(QStringLiteral("text meant for thread A arrives late"), [insert](World& world, const Captures&, const Table&) {
    expect(!insert(world, QStringLiteral("late transcript"), world.mc.part<Pressed>().text), QStringLiteral("the composer took the text"));
  });
  step(QStringLiteral("thread B's draft is unchanged"), [](World& world, const Captures&, const Table&) {
    settleComposer(world);
    const QString draft = world.native().controller<ComposerController>()->draft(otherThread(world));
    expect(draft == QLatin1String("for thread B") && editorText(world) == draft, QStringLiteral("thread B's draft reads \"%1\"").arg(draft));
  });

  // The shell's own scenarios (qt-scenarios.feature).
  step(QStringLiteral("the composer has the draft %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openTurnThread(world);
    write(world, c[0], int(c[0].size()));
  });
  step(QStringLiteral("%1 is sent in the foreground").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject> sent = messages(world);
    expect(sent.size() == 1 && sent.first().value(QLatin1String("text")) == c[0] &&
               sent.first().value(QLatin1String("dispatchMode")).toObject().value(QLatin1String("type")) == QLatin1String("start_immediately"),
           QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
});

}  // namespace

bool composerBrickShown(World& world) {
  return world.brick && world.brick->root() && world.brick->root()->objectName() == QLatin1String("composerBrick");
}

Brick& composerBrick(World& world) {
  if (composerBrickShown(world)) return *world.brick;
  expect(!world.state(QStringLiteral("composer")).toMap().isEmpty(), QStringLiteral("no thread or draft is open for the composer"));
  // The controllers' singletons (Keybindings), as main.cpp registers them.
  world.native().registerQmlSingletons();
  world.brick = std::make_unique<Brick>(world, kComposerQml, QSize(900, 700));
  Brick& brick = *world.brick;
  expect(QTest::qWaitForWindowActive(&brick.window()), QStringLiteral("the composer's window did not come up"));
  QQuickItem* editor = composerEditor(world);
  world.waitFor([&] { return editor->isEnabled() && editor->property("text") == shown(world).value(QStringLiteral("text")); },
                QStringLiteral("the composer to show the draft"));
  QMetaObject::invokeMethod(composerItem(world), "focusInput");
  expect(editor->hasActiveFocus(), QStringLiteral("the composer's editor did not take the keyboard"));
  return brick;
}

QQuickItem* composerItem(World& world) {
  return composerBrick(world).item(QStringLiteral("composer"));
}

QQuickItem* composerEditor(World& world) {
  return composerBrick(world).item(QStringLiteral("input"));
}

QQuickItem* composerPart(World& world, const QString& objectName) {
  return find(composerBrick(world).window().contentItem(), objectName);
}

void settleComposer(World& world) {
  if (!composerBrickShown(world)) {
    world.sync();
    return;
  }
  QMetaObject::invokeMethod(composerItem(world), "flushText");
  world.sync();
  world.waitFor([&] { return editorText(world) == shown(world).value(QStringLiteral("text")).toString(); },
                [&] { return QStringLiteral("the editor and the shell to agree; the editor reads \"%1\", the shell \"%2\"")
                                 .arg(editorText(world), shown(world).value(QStringLiteral("text")).toString()); });
}

void typeInComposer(World& world, const QString& text) {
  Brick& brick = composerBrick(world);
  for (const QChar ch : text) QTest::keyClick(&brick.window(), ch.toLatin1());
}

bool pressInComposer(World& world, const QString& key) {
  QStringList parts = key.split(QLatin1Char('+'));
  if (key == QLatin1String("+") || parts.last().isEmpty()) parts = {key};
  const QString name = parts.takeLast();
  const QString lower = name.toLower();
  const bool enter = lower == QLatin1String("enter") || lower == QLatin1String("return");
  if (!composerBrickShown(world)) {
    // The keyboard is in the composer of a thread or draft with a prompt
    // written: Enter is the composer's to take.
    auto* palette = world.native().controller<CommandPaletteController>();
    if (!enter || (palette && palette->isOpen()) || shown(world).value(QStringLiteral("text")).toString().isEmpty()) return false;
  }
  Brick& brick = composerBrick(world);
  Qt::KeyboardModifiers modifiers;
  for (const QString& part : parts) {
    const QString modifier = part.toLower();
    if (modifier == QLatin1String("mod") || modifier == QLatin1String("ctrl") || modifier == QLatin1String("cmd")) modifiers |= Qt::ControlModifier;
    else if (modifier == QLatin1String("shift")) modifiers |= Qt::ShiftModifier;
    else if (modifier == QLatin1String("alt")) modifiers |= Qt::AltModifier;
    else if (modifier == QLatin1String("meta")) modifiers |= Qt::MetaModifier;
    else fail(QStringLiteral("%1 is not a modifier").arg(part));
  }
  Pressed& pressed = world.mc.part<Pressed>();
  pressed.text = editorText(world);
  pressed.cursor = cursor(world);
  pressed.commands = world.mc.commands.size();
  static const QHash<QString, Qt::Key> named{
      {QStringLiteral("enter"), Qt::Key_Return}, {QStringLiteral("return"), Qt::Key_Return}, {QStringLiteral("escape"), Qt::Key_Escape},
      {QStringLiteral("esc"), Qt::Key_Escape},   {QStringLiteral("up"), Qt::Key_Up},         {QStringLiteral("down"), Qt::Key_Down},
      {QStringLiteral("left"), Qt::Key_Left},    {QStringLiteral("right"), Qt::Key_Right},   {QStringLiteral("backspace"), Qt::Key_Backspace},
      {QStringLiteral("tab"), Qt::Key_Tab}};
  if (lower == QLatin1String("tab") && (modifiers & Qt::ShiftModifier)) {
    QTest::keyClick(&brick.window(), Qt::Key_Backtab, modifiers);
  } else if (named.contains(lower)) {
    QTest::keyClick(&brick.window(), named.value(lower), modifiers);
  } else if (name.size() == 1) {
    QTest::keyClick(&brick.window(), name.at(0).toLatin1(), modifiers);
  } else {
    fail(QStringLiteral("%1 is not a key the composer steps know").arg(key));
  }
  world.sync();
  return true;
}
