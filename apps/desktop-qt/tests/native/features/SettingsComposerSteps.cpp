// What General's composer rows change in the composer on screen
// (qml/HalC2/Bricks/Composer.qml, features/settings/general.feature): skills in
// the slash menu, Markdown drawn as it reads, and resting on scroll.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QQuickTextDocument>
#include <QTextBlock>
#include <QTextDocument>
#include <QTextLayout>

#include "Brick.h"
#include "ComposerBrick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "SettingsController.h"
#include "Turn.h"
#include "World.h"

namespace {

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

QVariantMap composer(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

// A provider with one skill, and a thread to write in.
void openThreadWithSkill(World& world) {
  publishProviders(world.mc, {QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")},
                                          {QStringLiteral("driver"), QStringLiteral("claudeAgent")},
                                          {QStringLiteral("displayName"), QStringLiteral("Claude")},
                                          {QStringLiteral("enabled"), true},
                                          {QStringLiteral("installed"), true},
                                          {QStringLiteral("status"), QStringLiteral("ready")},
                                          {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), QStringLiteral("sonnet")}, {QStringLiteral("name"), QStringLiteral("Sonnet")}}}},
                                          {QStringLiteral("skills"), QJsonArray{QJsonObject{{QStringLiteral("name"), QStringLiteral("review")},
                                                                                            {QStringLiteral("description"), QStringLiteral("Review the changes")},
                                                                                            {QStringLiteral("enabled"), true}}}}}});
  openTurnThread(world);
  composerBrick(world);
}

// What the menu lists after the user types `text`.
QStringList listedAfter(World& world, const QString& text) {
  QQuickItem* editor = composerEditor(world);
  QMetaObject::invokeMethod(editor, "clear");
  settleComposer(world);
  typeInComposer(world, text);
  settleComposer(world);
  QStringList labels;
  for (const QVariant& item : composer(world).value(QStringLiteral("suggestions")).toList()) {
    if (at(item, QStringLiteral("kind")) == QLatin1String("skill")) labels.append(at(item, QStringLiteral("label")).toString());
  }
  return labels;
}

// Whether the editor draws the characters of `word` in bold.
bool drawnBold(World& world, const QString& word) {
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
}

// The composer's height once the user scrolls the conversation of its thread, with the keyboard elsewhere.
struct Heights {
  double before = 0;
  double scrolled = 0;
  bool strip = false;
};
Heights scrollConversation(World& world) {
  openTurnThread(world);
  composerBrick(world);
  QQuickItem* item = composerItem(world);
  settleComposer(world);
  world.brick->grab();
  Heights heights;
  heights.before = item->implicitHeight();
  // The layout tells the composer (DefaultShell: CentreHost.conversationScrolled).
  item->setProperty("conversationScrolled", true);
  world.brick->grab();
  heights.scrolled = item->implicitHeight();
  return heights;
}

const QHash<QString, QString>& rows() {
  static const QHash<QString, QString> keys{{QStringLiteral("Show skills in slash menu"), QStringLiteral("showSkillsInSlashMenu")},
                                            {QStringLiteral("Rich text composer"), QStringLiteral("composerRichTextEnabled")},
                                            {QStringLiteral("Collapse composer on scroll"), QStringLiteral("composerCollapseOnScroll")}};
  return keys;
}

const Steps steps([] {
  step(QStringLiteral("the user turns \"(Show skills in slash menu|Rich text composer|Collapse composer on scroll)\" (on|off)"),
       [](World& world, const Captures& c, const Table&) {
         // What the General page's switch does (SettingsRow); the composer is what is on screen here.
         const QString key = rows().value(c[0]);
         const bool on = c[1] == QLatin1String("on");
         // From the other state, so the row is what makes the difference.
         settings(world)->set(key, !on);
         settings(world)->set(key, on);
         expect(settings(world)->setting(key) == QVariant(on), QStringLiteral("%1 is %2").arg(key, show(settings(world)->setting(key))));
       });

  step(QStringLiteral("skills are listed in the slash command menu as well as after a dollar sign"), [](World& world, const Captures&, const Table&) {
    openThreadWithSkill(world);
    const QStringList slash = listedAfter(world, QStringLiteral("/"));
    const QStringList dollar = listedAfter(world, QStringLiteral("$"));
    expect(slash.size() == 1 && slash.first().contains(QLatin1String("review"), Qt::CaseInsensitive) && dollar.size() == 1, QStringLiteral("/ lists %1, $ lists %2").arg(slash.join(u", "), dollar.join(u", ")));
  });
  step(QStringLiteral("skills are only listed after a dollar sign"), [](World& world, const Captures&, const Table&) {
    openThreadWithSkill(world);
    const QStringList slash = listedAfter(world, QStringLiteral("/"));
    const QStringList dollar = listedAfter(world, QStringLiteral("$"));
    expect(slash.isEmpty() && dollar.size() == 1, QStringLiteral("/ lists %1, $ lists %2").arg(slash.join(u", "), dollar.join(u", ")));
  });

  step(QStringLiteral("Markdown is shown formatted while typing"), [](World& world, const Captures&, const Table&) {
    openTurnThread(world);
    composerBrick(world);
    typeInComposer(world, QStringLiteral("**careful**"));
    settleComposer(world);
    world.waitFor([&] { return drawnBold(world, QStringLiteral("careful")); }, QStringLiteral("\"careful\" to be drawn bold"));
  });
  step(QStringLiteral("the composer shows plain text"), [](World& world, const Captures&, const Table&) {
    openTurnThread(world);
    composerBrick(world);
    typeInComposer(world, QStringLiteral("**careful**"));
    settleComposer(world);
    world.brick->grab();
    expect(!drawnBold(world, QStringLiteral("careful")) && composerEditor(world)->property("text") == QLatin1String("**careful**"),
           QStringLiteral("the editor reads \"%1\"").arg(composerEditor(world)->property("text").toString()));
  });

  step(QStringLiteral("the composer of an existing thread shrinks to one line while scrolling"), [](World& world, const Captures&, const Table&) {
    const Heights heights = scrollConversation(world);
    QQuickItem* item = composerItem(world);
    expect(item->property("resting").toBool() && heights.scrolled < heights.before - 20,
           QStringLiteral("the composer is %1 tall, %2 before scrolling").arg(heights.scrolled).arg(heights.before));
    // Typing brings it back.
    typeInComposer(world, QStringLiteral("a"));
    world.brick->grab();
    expect(!item->property("resting").toBool() && item->implicitHeight() >= heights.before, QStringLiteral("typing did not bring the composer back"));
  });
  step(QStringLiteral("the composer keeps its size while scrolling"), [](World& world, const Captures&, const Table&) {
    const Heights heights = scrollConversation(world);
    expect(!composerItem(world)->property("resting").toBool() && heights.scrolled == heights.before,
           QStringLiteral("the composer is %1 tall, %2 before scrolling").arg(heights.scrolled).arg(heights.before));
  });
});

}  // namespace
