// Terminal excerpts on the composer's draft: a terminal selection added to
// the chat (composer.terminalContext.add, as the terminal's menu dispatches
// it), the chips the composer shows and removes, and the context records a
// send carries (features/terminal/composer-context.feature,
// composer/context-references.feature). A quoted reply is held the same way
// (composer.citation.add, as the timeline's Cite dispatches it).

#include <QJsonArray>
#include <QJsonObject>
#include <QUrl>
#include <QUrlQuery>
#include <QVariantMap>

#include "ComposerController.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "Turn.h"
#include "World.h"

namespace {

const QString kFailure = QStringLiteral("FAIL cart.test.ts\n  expected 3, got 2\n  at cart.test.ts:12");

// The reply the quote scenarios cite from.
const QString kParagraph = QStringLiteral("Cache keys include the tenant, so <one> tenant's entries never serve another.");

// The selection the scenario's terminal shows, and the draft's text before
// the last removal.
QVariantMap g_selection;
QString g_textBefore;

ComposerController* composer(World& world) {
  return world.native().controller<ComposerController>();
}

QString target(World& world) {
  return world.native().controller<NavigationController>()->threadKey();
}

QVariantList chips(World& world) {
  return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("terminalContexts")).toList();
}

// The chip's words, as the composer brick writes them.
QString label(const QVariantMap& chip) {
  const int start = chip.value(QStringLiteral("lineStart")).toInt();
  const int end = chip.value(QStringLiteral("lineEnd")).toInt();
  const QString name = chip.value(QStringLiteral("label")).toString();
  return start == end ? QStringLiteral("%1 line %2").arg(name).arg(start)
                      : QStringLiteral("%1 lines %2-%3").arg(name).arg(start).arg(end);
}

QStringList labels(World& world) {
  QStringList found;
  for (const QVariant& chip : chips(world)) found.append(label(chip.toMap()));
  return found;
}

void add(World& world, const QVariantMap& selection) {
  openTurnThread(world);
  g_selection = selection;
  world.bridge().dispatch(QStringLiteral("composer.terminalContext.add"), selection);
}

QVariantMap selection(const QString& terminal, int start, int end, const QString& text) {
  return {{QStringLiteral("terminalId"), QStringLiteral("term-") + terminal.section(QLatin1Char(' '), -1)},
          {QStringLiteral("terminalLabel"), terminal},
          {QStringLiteral("lineStart"), start},
          {QStringLiteral("lineEnd"), end},
          {QStringLiteral("text"), text}};
}

// The newest message the MC was sent.
QJsonObject lastMessage(World& world) {
  for (qsizetype i = world.mc.commands.size() - 1; i >= 0; --i) {
    const QJsonObject& command = world.mc.commands.at(i);
    if (command.value(QLatin1String("type")).toString() == QLatin1String("message.dispatch")) return command;
  }
  return {};
}

QVariantList quotes(World& world) {
  return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("citations")).toList();
}

// Cites the paragraph, as selecting it in the reply and choosing Cite does.
void cite(World& world) {
  openTurnThread(world);
  world.bridge().dispatch(QStringLiteral("composer.citation.add"),
                          QVariantMap{{QStringLiteral("messageId"), QStringLiteral("msg-caching")},
                                      {QStringLiteral("text"), kParagraph},
                                      {QStringLiteral("start"), 12},
                                      {QStringLiteral("end"), 12 + kParagraph.size()},
                                      {QStringLiteral("prefix"), QStringLiteral("On caching: ")},
                                      {QStringLiteral("suffix"), QString()}});
  world.waitFor([&] { return quotes(world).size() == 1; },
                [&] { return QStringLiteral("one quote; the composer shows %1").arg(show(quotes(world))); });
}

void comment(World& world, const QString& text) {
  world.bridge().dispatch(QStringLiteral("composer.citation.comment"),
                          QVariantMap{{QStringLiteral("id"), quotes(world).constFirst().toMap().value(QStringLiteral("id"))},
                                      {QStringLiteral("comment"), text}});
  world.waitFor([&] { return quotes(world).constFirst().toMap().value(QStringLiteral("comment")).toString() == text; },
                [&] { return QStringLiteral("the comment %1; the composer shows %2").arg(show(text), show(quotes(world))); });
}

QJsonObject terminalRecord(const QJsonObject& message) {
  const QJsonArray records = message.value(QLatin1String("context")).toObject().value(QLatin1String("records")).toArray();
  for (const QJsonValue& record : records) {
    if (record.toObject().value(QLatin1String("kind")).toString() == QLatin1String("terminal")) return record.toObject();
  }
  return {};
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("%1 shows a failing test on lines (\\d+) to (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    openTurnThread(world);
    g_selection = selection(c[0], c[1].toInt(), c[2].toInt(), kFailure);
  });
  step(QStringLiteral("the user selects those lines and adds them to the chat"), [](World& world, const Captures&, const Table&) {
    add(world, g_selection);
  });
  step(QStringLiteral("the user adds line (\\d+) of %1 to the chat").arg(q), [](World& world, const Captures& c, const Table&) {
    add(world, selection(c[1], c[0].toInt(), c[0].toInt(), QStringLiteral("$ npm test")));
  });
  step(QStringLiteral("the user selects blank lines in the terminal and adds them to the chat"), [](World& world, const Captures&, const Table&) {
    add(world, selection(QStringLiteral("Terminal 1"), 4, 6, QStringLiteral("\n\n\n")));
  });
  step(QStringLiteral("the draft holds an excerpt from %1 lines (\\d+) to (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    add(world, selection(c[0], c[1].toInt(), c[2].toInt(), kFailure));
  });

  step(QStringLiteral("the draft gains an excerpt labelled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return labels(world) == QStringList{c[0]}; },
                  [&] { return QStringLiteral("the excerpt; the composer shows %1").arg(show(labels(world))); });
  });
  step(QStringLiteral("the excerpt holds the selected text"), [](World& world, const Captures&, const Table&) {
    const QVariantList held = composer(world)->terminalContexts(target(world));
    expect(held.size() == 1 && held.constFirst().toMap().value(QStringLiteral("text")) == g_selection.value(QStringLiteral("text")),
           QStringLiteral("the draft holds %1").arg(show(held)));
  });
  step(QStringLiteral("the draft gains no excerpt"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(chips(world).isEmpty(), QStringLiteral("the composer shows %1").arg(show(labels(world))));
  });
  step(QStringLiteral("the composer shows that excerpt with its terminal and lines"), [](World& world, const Captures&, const Table&) {
    const QVariantMap chip{{QStringLiteral("label"), g_selection.value(QStringLiteral("terminalLabel"))},
                           {QStringLiteral("lineStart"), g_selection.value(QStringLiteral("lineStart"))},
                           {QStringLiteral("lineEnd"), g_selection.value(QStringLiteral("lineEnd"))}};
    world.waitFor([&] { return labels(world) == QStringList{label(chip)}; },
                  [&] { return QStringLiteral("%1; the composer shows %2").arg(label(chip), show(labels(world))); });
  });
  step(QStringLiteral("the user removes that excerpt"), [](World& world, const Captures&, const Table&) {
    const QVariantList shown = chips(world);
    expect(!shown.isEmpty(), QStringLiteral("the composer shows no excerpt"));
    g_textBefore = composer(world)->draft(target(world));
    world.bridge().dispatch(QStringLiteral("composer.terminalContext.remove"),
                            QVariantMap{{QStringLiteral("id"), shown.constFirst().toMap().value(QStringLiteral("id"))}});
  });
  step(QStringLiteral("the draft no longer holds it"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return chips(world).isEmpty() && composer(world)->terminalContexts(target(world)).isEmpty(); },
                  [&] { return QStringLiteral("no excerpt; the composer shows %1").arg(show(labels(world))); });
  });
  step(QStringLiteral("the rest of the draft is unchanged"), [](World& world, const Captures&, const Table&) {
    const QString text = composer(world)->draft(target(world));
    expect(text == g_textBefore, QStringLiteral("the draft's text went from %1 to %2").arg(show(g_textBefore), show(text)));
  });

  // What a send carries.
  step(QStringLiteral("the message references the excerpt %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !terminalRecord(lastMessage(world)).isEmpty(); },
                  [&] { return QStringLiteral("a message with an excerpt; the MC has %1").arg(world.describeCommands()); });
    const QJsonObject message = lastMessage(world);
    const QJsonObject record = terminalRecord(message);
    const QString link = QStringLiteral("[%1](hal-c2-context://v1/terminal/%2)")
                             .arg(c[0], record.value(QLatin1String("contextId")).toString());
    expect(record.value(QLatin1String("label")).toString() == c[0],
           QStringLiteral("the excerpt is labelled %1").arg(show(record.toVariantMap())));
    expect(message.value(QLatin1String("text")).toString().contains(link),
           QStringLiteral("the message text %1 has no %2").arg(show(message.value(QLatin1String("text")).toString()), link));
  });
  step(QStringLiteral("the message carries the excerpt's text"), [](World& world, const Captures&, const Table&) {
    const QJsonObject record = terminalRecord(lastMessage(world));
    expect(record.value(QLatin1String("text")).toString() == g_selection.value(QStringLiteral("text")).toString(),
           QStringLiteral("the excerpt carries %1").arg(show(record.toVariantMap())));
  });
  step(QStringLiteral("the message carries no excerpt"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !lastMessage(world).isEmpty(); },
                  [&] { return QStringLiteral("a message; the MC has %1").arg(world.describeCommands()); });
    const QJsonObject message = lastMessage(world);
    expect(terminalRecord(message).isEmpty() && !message.value(QLatin1String("text")).toString().contains(QLatin1String("hal-c2-context:")),
           QStringLiteral("the message carries %1").arg(show(message.toVariantMap())));
  });
  // Quoted replies.
  step(QStringLiteral("the assistant replied with a paragraph about caching"), [](World& world, const Captures&, const Table&) {
    openTurnThread(world);
  });
  step(QStringLiteral("the user cites that paragraph in the composer"), [](World& world, const Captures&, const Table&) {
    cite(world);
  });
  step(QStringLiteral("the draft carries the quoted paragraph"), [](World& world, const Captures&, const Table&) {
    expect(quotes(world).constFirst().toMap().value(QStringLiteral("text")).toString() == kParagraph,
           QStringLiteral("the composer shows %1").arg(show(quotes(world))));
  });
  for (const auto& text : {QStringLiteral("the user can add a comment to it"), QStringLiteral("the user can add a comment to the citation")}) {
    step(text, [](World& world, const Captures&, const Table&) { comment(world, QStringLiteral("Too slow?")); });
  }
  step(QStringLiteral("the draft quotes the assistant's paragraph about caching with the comment %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         cite(world);
         comment(world, c[0]);
       });
  step(QStringLiteral("the message cites the paragraph with the comment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !lastMessage(world).isEmpty(); },
                  [&] { return QStringLiteral("a message; the MC has %1").arg(world.describeCommands()); });
    const QString text = lastMessage(world).value(QLatin1String("text")).toString();
    const qsizetype at = text.indexOf(QLatin1String("[Assistant quote](hal-c2-citation://v1/"));
    expect(at >= 0 && text.endsWith(u')'), QStringLiteral("the message reads %1").arg(show(text)));
    const QUrl link(text.mid(at + 18).chopped(1));
    const QUrlQuery query(link.query(QUrl::FullyEncoded).replace(u'+', QLatin1String("%20")));
    expect(link.path().endsWith(QLatin1String("/msg-caching")) &&
               query.queryItemValue(QStringLiteral("text"), QUrl::FullyDecoded) == kParagraph &&
               query.queryItemValue(QStringLiteral("comment"), QUrl::FullyDecoded) == c[0],
           QStringLiteral("the message cites %1").arg(show(link.toString())));
  });
  step(QStringLiteral("the stash lists the prompt by the quoted paragraph and its comment"), [](World& world, const Captures&, const Table&) {
    const QVariantList entries = world.state(QStringLiteral("composerStash")).toMap().value(QStringLiteral("entries")).toList();
    const QString expected = (kParagraph + QStringLiteral(" Comment: Too slow?")).left(90) + QStringLiteral("…");
    expect(entries.size() == 1 && entries.constFirst().toMap().value(QStringLiteral("snippet")).toString() == expected,
           QStringLiteral("the stash holds %1").arg(show(entries)));
  });
  step(QStringLiteral("the draft no longer quotes it"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return quotes(world).isEmpty(); },
                  [&] { return QStringLiteral("no quote; the composer shows %1").arg(show(quotes(world))); });
  });

  step(QStringLiteral("the message starts with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !lastMessage(world).isEmpty(); },
                  [&] { return QStringLiteral("a message; the MC has %1").arg(world.describeCommands()); });
    const QString text = lastMessage(world).value(QLatin1String("text")).toString();
    expect(text.startsWith(c[0]), QStringLiteral("the message reads %1").arg(show(text)));
  });
});

}  // namespace
