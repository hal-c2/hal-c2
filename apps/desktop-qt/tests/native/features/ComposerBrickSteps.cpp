// The composer brick on screen (ComposerBrick.h): what the user's keys and
// clicks do in the editor and its toolbar, against the scenario's shell
// (features/composer/drafting-and-sending.feature, editors-and-keys.feature,
// qt-scenarios.feature).

#include <QClipboard>
#include <QCoreApplication>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QPointer>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QQuickTextDocument>
#include <QTextBlock>
#include <QTextDocument>
#include <QTextLayout>
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
// a key a shortcut takes never reaches the editor here either. The room above
// it stands for the timeline, and the conversation's drop covers both, as
// DefaultLayout lays them out.
const QByteArray kComposerQml = R"(
import QtQuick
import HalC2.Bricks
import HalC2.Shell

Item {
    id: root
    objectName: "composerBrick"
    property int windowShortcuts: 0

    Composer {
        id: composerView
        objectName: "composer"
        takesDrops: false
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: implicitHeight
    }

    ConversationDrop {
        objectName: "conversationDrop"
        anchors.fill: parent
        composer: composerView
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

// What a step set the draft up with, for a later step to compare: its text,
// and the part of it selected.
struct SetUp {
  QString text;
  int start = 0;
  int length = 0;
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

  // Rich text: the draft's Markdown drawn as it reads.
  // Whether the editor draws the characters of `word` in bold.
  const auto drawnBold = [](World& world, const QString& word) {
    auto* quick = composerEditor(world)->property("textDocument").value<QQuickTextDocument*>();
    expect(quick && quick->textDocument(), QStringLiteral("the editor has no document"));
    const QString text = quick->textDocument()->toPlainText();
    const qsizetype at = text.indexOf(word);
    if (at < 0) return false;
    const QTextBlock block = quick->textDocument()->findBlock(int(at));
    int bold = 0;
    for (const QTextLayout::FormatRange& range : block.layout()->formats()) {
      if (range.format.fontWeight() < QFont::Bold) continue;
      for (int i = range.start; i < range.start + range.length; ++i) {
        const int position = block.position() + i;
        if (position >= at && position < at + word.size()) ++bold;
      }
    }
    return bold == word.size();
  };
  step(QStringLiteral("rich text editing is on and the draft shows %1 in bold").arg(q), [drawnBold](World& world, const Captures& c, const Table&) {
    expect(world.native().controller<SettingsController>()->setting(QStringLiteral("composerRichTextEnabled")).toBool(), QStringLiteral("rich text is off"));
    composerBrick(world);
    typeInComposer(world, QStringLiteral("**%1**").arg(c[0]));
    settleComposer(world);
    world.waitFor([&] { return drawnBold(world, c[0]); }, [&] { return QStringLiteral("\"%1\" to be drawn bold").arg(c[0]); });
    world.mc.part<Pressed>().text = c[0];
  });
  step(QStringLiteral("the user turns rich text editing off"), [drawnBold](World& world, const Captures&, const Table&) {
    // The General page's "Rich text composer" switch.
    world.native().controller<SettingsController>()->set(QStringLiteral("composerRichTextEnabled"), false);
    const QString word = world.mc.part<Pressed>().text;
    world.waitFor([&] { return !drawnBold(world, word); }, [&] { return QStringLiteral("\"%1\" to be drawn plain").arg(word); });
    expect(editorText(world) == QStringLiteral("**%1**").arg(word), QStringLiteral("the editor reads \"%1\"").arg(editorText(world)));
  });

  // Text put into the composer by something else (voice input, a plugin).
  step(QStringLiteral("the draft reads %1 with %1 selected").arg(q), [](World& world, const Captures& c, const Table&) {
    write(world, c[0], int(c[0].size()));
    const int start = int(c[0].indexOf(c[1]));
    QMetaObject::invokeMethod(composerEditor(world), "select", Q_ARG(int, start), Q_ARG(int, start + int(c[1].size())));
    expect(composerEditor(world)->property("selectedText") == c[1], QStringLiteral("the selection is \"%1\"").arg(composerEditor(world)->property("selectedText").toString()));
  });

  // The draft's right-click menu (TextEditMenu) and the paste keys.
  step(QStringLiteral("the user copied %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QGuiApplication::clipboard()->setText(c[0]);
    world.clipboard = c[0];
  });
  step(QStringLiteral("the user presses (\\S+) in the composer"), [](World& world, const Captures& c, const Table&) {
    expect(pressInComposer(world, c[0]), QStringLiteral("the composer did not take %1").arg(c[0]));
  });
  step(QStringLiteral("the user chooses %1 from the draft's right-click menu").arg(q), [](World& world, const Captures& c, const Table&) {
    chooseInDraftMenu(world, c[0]);
  });
  step(QStringLiteral("%1 is selected in the composer").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString selected = composerEditor(world)->property("selectedText").toString();
    expect(selected == c[0], QStringLiteral("the selection is \"%1\"").arg(selected));
  });
  step(QStringLiteral("the draft's right-click menu is open"), [](World& world, const Captures&, const Table&) {
    QObject* menu = composerItem(world)->findChild<QObject*>(QStringLiteral("editorMenu"));
    world.waitFor([&] { return menu && menu->property("opened").toBool(); }, QStringLiteral("the draft's menu to open"));
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

  // Recalling sent prompts.
  const auto sent = [](World& world, const QStringList& prompts) {
    openTurnThread(world);
    for (const QString& prompt : prompts) {
      const QString run = startRun(world, 60, QStringLiteral("completed"));
      set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run, {{QStringLiteral("text"), prompt}});
    }
  };
  step(QStringLiteral("the user sent %1 and then %1 in this thread").arg(q), [sent](World& world, const Captures& c, const Table&) {
    sent(world, {c[0], c[1]});
  });
  step(QStringLiteral("the user recalls the previous prompt twice"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    pressInComposer(world, QStringLiteral("Up"));
    pressInComposer(world, QStringLiteral("Up"));
  });
  step(QStringLiteral("the user moves forward again"), [](World& world, const Captures&, const Table&) { pressInComposer(world, QStringLiteral("Down")); });
  step(QStringLiteral("the composer is empty with keyboard focus"), [sent](World& world, const Captures&, const Table&) {
    // In a thread whose last prompt was "Run the tests".
    sent(world, {QStringLiteral("Run the tests")});
    composerBrick(world);
    expect(editorText(world).isEmpty() && composerEditor(world)->hasActiveFocus(), QStringLiteral("the editor reads \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("the shell is asked for the previous prompt"), [](World& world, const Captures&, const Table&) {
    // It answers with the thread's last prompt as the draft.
    expect(world.native().controller<ComposerController>()->draft(target(world)) == QLatin1String("Run the tests"),
           QStringLiteral("the shell's draft reads \"%1\"").arg(world.native().controller<ComposerController>()->draft(target(world))));
  });
  step(QStringLiteral("the shell recalls %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return shown(world).value(QStringLiteral("text")) == c[0]; }, [&] { return QStringLiteral("the shell to publish %1; it shows %2").arg(c[0], show(shown(world))); });
  });
  step(QStringLiteral("the composer contains %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return editorText(world) == c[0]; }, [&] { return QStringLiteral("the editor to read %1; it reads \"%2\"").arg(c[0], editorText(world)); });
  });
  step(QStringLiteral("the composer holds two lines with the caret on the second"), [sent](World& world, const Captures&, const Table&) {
    sent(world, {QStringLiteral("Run the tests")});
    const QString text = QStringLiteral("line one\nline two");
    write(world, text, int(text.size()));
  });
  step(QStringLiteral("the shell is not asked for the previous prompt"), [](World& world, const Captures&, const Table&) {
    settleComposer(world);
    // Up moved the caret onto the first line and left the draft alone.
    expect(editorText(world) == QLatin1String("line one\nline two") && cursor(world) <= 8,
           QStringLiteral("the draft reads \"%1\" with the caret at %2").arg(editorText(world)).arg(cursor(world)));
  });

  // The message limit.
  step(QStringLiteral("the user has typed a prompt (\\d+) characters over the 120,000-character limit"), [](World& world, const Captures& c, const Table&) {
    const QString text(120000 + c[0].toInt(), QLatin1Char('x'));
    world.bridge().dispatch(QStringLiteral("composer.text.set"),
                            QVariantMap{{QStringLiteral("target"), target(world)}, {QStringLiteral("text"), text}, {QStringLiteral("cursor"), text.size()}});
  });
  step(QStringLiteral("the message is not sent"), [](World& world, const Captures&, const Table&) {
    expect(messages(world).isEmpty(), QStringLiteral("the MC has %1 commands").arg(world.mc.commands.size()));
    expect(!world.native().controller<ComposerController>()->draft(target(world)).isEmpty(), QStringLiteral("the draft was cleared"));
  });
  step(QStringLiteral("the user is told the prompt is (\\d+) characters over the limit and to shorten or split it"), [](World& world, const Captures& c, const Table&) {
    const QString expected = QStringLiteral("Prompt is %1 characters over the 120,000-character limit. Shorten or split it before sending.").arg(c[0]);
    const QVariantList toasts = world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
    expect(std::any_of(toasts.cbegin(), toasts.cend(), [&](const QVariant& toast) { return toast.toMap().value(QStringLiteral("description")) == expected; }),
           QStringLiteral("the toasts are %1").arg(show(toasts)));
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
  step(QStringLiteral("%1 is sent").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject> list = messages(world);
    expect(list.size() == 1 && list.first().value(QLatin1String("text")) == c[0], QStringLiteral("the MC has %1").arg(world.describeCommands()));
  });
  step(QStringLiteral("the window is narrowed to the width of a phone"), [](World& world, const Captures&, const Table&) {
    Brick& brick = composerBrick(world);
    brick.window().resize(390, 700);
    brick.root()->setSize(QSizeF(390, 700));
    world.waitFor([&] { return composerItem(world)->width() <= 390; }, QStringLiteral("the composer to narrow"));
  });

  // More of recalling sent prompts, and what is never recalled.
  step(QStringLiteral("the user sent %1 in this thread").arg(q), [sent](World& world, const Captures& c, const Table&) {
    sent(world, {c[0]});
    composerBrick(world);
  });
  step(QStringLiteral("the user sent %1, then %1 and then %1 in this thread").arg(q), [sent](World& world, const Captures& c, const Table&) {
    sent(world, {c[0], c[1], c[2]});
  });
  step(QStringLiteral("the user then sent %1").arg(q), [sent](World& world, const Captures& c, const Table&) { sent(world, {c[0]}); });
  step(QStringLiteral("a scheduled task then sent %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString run = startRun(world, 60, QStringLiteral("completed"));
    set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run,
        {{QStringLiteral("text"), c[0]}, {QStringLiteral("scheduledTaskId"), QStringLiteral("task-nightly")}});
  });
  // How each extra reaches the MC: in the text after the words typed.
  const QHash<QString, QString> extras{
      {QStringLiteral("Ultrathink turned on"), QStringLiteral("Ultrathink:\n%1")},
      {QStringLiteral("a comment on a file"), QStringLiteral("%1\n\n[cart.ts:12](hal-c2-context://v1/review-comment/comment-1)")},
      {QStringLiteral("a terminal excerpt added at the end"), QStringLiteral("%1\n\n[Terminal 1 lines 3-9](hal-c2-context://v1/terminal/excerpt-1)")},
      {QStringLiteral("a preview annotation"), QStringLiteral("%1 [Preview: Checkout button](hal-c2-context://v1/preview-annotation/note-1)")}};
  step(QStringLiteral("the user sent %1 with (Ultrathink turned on|a comment on a file|a terminal excerpt added at the end|a preview annotation)").arg(q),
       [sent, extras](World& world, const Captures& c, const Table&) { sent(world, {extras.value(c[1]).arg(c[0])}); });
  step(QStringLiteral("the user sent %1 and then (an image with no text|the request to implement a proposed plan)").arg(q),
       [sent](World& world, const Captures& c, const Table&) {
         sent(world, {c[0], c[1].startsWith(QLatin1String("an image")) ? QString() : QStringLiteral("PLEASE IMPLEMENT THIS PLAN:\n# Tax line\n\nAdd it.")});
       });
  // An older MC or a T3 import: the task is in the item's id and the text's prefix, and the sender is "user".
  step(QStringLiteral("the user sent %1 and then a scheduled task's message an older MC marked by its id").arg(q),
       [sent](World& world, const Captures& c, const Table&) {
         sent(world, {c[0]});
         const QString run = startRun(world, 60, QStringLiteral("completed"));
         set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run, {{QStringLiteral("text"), QString()}});
         set(world, QStringLiteral("turn-item"), QStringLiteral("scheduled-task-message:task-nightly:1:scheduled"),
             {{QStringLiteral("type"), QStringLiteral("user_message")},
              {QStringLiteral("runId"), run},
              {QStringLiteral("createdBy"), QStringLiteral("user")},
              {QStringLiteral("text"), QStringLiteral("[Triggered by schedule task: Nightly]\n\nRun the nightly check")}});
       });
  step(QStringLiteral("the user recalls the previous prompt"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    pressInComposer(world, QStringLiteral("Up"));
  });
  step(QStringLiteral("the user recalled %1(?: in thread A)?").arg(q), [](World& world, const Captures& c, const Table&) {
    composerBrick(world);
    for (int i = 0; i < 8 && editorText(world) != c[0]; ++i) pressInComposer(world, QStringLiteral("Up"));
    expect(editorText(world) == c[0], QStringLiteral("Up recalled \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("the user changes the draft to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    write(world, c[0], int(c[0].size()));
  });
  step(QStringLiteral("the user presses (Up|Down) on the (?:first|last) line of the composer"), [](World& world, const Captures& c, const Table&) {
    composerBrick(world);
    pressInComposer(world, c[0]);
  });
  step(QStringLiteral("the caret moves to the start of the draft"), [](World& world, const Captures&, const Table&) {
    expect(cursor(world) == 0, QStringLiteral("the caret is at %1").arg(cursor(world)));
  });
  step(QStringLiteral("the user recalled a prompt long enough to wrap onto three lines"), [sent](World& world, const Captures&, const Table&) {
    QQuickItem* editor = composerEditor(world);
    // Words until the editor wraps them onto a third line.
    QString prompt = QStringLiteral("totals");
    for (int words = 1; words < 1000; ++words) {
      editor->setProperty("text", prompt);
      world.sync();
      if (editor->property("lineCount").toInt() >= 3) break;
      prompt += QStringLiteral(" totals");
    }
    editor->setProperty("text", QString());
    settleComposer(world);
    sent(world, {prompt});
    pressInComposer(world, QStringLiteral("Up"));
    world.waitFor([&] { return editorText(world) == prompt && editor->property("lineCount").toInt() == 3; },
                  [&] {
                    return QStringLiteral("the editor reads \"%1\" on %2 lines").arg(editorText(world)).arg(editor->property("lineCount").toInt());
                  });
    world.mc.part<SetUp>().text = prompt;
  });
  step(QStringLiteral("the caret is on the last line"), [](World& world, const Captures&, const Table&) {
    composerEditor(world)->setProperty("cursorPosition", int(editorText(world).size()));
  });
  const auto caretY = [](World& world, int position) {
    QRectF rect;
    QMetaObject::invokeMethod(composerEditor(world), "positionToRectangle", Q_RETURN_ARG(QRectF, rect), Q_ARG(int, position));
    return rect.y();
  };
  step(QStringLiteral("the caret moves up one line"), [caretY](World& world, const Captures&, const Table&) {
    const qreal was = caretY(world, world.mc.part<Pressed>().cursor);
    const qreal now = caretY(world, cursor(world));
    expect(now < was && now > caretY(world, 0), QStringLiteral("the caret went from y %1 to %2").arg(was).arg(now));
  });
  step(QStringLiteral("the draft still reads that prompt"), [](World& world, const Captures&, const Table&) {
    settleComposer(world);
    const QString prompt = world.mc.part<SetUp>().text;
    expect(world.native().controller<ComposerController>()->draft(target(world)) == prompt, QStringLiteral("the draft reads \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("the user sent %1 in thread A and %1 in thread B").arg(q), [sent](World& world, const Captures& c, const Table&) {
    sent(world, {c[0]});
    otherThread(world);
    // Thread B's own stream, while the user is still in thread A.
    FakeStreams& fake = world.mc.part<FakeStreams>();
    const QString was = std::exchange(fake.thread, QStringLiteral("thread-2"));
    const QString at = iso(now().addSecs(-60));
    set(world, QStringLiteral("run"), QStringLiteral("run-b"),
        {{QStringLiteral("id"), QStringLiteral("run-b")}, {QStringLiteral("ordinal"), 1}, {QStringLiteral("status"), QStringLiteral("completed")},
         {QStringLiteral("requestedAt"), at}, {QStringLiteral("startedAt"), at}});
    set(world, QStringLiteral("turn-item"), QStringLiteral("message:run-b"),
        {{QStringLiteral("id"), QStringLiteral("message:run-b")}, {QStringLiteral("type"), QStringLiteral("user_message")},
         {QStringLiteral("runId"), QStringLiteral("run-b")}, {QStringLiteral("ordinal"), 2}, {QStringLiteral("status"), QStringLiteral("completed")},
         {QStringLiteral("text"), c[1]}, {QStringLiteral("updatedAt"), at}});
    fake.thread = was;
  });
  step(QStringLiteral("the user opens thread B and recalls the previous prompt"), [](World& world, const Captures&, const Table&) {
    look(world, otherThread(world));
    world.sync();
    settleComposer(world);
    pressInComposer(world, QStringLiteral("Up"));
  });

  // Keys the composer does not send with.
  step(QStringLiteral("the user presses Enter (to accept a word from their input method|and holds it so the key repeats)"),
       [](World& world, const Captures& c, const Table&) {
         Brick& brick = composerBrick(world);
         if (c[0].startsWith(QLatin1String("to accept"))) {
           // The input method is still composing the word Enter accepts.
           QInputMethodEvent composing(QStringLiteral("ね"), {QInputMethodEvent::Attribute(QInputMethodEvent::Cursor, 1, 1, QVariant())});
           QCoreApplication::sendEvent(composerEditor(world), &composing);
           pressInComposer(world, QStringLiteral("Enter"));
         } else {
           // Only the repeats: the first press has been and gone.
           for (int i = 0; i < 3; ++i) {
             QKeyEvent repeat(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r"), true);
             QCoreApplication::sendEvent(&brick.window(), &repeat);
           }
           QKeyEvent release(QEvent::KeyRelease, Qt::Key_Return, Qt::NoModifier, QStringLiteral("\r"));
           QCoreApplication::sendEvent(&brick.window(), &release);
           world.sync();
         }
       });

  // Lists: a new line in an item starts the next one.
  step(QStringLiteral("the draft's last line (?:reads|is) %1(?: with the caret at its end)?").arg(q), [](World& world, const Captures& c, const Table&) {
    write(world, c[0], int(c[0].size()));
  });
  step(QStringLiteral("the draft's last line is a bullet indented by two spaces"), [](World& world, const Captures&, const Table&) {
    write(world, QStringLiteral("- milk\n  - oat"), 14);
  });
  step(QStringLiteral("the draft's last line is a bullet with nothing after it"), [](World& world, const Captures&, const Table&) {
    write(world, QStringLiteral("- milk\n- "), 9);
  });
  step(QStringLiteral("a list item holds a file reference"), [](World& world, const Captures&, const Table&) {
    const QString text = QStringLiteral("- read [cart.ts](src/cart.ts) first");
    write(world, text, int(text.size()));
  });
  step(QStringLiteral("the draft reads %1 with the caret before %1").arg(q), [](World& world, const Captures& c, const Table&) {
    write(world, c[0], int(c[0].indexOf(c[1])));
  });
  step(QStringLiteral("the user (?:adds|starts) a new line"), [](World& world, const Captures&, const Table&) {
    expect(pressInComposer(world, QStringLiteral("Shift+Enter")), QStringLiteral("the composer did not take Shift+Enter"));
  });
  step(QStringLiteral("the user adds a new line with the caret inside the reference label"), [](World& world, const Captures&, const Table&) {
    // After "[cart", inside the label.
    composerEditor(world)->setProperty("cursorPosition", int(editorText(world).indexOf(QLatin1String("[cart")) + 5));
    expect(pressInComposer(world, QStringLiteral("Shift+Enter")), QStringLiteral("the composer did not take Shift+Enter"));
  });
  const auto lines = [](World& world) {
    settleComposer(world);
    return editorText(world).split(QLatin1Char('\n'));
  };
  step(QStringLiteral("the new line starts with %1").arg(q), [lines](World& world, const Captures& c, const Table&) {
    const QStringList now = lines(world);
    expect(now.size() == 2 && now.last() == c[0] + QLatin1Char(' ') && cursor(world) == editorText(world).size(),
           QStringLiteral("the draft reads \"%1\" with the caret at %2").arg(editorText(world)).arg(cursor(world)));
  });
  step(QStringLiteral("the new line is a bullet indented by two spaces"), [lines](World& world, const Captures&, const Table&) {
    expect(lines(world).last() == QLatin1String("  - "), QStringLiteral("the draft reads \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("that line is no longer a bullet"), [lines](World& world, const Captures&, const Table&) {
    expect(lines(world).last().isEmpty(), QStringLiteral("the draft reads \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("no new bullet is started"), [lines](World& world, const Captures&, const Table&) {
    expect(lines(world) == QStringList{QStringLiteral("- milk"), QString()}, QStringLiteral("the draft reads \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("the draft reads %1 and then %1 on the next line").arg(q), [lines](World& world, const Captures& c, const Table&) {
    expect(lines(world) == QStringList{c[0], c[1]}, QStringLiteral("the draft reads \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("the file reference is whole on one of the two lines"), [lines](World& world, const Captures&, const Table&) {
    const QStringList now = lines(world);
    expect(now.size() == 2 && (now.first().contains(QLatin1String("[cart.ts](src/cart.ts)")) || now.last().contains(QLatin1String("[cart.ts](src/cart.ts)"))),
           QStringLiteral("the draft reads \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("the line %1 is kept and a new line starts below it").arg(q), [lines](World& world, const Captures& c, const Table&) {
    expect(lines(world) == QStringList{c[0], QString()}, QStringLiteral("the draft reads \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("no suggestion list is open"), [](World& world, const Captures&, const Table&) {
    expect(!composerItem(world)->property("suggesting").toBool(), QStringLiteral("a suggestion list is open"));
  });
  step(QStringLiteral("that line is indented by two spaces"), [](World& world, const Captures&, const Table&) {
    settleComposer(world);
    const QString was = world.mc.part<Pressed>().text;
    expect(editorText(world) == QStringLiteral("  ") + was, QStringLiteral("the draft reads \"%1\"").arg(editorText(world)));
  });

  // Typing over a selection, and with an input method.
  step(QStringLiteral("the user types (\\S)"), [](World& world, const Captures& c, const Table&) {
    typeInComposer(world, c[0]);
    settleComposer(world);
  });
  // The wrapped word is unquoted: one of the marks is a quote.
  step(QStringLiteral("the draft reads hello (\\S+)"), [](World& world, const Captures& c, const Table&) {
    settleComposer(world);
    const QString expected = QStringLiteral("hello ") + c[0];
    expect(editorText(world) == expected, QStringLiteral("the draft reads \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("%1 is still selected").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString selected = composerEditor(world)->property("selectedText").toString();
    expect(selected == c[0], QStringLiteral("the selection is \"%1\"").arg(selected));
  });
  step(QStringLiteral("the draft's selection covers (a file reference|text shown in bold)"), [](World& world, const Captures& c, const Table&) {
    const bool reference = c[0] == QLatin1String("a file reference");
    const QString text = reference ? QStringLiteral("see [cart.ts](src/cart.ts) now") : QStringLiteral("see **bold** now");
    const QString selected = reference ? QStringLiteral("[cart.ts](src/cart.ts)") : QStringLiteral("bold");
    write(world, text, int(text.size()));
    const int start = int(text.indexOf(selected));
    QMetaObject::invokeMethod(composerEditor(world), "select", Q_ARG(int, start), Q_ARG(int, start + int(selected.size())));
    world.mc.part<SetUp>() = {text, start, int(selected.size())};
  });
  step(QStringLiteral("the selection is replaced by %1").arg(q), [](World& world, const Captures& c, const Table&) {
    settleComposer(world);
    const SetUp& kept = world.mc.part<SetUp>();
    const QString expected = QString(kept.text).replace(kept.start, kept.length, c[0]);
    expect(editorText(world) == expected, QStringLiteral("the draft reads \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("the user types Compose, then (\\S), then (\\S)"), [](World& world, const Captures& c, const Table&) {
    static const QHash<QString, QString> composed{{QStringLiteral("\"o"), QStringLiteral("ö")}, {QStringLiteral("\"a"), QStringLiteral("ä")},
                                                  {QStringLiteral("'e"), QStringLiteral("é")}};
    expect(composed.contains(c[0] + c[1]), QStringLiteral("no Compose sequence for %1%2").arg(c[0], c[1]));
    QQuickItem* editor = composerEditor(world);
    editor->setProperty("cursorPosition", int(editorText(world).size()));
    // Compose shows the mark it is composing, then commits the letter.
    QInputMethodEvent composing(c[0], {QInputMethodEvent::Attribute(QInputMethodEvent::Cursor, 1, 1, QVariant())});
    QCoreApplication::sendEvent(editor, &composing);
    QInputMethodEvent commit;
    commit.setCommitString(composed.value(c[0] + c[1]));
    QCoreApplication::sendEvent(editor, &commit);
    settleComposer(world);
  });

  // Rich text.
  step(QStringLiteral("rich text editing is (on|off)"), [](World& world, const Captures& c, const Table&) {
    world.native().controller<SettingsController>()->set(QStringLiteral("composerRichTextEnabled"), c[0] == QLatin1String("on"));
    composerBrick(world);
  });
  step(QStringLiteral("nothing in it is italic"), [](World& world, const Captures&, const Table&) {
    auto* quick = composerEditor(world)->property("textDocument").value<QQuickTextDocument*>();
    expect(quick && quick->textDocument(), QStringLiteral("the editor has no document"));
    for (QTextBlock block = quick->textDocument()->begin(); block.isValid(); block = block.next()) {
      for (const QTextLayout::FormatRange& range : block.layout()->formats()) {
        expect(!range.format.fontItalic(), QStringLiteral("\"%1\" is italic").arg(block.text().mid(range.start, range.length)));
      }
    }
  });
  step(QStringLiteral("the draft reads %1 with a file reference").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString text = c[0] + QStringLiteral(" [cart.ts](src/cart.ts) ");
    write(world, text, int(text.size()));
    world.mc.part<SetUp>().text = text;
  });
  step(QStringLiteral("the user turns rich text editing on and then off again"), [](World& world, const Captures&, const Table&) {
    auto* settings = world.native().controller<SettingsController>();
    for (const bool on : {true, false}) {
      settings->set(QStringLiteral("composerRichTextEnabled"), on);
      world.sync();
      settleComposer(world);
    }
  });
  step(QStringLiteral("the draft reads the same text with the same file reference"), [](World& world, const Captures&, const Table&) {
    settleComposer(world);
    const QString kept = world.mc.part<SetUp>().text;
    const QString draft = world.native().controller<ComposerController>()->draft(target(world));
    expect(editorText(world) == kept && draft == kept, QStringLiteral("the editor reads \"%1\", the draft \"%2\"").arg(editorText(world), draft));
  });

  // Undo.
  step(QStringLiteral("the user typed, pasted, then typed more"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    typeInComposer(world, QStringLiteral("fix "));
    QGuiApplication::clipboard()->setText(QStringLiteral("the tax line"));
    world.clipboard = QStringLiteral("the tax line");
    expect(pressInComposer(world, QStringLiteral("Ctrl+V")), QStringLiteral("the composer did not take Ctrl+V"));
    typeInComposer(world, QStringLiteral(" today"));
    expect(editorText(world) == QLatin1String("fix the tax line today"), QStringLiteral("the editor reads \"%1\"").arg(editorText(world)));
  });
  step(QStringLiteral("the user undoes once"), [](World& world, const Captures&, const Table&) {
    expect(pressInComposer(world, QStringLiteral("Ctrl+Z")), QStringLiteral("the composer did not take Ctrl+Z"));
  });
  step(QStringLiteral("only the last action is undone"), [](World& world, const Captures&, const Table&) {
    settleComposer(world);
    expect(editorText(world) == QLatin1String("fix the tax line"), QStringLiteral("the editor reads \"%1\"").arg(editorText(world)));
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
  // A request that takes no typed text (an approval, fixed choices) has the editor off.
  const bool editable = !shown(world).value(QStringLiteral("editorDisabled")).toBool();
  world.waitFor([&] { return editor->isEnabled() == editable && editor->property("text") == shown(world).value(QStringLiteral("text")); },
                QStringLiteral("the composer to show the draft"));
  QMetaObject::invokeMethod(composerItem(world), "focusInput");
  expect(editor->hasActiveFocus() == editable, QStringLiteral("the composer's editor did not take the keyboard"));
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

QString textMenuItem(const QString& said) {
  static const QHash<QString, QString> names{{QStringLiteral("Cut"), QStringLiteral("cutText")},
                                             {QStringLiteral("Copy"), QStringLiteral("copyText")},
                                             {QStringLiteral("Paste"), QStringLiteral("pasteText")},
                                             {QStringLiteral("Select All"), QStringLiteral("selectAllText")}};
  if (!names.contains(said)) fail(QStringLiteral("a text's menu has no %1").arg(said));
  return names.value(said);
}

void chooseInTextMenu(World& world, Brick& brick, QObject* menu, const QString& said) {
  const QString name = textMenuItem(said);
  // An item takes clicks once the menu has finished opening.
  world.waitFor([&] { return menu->property("opened").toBool(); }, QStringLiteral("the text's menu to open"));
  QQuickItem* item = nullptr;
  for (int i = 0; i < menu->property("count").toInt() && !item; ++i) {
    QQuickItem* entry = nullptr;
    QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, entry), Q_ARG(int, i));
    if (entry && entry->objectName() == name) item = entry;
  }
  expect(item && item->isVisible() && item->isEnabled(), QStringLiteral("the text's menu offers no %1 to choose").arg(said));
  const QPointer<QObject> open = menu;
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item));
  // What it chose is done once the menu has gone; a reply's is destroyed.
  world.waitFor([&] { return !open || !open->property("visible").toBool(); }, QStringLiteral("the text's menu to close"));
}

void chooseInDraftMenu(World& world, const QString& said) {
  Brick& brick = composerBrick(world);
  QQuickItem* editor = composerEditor(world);
  QTest::mouseClick(&brick.window(), Qt::RightButton, Qt::NoModifier, brick.at(editor, 0.5, 0.5));
  QObject* menu = composerItem(world)->findChild<QObject*>(QStringLiteral("editorMenu"));
  expect(menu != nullptr, QStringLiteral("the composer has no editorMenu"));
  chooseInTextMenu(world, brick, menu, said);
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
      {QStringLiteral("tab"), Qt::Key_Tab},        {QStringLiteral("insert"), Qt::Key_Insert},
      {QStringLiteral("menu"), Qt::Key_Menu}};
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
