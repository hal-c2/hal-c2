// CodeHighlighter as a state machine over what changes a code block: text
// written onto its end (as a reply streams) or put in its place, its language,
// whether it is still being written, and the theme. The promise
// (features/timeline/markdown.feature): once it has read, the block shows the
// colours a fresh read of its finished lines would give, in its background's
// theme; a line being written waits, a line already read stays coloured, and
// a language with no syntax stays plain.
//
// Beside it, examples of the same promise one at a time: the theme switch
// reads nothing again, code read once colours a new block at once.

#include "Prop.h"

#include "CodeHighlighter.h"
#include "hal_c2_syntax.h"

#include <QSignalSpy>
#include <QTextBlock>
#include <QTextDocument>
#include <QTextLayout>

#include <algorithm>
#include <vector>

namespace {

const std::vector<QString> kLanguages{QStringLiteral("ts"), QStringLiteral("elixir"), QStringLiteral("qml"), QStringLiteral("nope"),
                             QString()};
const std::vector<QString> kPieces{
    QStringLiteral("const x = 1;\n"), QStringLiteral("defmodule A do\n"), QStringLiteral("  def f, do: :ok\n"),
    QStringLiteral("end\n"), QStringLiteral("\"str"), QStringLiteral("ing\"\n"), QStringLiteral("// note é😀"),
    QStringLiteral("\n"), QStringLiteral("import QtQuick\n"), QStringLiteral("Item { id: x }\n"), QStringLiteral("let"),
};

const QColor kLight(QStringLiteral("#ffffff"));
const QColor kDark(QStringLiteral("#111111"));

// The colour of each UTF-16 unit of `text` when read at once, 0 where plain.
QList<QRgb> freshColours(const QString& language, const QString& text, int theme, qsizetype size) {
  QList<QRgb> colours(size, 0);
  const QByteArray name = language.toUtf8();
  HalC2Syntax* syntax = hal_c2_syntax_for_language(name.constData(), size_t(name.size()));
  if (!syntax) return colours;
  struct Context {
    QList<QRgb>* colours;
    int theme;
  } context{&colours, theme};
  const QByteArray code = text.toUtf8();
  hal_c2_syntax_feed(syntax, code.constData(), size_t(code.size()), [](void* data, const HalC2SyntaxSpan* span) {
    auto* context = static_cast<Context*>(data);
    if (span->theme != context->theme) return;
    for (quint32 at = span->start; at < span->start + span->length && at < quint32(context->colours->size()); ++at)
      (*context->colours)[at] = span->color;
  }, &context);
  hal_c2_syntax_free(syntax);
  return colours;
}

// The colour each unit of `document` shows, 0 where plain.
QList<QRgb> shownColours(const QTextDocument& document) {
  QList<QRgb> colours(document.characterCount(), 0);
  for (QTextBlock block = document.begin(); block.isValid(); block = block.next()) {
    for (const QTextLayout::FormatRange& range : block.layout()->formats()) {
      if (!range.format.hasProperty(QTextFormat::ForegroundBrush)) continue;
      for (int at = range.start; at < range.start + range.length; ++at)
        colours[block.position() + at] = range.format.foreground().color().rgba();
    }
  }
  return colours;
}

struct Model {
  QString text;
  QString language = QStringLiteral("ts");
  bool streaming = false;
  bool dark = true;
  // What is coloured: the start of the text, read whole.
  QString covered;

  // The finished lines, or all of it once it is not being written.
  QString target() const { return streaming ? text.left(text.lastIndexOf(QLatin1Char('\n')) + 1) : text; }
  // After a change: what was coloured stays while the text still starts
  // with it, and the finished lines are read.
  void settle() {
    if (!text.startsWith(covered)) covered.clear();
    if (target().size() > covered.size()) covered = target();
  }
};

struct Block {
  QTextDocument document;
  CodeHighlighter highlighter;

  Block() {
    // A document tells of its changes only once laid out, as a TextEdit's is.
    document.documentLayout();
    highlighter.setLanguage(QStringLiteral("ts"));
    highlighter.setBackground(kDark);
    highlighter.setTextDocument(&document);
  }
};

void check(const Model& model, Block& block) {
  RC_ASSERT(halc2::prop::until([&] { return !block.highlighter.reading(); }));
  RC_ASSERT(block.document.toPlainText() == model.text);
  const QList<QRgb> shown = shownColours(block.document);
  const QList<QRgb> expected = freshColours(model.language, model.covered, model.dark ? 1 : 0, shown.size());
  RC_ASSERT(shown == expected);
  RC_ASSERT(block.highlighter.coloured() == std::any_of(expected.begin(), expected.end(), [](QRgb c) { return c != 0; }));
}

using Command = rc::state::Command<Model, Block>;

struct Write : Command {
  QString piece = *rc::gen::elementOf(kPieces);
  void apply(Model& model) const override {
    model.text += piece;
    model.settle();
  }
  void run(const Model& before, Block& block) const override {
    Model after = before;
    apply(after);
    // As the TextEdit's text binding does: the whole text again.
    block.document.setPlainText(after.text);
    check(after, block);
  }
  void show(std::ostream& os) const override { os << "Write(" << piece.toStdString() << ")"; }
};

struct Replace : Command {
  QString text = *rc::gen::map(rc::gen::container<std::vector<QString>>(*rc::gen::inRange(0, 4), rc::gen::elementOf(kPieces)),
                               [](const std::vector<QString>& pieces) { return QStringList(pieces.begin(), pieces.end()).join(QString()); });
  void apply(Model& model) const override {
    model.text = text;
    model.settle();
  }
  void run(const Model& before, Block& block) const override {
    Model after = before;
    apply(after);
    block.document.setPlainText(text);
    check(after, block);
  }
  void show(std::ostream& os) const override { os << "Replace(" << text.toStdString() << ")"; }
};

struct Language : Command {
  QString language = *rc::gen::elementOf(kLanguages);
  void apply(Model& model) const override {
    if (language == model.language) return;
    model.language = language;
    model.covered.clear();
    model.settle();
  }
  void run(const Model& before, Block& block) const override {
    Model after = before;
    apply(after);
    block.highlighter.setLanguage(language);
    check(after, block);
  }
  void show(std::ostream& os) const override { os << "Language(" << language.toStdString() << ")"; }
};

struct Streaming : Command {
  bool streaming = *rc::gen::arbitrary<bool>();
  void apply(Model& model) const override {
    model.streaming = streaming;
    model.settle();
  }
  void run(const Model& before, Block& block) const override {
    Model after = before;
    apply(after);
    block.highlighter.setStreaming(streaming);
    check(after, block);
  }
  void show(std::ostream& os) const override { os << "Streaming(" << streaming << ")"; }
};

struct ThemeSwitch : Command {
  void apply(Model& model) const override { model.dark = !model.dark; }
  void run(const Model& before, Block& block) const override {
    Model after = before;
    apply(after);
    block.highlighter.setBackground(after.dark ? kDark : kLight);
    // A theme is shown from what was read: nothing is read again.
    RC_ASSERT(!block.highlighter.reading());
    check(after, block);
  }
  void show(std::ostream& os) const override { os << "ThemeSwitch"; }
};

const QString kTs = QStringLiteral("const x = 1;\n");

}  // namespace

class CodeHighlighterProp : public QObject {
  Q_OBJECT
private slots:
  void init() { CodeHighlighter::clearCache(); }

  void block() {
    QVERIFY(rc::check("a code block shows its finished lines coloured as a fresh read", [] {
      CodeHighlighter::clearCache();
      Model model;
      Block block;
      rc::state::check(model, block, rc::state::gen::execOneOfWithArgs<Write, Replace, Language, Streaming, ThemeSwitch>());
    }));
  }

  void themeSwitchReadsNothingAgain() {
    QTextDocument document(kTs);
    CodeHighlighter highlighter;
    highlighter.setLanguage(QStringLiteral("ts"));
    highlighter.setBackground(kDark);
    highlighter.setTextDocument(&document);
    QTRY_VERIFY(highlighter.coloured());
    QVERIFY(!highlighter.reading());
    const QRgb dark = shownColours(document).at(0);
    QSignalSpy reads(&highlighter, &CodeHighlighter::readingChanged);
    highlighter.setBackground(kLight);
    const QRgb light = shownColours(document).at(0);
    QCOMPARE(reads.count(), 0);
    QCOMPARE(dark, QRgb(0xffff678d));
    QCOMPARE(light, QRgb(0xffd32a61));
  }

  void lineBeingWrittenWaits() {
    QTextDocument document(QStringLiteral("const"));
    CodeHighlighter highlighter;
    highlighter.setLanguage(QStringLiteral("ts"));
    highlighter.setStreaming(true);
    highlighter.setTextDocument(&document);
    QVERIFY(!highlighter.reading());
    QVERIFY(!highlighter.coloured());
    highlighter.setStreaming(false);
    QTRY_VERIFY(highlighter.coloured());
  }

  void unknownLanguageStaysPlain() {
    QTextDocument document(kTs);
    CodeHighlighter highlighter;
    highlighter.setLanguage(QStringLiteral("no-such-language"));
    highlighter.setTextDocument(&document);
    QTRY_VERIFY(!highlighter.reading());
    QVERIFY(!highlighter.coloured());
    document.setPlainText(kTs + kTs);
    // Known to have no syntax: nothing more is read.
    QVERIFY(!highlighter.reading());
  }

  void codeReadOnceColoursANewBlockAtOnce() {
    {
      QTextDocument document(kTs);
      CodeHighlighter highlighter;
      highlighter.setLanguage(QStringLiteral("ts"));
      highlighter.setTextDocument(&document);
      QTRY_VERIFY(highlighter.coloured());
    }
    // The same block made again, as a reply scrolled back into view is.
    QTextDocument document(kTs);
    CodeHighlighter highlighter;
    highlighter.setLanguage(QStringLiteral("ts"));
    highlighter.setTextDocument(&document);
    QVERIFY(!highlighter.reading());
    QVERIFY(highlighter.coloured());
  }

  void filesAreKnownByTheirNames() {
    QTextDocument document(QStringLiteral("defmodule A do\nend\n"));
    CodeHighlighter highlighter;
    highlighter.setPath(QStringLiteral("lib/a.ex"));
    highlighter.setTextDocument(&document);
    QTRY_VERIFY(highlighter.coloured());
  }
};

HAL_C2_PROP_MAIN(CodeHighlighterProp)
#include "tst_CodeHighlighterProp.moc"
