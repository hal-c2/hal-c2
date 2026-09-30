// Formatted messages (features/timeline/markdown.feature) and bare web
// addresses (scrolling-and-links.feature) as the desktop draws them: the
// fake node's thread goes through the ThreadStore's TimelineModel into the
// Timeline brick, whose messages are Markdown bricks. Steps click what the
// user clicks and read back the segments the brick draws.

#include <QClipboard>
#include <QGuiApplication>
#include <QJsonObject>
#include <QPointer>
#include <QQuickItem>
#include <QRectF>
#include <QSignalSpy>
#include <QTest>

#include <memory>

#include "Brick.h"
#include "Harness.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

const QString kSource = QStringLiteral("const total = cart.lines.reduce((sum, line) => sum + line.price, 0);\nreturn roundToCent(total * (1 + rate));");
const QString kTable = QStringLiteral("| Region | Rate |\n|---|---:|\n| EU, north | 21% |\n| a\\|b | \"q\" |");

// What a step saw, for a later step to compare with.
struct Seen {
  QPointer<QQuickItem> item;
  std::shared_ptr<QSignalSpy> redraws;
  int segments = 0;
};

// Items named `name` under `item`, in the order they are drawn. From the
// window's content item this includes open menus, which live in its overlay.
void collect(QQuickItem* item, const QString& name, QList<QQuickItem*>& out) {
  if (item->objectName() == name) out.append(item);
  for (QQuickItem* child : item->childItems()) collect(child, name, out);
}

QList<QQuickItem*> named(QQuickItem* item, const QString& name) {
  QList<QQuickItem*> out;
  collect(item, name, out);
  return out;
}

bool isMarkdown(const QQuickItem* item) {
  return item->metaObject()->indexOfProperty("lineBreaks") >= 0 && item->metaObject()->indexOfProperty("segmentCount") >= 0;
}

// Items named `name` in one message, not in the messages a quote nests.
void collectOwn(QQuickItem* item, const QString& name, QList<QQuickItem*>& out) {
  if (item->objectName() == name) out.append(item);
  for (QQuickItem* child : item->childItems()) {
    if (!isMarkdown(child)) collectOwn(child, name, out);
  }
}

QList<QQuickItem*> within(QQuickItem* message, const QString& name) {
  QList<QQuickItem*> out;
  collectOwn(message, name, out);
  return out;
}

// The Markdown bricks the timeline shows: user messages keep their line
// breaks, agent replies do not.
void collectMarkdown(QQuickItem* item, QList<QQuickItem*>& out) {
  if (isMarkdown(item)) {
    out.append(item);
    return;
  }
  for (QQuickItem* child : item->childItems()) collectMarkdown(child, out);
}

QList<QQuickItem*> messages(World& world, bool user) {
  QList<QQuickItem*> all, out;
  collectMarkdown(world.brick->root(), all);
  for (QQuickItem* item : all) {
    if (item->property("lineBreaks").toBool() == user) out.append(item);
  }
  return out;
}

// The timeline of the open thread (Threads.timeline, as ThreadView shows
// it); it records the links the user activates.
Brick& timelineBrick(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world,
                                          "import QtQuick\nimport HalC2.Bricks\n"
                                          "Timeline { property var activated: []\n"
                                          "  onLinkActivated: link => activated = activated.concat([link]) }\n",
                                          QSize(820, 1400));
    world.brick->root()->setProperty("model", QVariant::fromValue(static_cast<QObject*>(&timeline(world))));
  }
  return *world.brick;
}

// The newest reply once it shows `segments` segments or more.
QQuickItem* reply(World& world, int segments = 1) {
  timelineBrick(world);
  QQuickItem* found = nullptr;
  world.waitFor([&] {
    const QList<QQuickItem*> replies = messages(world, false);
    found = replies.isEmpty() ? nullptr : replies.last();
    return found && found->property("segmentCount").toInt() >= segments;
  }, [&] { return QStringLiteral("a reply of %1 segments; %2").arg(segments).arg(describe(timeline(world))); });
  return found;
}

QQuickItem* one(QQuickItem* scope, const QString& name) {
  const QList<QQuickItem*> found = within(scope, name);
  expect(found.size() == 1, QStringLiteral("%1 %2 are shown").arg(found.size()).arg(name));
  return found.first();
}

QString plain(QQuickItem* edit) {
  QString text;
  QMetaObject::invokeMethod(edit, "getText", Q_RETURN_ARG(QString, text), Q_ARG(int, 0), Q_ARG(int, edit->property("length").toInt()));
  // Rich text reports a line break as a line separator.
  return text.replace(QChar(0x2028), QLatin1Char('\n'));
}

// The link under the middle of `needle` in a rich text segment, and the point
// the user would click in the window.
QString linkAt(QQuickItem* edit, const QString& needle, QPoint* point = nullptr) {
  const int at = plain(edit).indexOf(needle);
  expect(at >= 0, QStringLiteral("\"%1\" is not shown in \"%2\"").arg(needle, plain(edit)));
  QRectF rect;
  QMetaObject::invokeMethod(edit, "positionToRectangle", Q_RETURN_ARG(QRectF, rect), Q_ARG(int, at + int(needle.size() / 2)));
  const QPointF local(rect.x() + 1, rect.y() + rect.height() / 2);
  QString link;
  QMetaObject::invokeMethod(edit, "linkAt", Q_RETURN_ARG(QString, link), Q_ARG(qreal, local.x()), Q_ARG(qreal, local.y()));
  if (point) *point = edit->mapToScene(local).toPoint();
  return link;
}

QStringList kindsOf(QQuickItem* message) {
  QStringList kinds;
  for (QQuickItem* segment : within(message, QStringLiteral("markdownSegment"))) kinds.append(segment->property("kind").toString());
  return kinds;
}

void click(World& world, QQuickItem* item) {
  Brick& brick = timelineBrick(world);
  expect(item->isVisible() && item->isEnabled(), QStringLiteral("%1 cannot be clicked").arg(item->objectName()));
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(item));
}

// A finished reply of the current thread.
void answer(World& world, const QString& text) {
  startRun(world, 30);
  addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), text}});
  settleRun(world, QStringLiteral("completed"), 30);
}

// A reply the agent is still writing, and more of it.
void startWriting(World& world, const QString& text) {
  startRun(world, 30);
  addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("id"), QStringLiteral("reply")}, {QStringLiteral("streaming"), true}, {QStringLiteral("text"), text}});
}

void write(World& world, const QString& more) {
  change(world, QStringLiteral("turn-item"), QStringLiteral("reply"), {{QStringLiteral("a"), QJsonObject{{QStringLiteral("text"), more}}}});
}

QString clipboard() {
  return QGuiApplication::clipboard()->text();
}

const Steps steps([] {
  const QString q = kQuoted;

  // Formatting.
  step(QStringLiteral("the agent answers with a heading, a list, a quote, a code block and a table"), [](World& world, const Captures&, const Table&) {
    answer(world, QStringLiteral("# Cart totals\n\n- Discounts first\n- Tax second\n\n> Old carts keep their totals.\n\n```ts\n") + kSource +
                      QStringLiteral("\n```\n\n") + kTable);
  });
  step(QStringLiteral("the heading and the list are shown as text"), [](World& world, const Captures&, const Table&) {
    const QString text = plain(within(reply(world, 4), QStringLiteral("markdownProse")).first());
    expect(text.contains(QLatin1String("Cart totals")) && text.contains(QLatin1String("Tax second")) && !text.contains(QLatin1Char('#')),
           QStringLiteral("the reply reads \"%1\"").arg(text));
  });
  step(QStringLiteral("the quote, the code block and the table are each shown in their own form"), [](World& world, const Captures&, const Table&) {
    QQuickItem* message = reply(world, 4);
    const QStringList kinds = kindsOf(message);
    expect(kinds == QStringList({QStringLiteral("prose"), QStringLiteral("quote"), QStringLiteral("code"), QStringLiteral("table")}),
           QStringLiteral("the reply is drawn as %1").arg(kinds.join(QStringLiteral(", "))));
    expect(plain(one(message, QStringLiteral("codeText"))) == kSource, QStringLiteral("the code block reads \"%1\"").arg(plain(one(message, QStringLiteral("codeText")))));
    expect(one(message, QStringLiteral("codeLabel"))->property("text").toString() == QLatin1String("ts"), QStringLiteral("the code block is not labelled ts"));
    expect(within(message, QStringLiteral("tableCell")).size() == 6, QStringLiteral("the table has %1 cells").arg(within(message, QStringLiteral("tableCell")).size()));
  });

  // Code blocks.
  step(QStringLiteral("the agent's reply has a code block"), [](World& world, const Captures&, const Table&) {
    answer(world, QStringLiteral("Here it is:\n\n```ts\n") + kSource + QStringLiteral("\n```"));
  });
  step(QStringLiteral("the user copies the code block"), [](World& world, const Captures&, const Table&) {
    QGuiApplication::clipboard()->clear();
    click(world, one(reply(world, 2), QStringLiteral("copyCode")));
  });
  step(QStringLiteral("the code block's source is on the clipboard"), [](World&, const Captures&, const Table&) {
    expect(clipboard() == kSource, QStringLiteral("the clipboard holds \"%1\"").arg(clipboard()));
  });
  step(QStringLiteral("the code block shows it was copied"), [](World& world, const Captures&, const Table&) {
    QQuickItem* button = one(reply(world, 2), QStringLiteral("copyCode"));
    expect(button->property("iconName").toString() == QLatin1String("check") && button->property("label").toString() == QLatin1String("Copied"),
           QStringLiteral("the copy button shows %1").arg(button->property("iconName").toString()));
    world.waitFor([&] { return button->property("iconName").toString() == QLatin1String("copy"); }, QStringLiteral("the copy button to come back"));
  });

  step(QStringLiteral("the agent's reply has a code block with a long line"), [](World& world, const Captures&, const Table&) {
    answer(world, QStringLiteral("```\n") + QStringLiteral("word ").repeated(80) + QStringLiteral("\n```"));
  });
  step(QStringLiteral("the user turns line wrap (off|on) for the code block"), [](World& world, const Captures& c, const Table&) {
    QQuickItem* toggle = one(reply(world), QStringLiteral("wrapCode"));
    const bool on = c[0] == QLatin1String("on");
    expect(toggle->property("checked").toBool() != on, QStringLiteral("line wrap is already %1").arg(c[0]));
    click(world, toggle);
    expect(toggle->property("checked").toBool() == on, QStringLiteral("line wrap did not turn %1").arg(c[0]));
  });
  step(QStringLiteral("the long line (scrolls sideways|wraps)"), [](World& world, const Captures& c, const Table&) {
    QQuickItem* message = reply(world);
    QQuickItem* code = one(message, QStringLiteral("codeText"));
    QQuickItem* block = one(message, QStringLiteral("markdownCode"));
    const int lines = code->property("lineCount").toInt();
    if (c[0] == QLatin1String("wraps")) {
      expect(lines > 1 && code->width() <= block->width(), QStringLiteral("the line is %1 wide in %2 lines").arg(code->width()).arg(lines));
    } else {
      expect(lines == 1 && code->width() > block->width(), QStringLiteral("the line is %1 wide in %2 lines").arg(code->width()).arg(lines));
    }
  });

  // Tables.
  step(QStringLiteral("the agent's reply has a table"), [](World& world, const Captures&, const Table&) {
    answer(world, kTable);
  });
  step(QStringLiteral("the user copies the table as (Markdown|CSV)"), [](World& world, const Captures& c, const Table&) {
    QGuiApplication::clipboard()->clear();
    click(world, one(reply(world), QStringLiteral("copyTable")));
    const QString name = c[0] == QLatin1String("CSV") ? QStringLiteral("copyTableCsv") : QStringLiteral("copyTableMarkdown");
    QQuickItem* content = timelineBrick(world).window().contentItem();
    world.waitFor([&] { return named(content, name).size() == 1 && named(content, name).first()->isVisible(); },
                  QStringLiteral("the copy menu to offer %1").arg(c[0]));
    click(world, named(content, name).first());
  });
  step(QStringLiteral("the table is on the clipboard as (Markdown|CSV)"), [](World&, const Captures& c, const Table&) {
    const QString expected = c[0] == QLatin1String("CSV")
                                 ? QStringLiteral("Region,Rate\n\"EU, north\",21%\na|b,\"\"\"q\"\"\"")
                                 : QStringLiteral("| Region | Rate |\n| --- | ---: |\n| EU, north | 21% |\n| a\\|b | \"q\" |");
    expect(clipboard() == expected, QStringLiteral("the clipboard holds \"%1\"").arg(clipboard()));
  });

  step(QStringLiteral("the agent's reply has a table with a long cell"), [](World& world, const Captures&, const Table&) {
    answer(world, QStringLiteral("| Region | Rounding |\n|---|---|\n| EU | ") + QStringLiteral("per line, then once more ").repeated(8) + QStringLiteral("|"));
  });
  step(QStringLiteral("the user (collapses|expands) the table cells"), [](World& world, const Captures& c, const Table&) {
    QQuickItem* toggle = one(reply(world), QStringLiteral("expandTable"));
    const bool expand = c[0] == QLatin1String("expands");
    expect(toggle->property("checked").toBool() != expand, QStringLiteral("the table cells are already %1").arg(expand ? "expanded" : "collapsed"));
    click(world, toggle);
  });
  step(QStringLiteral("the long cell (stays on one line|wraps)"), [](World& world, const Captures& c, const Table&) {
    QQuickItem* cell = within(reply(world), QStringLiteral("tableCell")).last();
    const int lines = cell->property("lineCount").toInt();
    const bool wraps = c[0] == QLatin1String("wraps");
    expect(wraps ? lines > 1 : lines == 1, QStringLiteral("the long cell takes %1 lines").arg(lines));
  });

  // Untrusted text.
  step(QStringLiteral("the agent answers with HTML and an image"), [](World& world, const Captures&, const Table&) {
    answer(world, QStringLiteral("<script>alert(1)</script> <b>bold?</b> <img src=\"https://example.com/x.png\">\n\n![pic](https://example.com/y.png)"));
  });
  step(QStringLiteral("the HTML is shown as written"), [](World& world, const Captures&, const Table&) {
    const QString text = plain(one(reply(world), QStringLiteral("markdownProse")));
    expect(text.contains(QLatin1String("<script>alert(1)</script>")) && text.contains(QLatin1String("<b>bold?</b>")) &&
               text.contains(QLatin1String("<img src=\"https://example.com/x.png\">")),
           QStringLiteral("the reply reads \"%1\"").arg(text));
  });
  step(QStringLiteral("the image is a link to its address and nothing is loaded from the web"), [](World& world, const Captures&, const Table&) {
    QQuickItem* edit = one(reply(world), QStringLiteral("markdownProse"));
    expect(!edit->property("text").toString().contains(QLatin1String("<img")), QStringLiteral("the reply draws an image"));
    const QString link = linkAt(edit, QStringLiteral("pic"));
    expect(link == QLatin1String("https://example.com/y.png"), QStringLiteral("the image links to \"%1\"").arg(link));
  });
  step(QStringLiteral("the agent answers with a link to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    answer(world, QStringLiteral("Open [the pricing docs](%1) now.").arg(c[0]));
  });
  step(QStringLiteral("the link's text is shown and nothing can be opened"), [](World& world, const Captures&, const Table&) {
    QQuickItem* edit = one(reply(world), QStringLiteral("markdownProse"));
    QPoint point;
    const QString link = linkAt(edit, QStringLiteral("pricing docs"), &point);
    expect(link.isEmpty(), QStringLiteral("\"the pricing docs\" links to \"%1\"").arg(link));
    expect(!edit->property("text").toString().contains(QLatin1String("javascript:")), QStringLiteral("the reply carries the script"));
    QTest::mouseClick(&timelineBrick(world).window(), Qt::LeftButton, Qt::NoModifier, point);
    const QVariantList activated = world.brick->root()->property("activated").toList();
    expect(activated.isEmpty(), QStringLiteral("the click opened %1").arg(show(activated)));
  });

  // A reply being written.
  step(QStringLiteral("the agent is writing a reply of several paragraphs"), [](World& world, const Captures&, const Table&) {
    startWriting(world, QStringLiteral("Discounts apply first.\n\nTax rounds to the cent."));
    QQuickItem* message = reply(world, 2);
    Seen& seen = world.node.part<Seen>();
    seen.item = within(message, QStringLiteral("markdownProse")).first();
    seen.redraws = std::make_shared<QSignalSpy>(seen.item.data(), SIGNAL(textChanged()));
    seen.segments = message->property("segmentCount").toInt();
  });
  step(QStringLiteral("the reply grows by another paragraph"), [](World& world, const Captures&, const Table&) {
    write(world, QStringLiteral(" Per line for VAT."));
    write(world, QStringLiteral("\n\nTotals are cached"));
    write(world, QStringLiteral(" until the cart changes."));
  });
  step(QStringLiteral("the paragraphs already shown are not drawn again"), [](World& world, const Captures&, const Table&) {
    const Seen& seen = world.node.part<Seen>();
    QQuickItem* message = reply(world, seen.segments + 1);
    const QString last = plain(within(message, QStringLiteral("markdownProse")).last());
    expect(last.contains(QLatin1String("until the cart changes.")), QStringLiteral("the reply ends \"%1\"").arg(last));
    expect(seen.item && within(message, QStringLiteral("markdownProse")).first() == seen.item.data(), QStringLiteral("the first paragraph was drawn anew"));
    expect(seen.redraws->isEmpty(), QStringLiteral("the first paragraph was redrawn %1 times").arg(seen.redraws->size()));
  });

  step(QStringLiteral("the agent is writing a code block"), [](World& world, const Captures&, const Table&) {
    startWriting(world, QStringLiteral("Checking the refund path:\n\n```py\ndef refund(order):\n    return order.total"));
  });
  step(QStringLiteral("the code written so far is shown as a code block"), [](World& world, const Captures&, const Table&) {
    QQuickItem* message = reply(world, 2);
    QQuickItem* segment = within(message, QStringLiteral("markdownSegment")).last();
    expect(segment->property("kind") == QLatin1String("code") && segment->property("open").toBool(),
           QStringLiteral("the reply is drawn as %1").arg(kindsOf(message).join(QStringLiteral(", "))));
    QQuickItem* code = one(message, QStringLiteral("codeText"));
    expect(plain(code) == QLatin1String("def refund(order):\n    return order.total"), QStringLiteral("the code reads \"%1\"").arg(plain(code)));
    world.node.part<Seen>().item = code;
  });
  step(QStringLiteral("the agent closes the code block"), [](World& world, const Captures&, const Table&) {
    write(world, QStringLiteral("\n```"));
  });
  step(QStringLiteral("the same code block is shown, finished"), [](World& world, const Captures&, const Table&) {
    QQuickItem* message = reply(world, 2);
    QQuickItem* segment = within(message, QStringLiteral("markdownSegment")).last();
    world.waitFor([&] { return !segment->property("open").toBool(); }, QStringLiteral("the code block to close"));
    expect(one(message, QStringLiteral("codeText")) == world.node.part<Seen>().item.data(), QStringLiteral("the code block was drawn anew"));
  });

  // Alerts.
  step(QStringLiteral("the agent answers with a %1 alert").arg(q), [](World& world, const Captures& c, const Table&) {
    answer(world, QStringLiteral("> [!%1]\n> Refunds reuse the old rate.").arg(c[0]));
  });
  step(QStringLiteral("the quote is titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* title = one(one(reply(world), QStringLiteral("markdownQuote")), QStringLiteral("alertTitle"));
    expect(title->isVisible() && title->property("text").toString() == c[0], QStringLiteral("the quote is titled \"%1\"").arg(title->property("text").toString()));
  });

  // The user's own message.
  step(QStringLiteral("the user's message has two lines"), [](World& world, const Captures&, const Table&) {
    const QString run = startRun(world, 30);
    set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run, {{QStringLiteral("text"), QStringLiteral("Thanks!\nWhat about refunds?")}});
  });
  step(QStringLiteral("the message is shown on two lines"), [](World& world, const Captures&, const Table&) {
    timelineBrick(world);
    QQuickItem* edit = nullptr;
    world.waitFor([&] {
      const QList<QQuickItem*> users = messages(world, true);
      edit = users.isEmpty() ? nullptr : within(users.last(), QStringLiteral("markdownProse")).value(0);
      return edit && plain(edit).contains(QLatin1String("refunds"));
    }, QStringLiteral("the user's message to be shown"));
    expect(edit->property("lineCount").toInt() == 2, QStringLiteral("the message takes %1 lines").arg(edit->property("lineCount").toInt()));
  });

  // Bare web addresses (scrolling-and-links.feature).
  step(QStringLiteral("the agent writes %1").arg(q), [](World& world, const Captures& c, const Table&) {
    answer(world, c[0]);
  });
  step(QStringLiteral("%1 can be opened as a link").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* edit = one(reply(world), QStringLiteral("markdownProse"));
    QPoint point;
    const QString link = linkAt(edit, c[0], &point);
    expect(link == c[0], QStringLiteral("\"%1\" links to \"%2\"").arg(c[0], link));
    QTest::mouseClick(&timelineBrick(world).window(), Qt::LeftButton, Qt::NoModifier, point);
    const QVariantList activated = world.brick->root()->property("activated").toList();
    expect(activated == QVariantList{c[0]}, QStringLiteral("the click opened %1").arg(show(activated)));
  });
  // The same address in inline code and in a code block, in the next reply.
  step(QStringLiteral("web addresses inside code are left as text"), [](World& world, const Captures&, const Table&) {
    const QString address = QStringLiteral("https://example.com/docs");
    answer(world, QStringLiteral("Try `%1` or:\n\n```\ncurl %1\n```").arg(address));
    QQuickItem* message = reply(world, 2);
    QQuickItem* prose = one(message, QStringLiteral("markdownProse"));
    const QString link = linkAt(prose, address);
    expect(link.isEmpty(), QStringLiteral("inline code links to \"%1\"").arg(link));
    QQuickItem* code = one(message, QStringLiteral("codeText"));
    const QString codeLink = linkAt(code, address);
    expect(codeLink.isEmpty() && !code->property("text").toString().contains(QLatin1String("href")),
           QStringLiteral("the code block links to \"%1\"").arg(codeLink));
  });
});

}  // namespace
