// A file and a text attachment coloured by their language
// (features/files/file-viewer-and-editing.feature): what the viewer's lines
// draw, read off the line items themselves.

#include <QQuickItem>
#include <QQuickTextDocument>
#include <QRegularExpression>
#include <QTextBlock>
#include <QTextDocument>
#include <QTextLayout>

#include "CodeReader.h"
#include "FakeFiles.h"
#include "FilesViewer.h"
#include "FilesWorkspace.h"
#include "Harness.h"
#include "SettingsController.h"
#include "ThemeController.h"
#include "World.h"

namespace {

using namespace filesteps;

struct Sample {
  QString code;
  // A word the language colours, at the start of the first line.
  QString keyword;
};

const QHash<QString, Sample> kSamples{
    {QStringLiteral("TypeScript"), {QStringLiteral("export const total = (items: number[]) => items.length;\nexport const tax = 0.2;\n"), QStringLiteral("export")}},
    {QStringLiteral("Elixir"), {QStringLiteral("defmodule Shop.Cart do\n  def total(items), do: length(items)\nend\n"), QStringLiteral("defmodule")}},
    {QStringLiteral("QML"), {QStringLiteral("import QtQuick\n\nItem {\n    id: cart\n}\n"), QStringLiteral("import")}},
};

struct ColourSeen {
  QString keywordColour;
  quint64 reads = 0;
  qsizetype fileReads = 0;
  QString longLine;
};

ColourSeen& seen(World& world) {
  return world.mc.part<ColourSeen>();
}

const QQuickItem* find(const QQuickItem* item, const QString& objectName) {
  if (item->objectName() == objectName) return item;
  for (const QQuickItem* child : item->childItems()) {
    if (const QQuickItem* found = find(child, objectName)) return found;
  }
  return nullptr;
}

// The item drawing line `number` of the open file, once there.
const QQuickItem* lineItem(World& world, int number) {
  showPanel(world);
  const QString name = QStringLiteral("fileLineText-%1").arg(number);
  const QQuickItem* item = nullptr;
  world.waitFor([&] { return (item = find(world.brick->window().contentItem(), name)) != nullptr; }, QStringLiteral("line %1 to be drawn").arg(number));
  return item;
}

// What a line's markup reads as.
QString plain(QString styled) {
  static const QRegularExpression tag(QStringLiteral("<[^>]+>"));
  styled.remove(tag);
  styled.replace(QLatin1String("&nbsp;"), QLatin1String(" "));
  styled.replace(QLatin1String("&#9;"), QLatin1String("\t"));
  styled.replace(QLatin1String("&lt;"), QLatin1String("<"));
  styled.replace(QLatin1String("&gt;"), QLatin1String(">"));
  styled.replace(QLatin1String("&amp;"), QLatin1String("&"));
  return styled;
}

bool styledText(const QQuickItem* item) {
  return item->property("textFormat").toInt() == 4;  // Text.StyledText
}

// The colour `keyword` is drawn in on `item`'s line, empty when plain.
QString colourOf(const QQuickItem* item, const QString& keyword) {
  if (!styledText(item)) return {};
  const QRegularExpression font(QStringLiteral("<font color=\"(#[0-9a-f]+)\">(?:<[biu]>)*") + QRegularExpression::escape(keyword));
  return font.match(item->property("text").toString()).captured(1);
}

qsizetype fileReads(World& world) {
  qsizetype count = 0;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) count += rpc.method == QLatin1String("projects.readFile");
  return count;
}

void waitForRead(World& world) {
  world.waitFor([&] { return files(world).fileStatus() == QLatin1String("ready") && !files(world).lines()->reading(); },
                [&] { return QStringLiteral("the file to be read; it is %1").arg(files(world).fileStatus()); });
}

QString describeLine(const QQuickItem* item) {
  return QStringLiteral("the line reads \"%1\" as %2").arg(item->property("text").toString().left(300), styledText(item) ? QStringLiteral("styled text") : QStringLiteral("plain text"));
}

// The attachment viewer's text and its highlighter, once both are there.
std::pair<QQuickItem*, QObject*> attachmentText(World& world) {
  QQuickItem* text = nullptr;
  QObject* highlighter = nullptr;
  world.waitFor([&] {
    text = world.brick->root()->findChild<QQuickItem*>(QStringLiteral("attachmentViewerText"));
    highlighter = text ? text->findChild<QObject*>(QStringLiteral("attachmentViewerHighlighter")) : nullptr;
    return highlighter && !highlighter->property("reading").toBool();
  }, QStringLiteral("the attachment's text"));
  return {text, highlighter};
}

qsizetype colouredRanges(QQuickItem* text) {
  QTextDocument* document = text->property("textDocument").value<QQuickTextDocument*>()->textDocument();
  qsizetype count = 0;
  for (QTextBlock block = document->begin(); block.isValid(); block = block.next()) {
    for (const QTextLayout::FormatRange& range : block.layout()->formats()) count += range.format.hasProperty(QTextFormat::ForegroundBrush);
  }
  return count;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("%1 in %1 holds (TypeScript|Elixir|QML) code").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(c[0], kSamples.value(c[2]).code);
  });
  step(QStringLiteral("%1 in %1 holds plain text").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(c[0], QStringLiteral("export const total = 1;\nbuy milk & eggs <today>\n"));
  });
  step(QStringLiteral("%1 in %1 holds more than 512K characters of code").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString line = kSamples.value(QStringLiteral("TypeScript")).code;
    fakeFiles(world.mc).files.insert(c[0], line.repeated(codereader::kMaxChars / line.size() + 1));
  });
  step(QStringLiteral("%1 in %1 has a line of TypeScript (\\d+) characters long").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString piece = QStringLiteral("const a = 1; ");
    QString line = QStringLiteral("export ") + piece.repeated(c[2].toInt() / piece.size() + 1);
    line.truncate(c[2].toInt());
    seen(world).longLine = line;
    fakeFiles(world.mc).files.insert(c[0], line + QStringLiteral("\nexport const b = 2;\n"));
  });

  step(QStringLiteral("the lines of %1 are coloured as (TypeScript|Elixir|QML)").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForRead(world);
    expect(files(world).openPath() == c[0] && files(world).lines()->coloured(), QStringLiteral("\"%1\" is open, coloured: %2").arg(files(world).openPath()).arg(files(world).lines()->coloured()));
    const Sample sample = kSamples.value(c[1]);
    const QStringList lines = sample.code.split(QLatin1Char('\n'));
    for (int number = 1; number < lines.size(); ++number) {
      const QQuickItem* item = lineItem(world, number);
      expect(plain(item->property("text").toString()) == lines.at(number - 1), describeLine(item));
    }
    const QQuickItem* first = lineItem(world, 1);
    const QString colour = colourOf(first, sample.keyword);
    expect(!colour.isEmpty(), QStringLiteral("\"%1\" is not coloured: %2").arg(sample.keyword, describeLine(first)));
    seen(world).keywordColour = colour;
  });
  step(QStringLiteral("the lines of %1 are shown plain").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForRead(world);
    expect(files(world).openPath() == c[0] && !files(world).lines()->coloured(), QStringLiteral("\"%1\" is open, coloured: %2").arg(files(world).openPath()).arg(files(world).lines()->coloured()));
    const QString first = fakeFiles(world.mc).files.value(c[0]).section(QLatin1Char('\n'), 0, 0);
    const QQuickItem* item = lineItem(world, 1);
    expect(!styledText(item) && item->property("text").toString() == first, describeLine(item));
  });

  step(QStringLiteral("the long line is shown up to its (\\d+)(?:st|nd|rd|th) character and then %1").arg(q), [](World& world, const Captures& c, const Table&) {
    waitForRead(world);
    expect(files(world).lines()->coloured(), QStringLiteral("the file is not coloured"));
    const QQuickItem* item = lineItem(world, 1);
    expect(styledText(item) && plain(item->property("text").toString()) == seen(world).longLine.left(c[0].toInt()) + c[1], describeLine(item));
  });
  step(QStringLiteral("no colour reaches past the cut"), [](World& world, const Captures&, const Table&) {
    const QString text = lineItem(world, 1)->property("text").toString();
    // The cut's mark comes after every coloured run has closed.
    const qsizetype mark = text.lastIndexOf(QStringLiteral("…"));
    expect(mark > 0 && text.lastIndexOf(QLatin1String("</font>")) < mark && text.lastIndexOf(QLatin1String("<font")) < mark && mark == text.size() - 1,
           QStringLiteral("the line ends \"%1\"").arg(text.right(120)));
  });

  step(QStringLiteral("the app turns dark while the file is open"), [](World& world, const Captures&, const Table&) {
    seen(world).reads = codereader::requested();
    seen(world).fileReads = fileReads(world);
    auto* themes = world.native().controller<ThemeController>();
    expect(themes->setMode(QStringLiteral("dark")), world.native().controller<SettingsController>()->deviceError());
    world.waitFor([&] { return world.theme().appearance() == QLatin1String("dark"); }, QStringLiteral("the app to be drawn dark"));
  });
  step(QStringLiteral("the lines of %1 are coloured for the dark theme").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(files(world).openPath() == c[0], QStringLiteral("\"%1\" is open").arg(files(world).openPath()));
    const QString keyword = kSamples.value(QStringLiteral("TypeScript")).keyword;
    QString colour;
    world.waitFor([&] {
      colour = colourOf(lineItem(world, 1), keyword);
      return !colour.isEmpty() && colour != seen(world).keywordColour;
    }, [&] { return QStringLiteral("\"%1\" in another colour than %2; it is %3").arg(keyword, seen(world).keywordColour, colour); });
  });
  step(QStringLiteral("the file was not read again"), [](World& world, const Captures&, const Table&) {
    expect(codereader::requested() == seen(world).reads && !files(world).lines()->reading(),
           QStringLiteral("the code was read %1 more times").arg(codereader::requested() - seen(world).reads));
    expect(fileReads(world) == seen(world).fileReads, QStringLiteral("the MC was asked for the file %1 more times").arg(fileReads(world) - seen(world).fileReads));
  });

  step(QStringLiteral("its text is shown coloured as TypeScript"), [](World& world, const Captures&, const Table&) {
    const auto [text, highlighter] = attachmentText(world);
    expect(text->property("text").toString() == kSamples.value(QStringLiteral("TypeScript")).code, QStringLiteral("the text reads \"%1\"").arg(text->property("text").toString()));
    expect(highlighter->property("coloured").toBool() && colouredRanges(text) > 0, QStringLiteral("the text has %1 coloured runs").arg(colouredRanges(text)));
  });
  step(QStringLiteral("its text is shown plain"), [](World& world, const Captures&, const Table&) {
    const auto [text, highlighter] = attachmentText(world);
    expect(!text->property("text").toString().isEmpty(), QStringLiteral("the text is empty"));
    expect(!highlighter->property("coloured").toBool() && colouredRanges(text) == 0, QStringLiteral("the text has %1 coloured runs").arg(colouredRanges(text)));
  });
});

}  // namespace
