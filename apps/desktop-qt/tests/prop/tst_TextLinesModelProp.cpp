// TextLinesModel as a state machine over what changes the file viewer's lines:
// a file's text put in (a file opened, reopened, or written back), the theme,
// and how many columns a line shows. The promise
// (features/files/file-viewer-and-editing.feature): once read, each line shows
// the colours a fresh read of the whole file gives, in the background's theme,
// cut where a plain line is cut with no colour past it; a file of no known
// language, past the cap, or with no name stays plain; and a theme switch, a
// new cut or the same file again reads nothing.

#include "Prop.h"

#include "CodeReader.h"
#include "WorkspaceFiles.h"
#include "hal_c2_syntax.h"

#include <QCoreApplication>
#include <QSignalSpy>

#include <algorithm>
#include <optional>
#include <set>
#include <vector>

namespace {

const std::vector<QString> kPaths{QStringLiteral("src/a.ts"), QStringLiteral("lib/a.ex"), QStringLiteral("ui/A.qml"),
                                  QStringLiteral("notes.txt"), QStringLiteral("x.zzz"), QString()};
const std::vector<QString> kPieces{
    QStringLiteral("const x = 1;\n"), QStringLiteral("defmodule A do\n"), QStringLiteral("  def f, do: :ok\n"),
    QStringLiteral("end\n"), QStringLiteral("\"str"), QStringLiteral("ing\"\n"), QStringLiteral("// note é😀 <b>&amp;</b>"),
    QStringLiteral("\n"), QStringLiteral("import QtQuick\n"), QStringLiteral("Item {\tid: x }\r\n"), QStringLiteral("let   y"),
};

const QColor kLight(QStringLiteral("#ffffff"));
const QColor kDark(QStringLiteral("#111111"));

// The colour of each UTF-16 unit of `text` when read whole, 0 where plain;
// none when the path has no syntax.
std::optional<QList<QRgb>> freshColours(const QString& path, const QString& text, int theme) {
  const QByteArray name = path.toUtf8();
  HalC2Syntax* syntax = hal_c2_syntax_for_path(name.constData(), size_t(name.size()));
  if (!syntax) return std::nullopt;
  QList<QRgb> colours(text.size(), 0);
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

// What a styled line draws: its characters and the colour of each, 0 where
// plain. Only the markup codereader::styled writes.
struct Drawn {
  QString text;
  QList<QRgb> colours;
  bool operator==(const Drawn&) const = default;
};
Drawn draw(const QString& styled) {
  Drawn drawn;
  QRgb colour = 0;
  for (qsizetype at = 0; at < styled.size();) {
    if (styled.at(at) == QLatin1Char('<')) {
      const qsizetype end = styled.indexOf(QLatin1Char('>'), at);
      const QStringView tag = QStringView(styled).mid(at + 1, end - at - 1);
      if (tag.startsWith(QLatin1String("font color=\""))) colour = QColor(tag.mid(12, tag.size() - 13)).rgba();
      else if (tag == QLatin1String("/font")) colour = 0;
      at = end + 1;
      continue;
    }
    QChar c = styled.at(at);
    qsizetype next = at + 1;
    if (c == QLatin1Char('&')) {
      const qsizetype end = styled.indexOf(QLatin1Char(';'), at);
      const QStringView entity = QStringView(styled).mid(at + 1, end - at - 1);
      c = entity == QLatin1String("lt") ? QLatin1Char('<') : entity == QLatin1String("gt") ? QLatin1Char('>') : entity == QLatin1String("amp") ? QLatin1Char('&')
          : entity == QLatin1String("nbsp") ? QLatin1Char(' ') : entity == QLatin1String("#9") ? QLatin1Char('\t') : QChar(u'?');
      next = end + 1;
    }
    drawn.text += c;
    drawn.colours.append(colour);
    at = next;
  }
  return drawn;
}

struct Model {
  QString text;
  QString path;
  bool dark = true;
  int limit = 2000;
  // Files read whole and kept, by path and text.
  std::set<std::pair<QString, QString>> kept;

  bool readable() const { return !path.isEmpty() && !text.isEmpty() && text.size() <= codereader::kMaxChars; }
  // The lines, by offset and length, as the viewer splits them.
  std::vector<std::pair<qsizetype, qsizetype>> lines() const {
    std::vector<std::pair<qsizetype, qsizetype>> lines;
    for (qsizetype at = 0; at < text.size();) {
      qsizetype end = text.indexOf(QLatin1Char('\n'), at);
      if (end < 0) end = text.size();
      qsizetype length = end - at;
      if (length > 0 && text.at(end - 1) == QLatin1Char('\r')) --length;
      lines.emplace_back(at, length);
      at = end + 1;
    }
    return lines;
  }
};

struct Viewer {
  TextLinesModel lines;
  Viewer() { lines.setBackground(kDark); }
};

// Each line is plain (nothing read yet, or nothing to read) or exactly what a
// fresh read colours, cut at the limit; once settled, it is coloured when
// there is colour for this theme.
void check(const Model& model, Viewer& viewer, bool settled) {
  const auto lines = model.lines();
  RC_ASSERT(viewer.lines.rowCount() == int(lines.size()));
  const auto fresh = model.readable() ? freshColours(model.path, model.text, model.dark ? 1 : 0) : std::nullopt;
  const bool colour = fresh && std::any_of(fresh->begin(), fresh->end(), [](QRgb c) { return c != 0; });
  if (settled) RC_ASSERT(viewer.lines.coloured() == colour);
  for (int row = 0; row < int(lines.size()); ++row) {
    const QString styled = viewer.lines.styled(row);
    RC_ASSERT(viewer.lines.data(viewer.lines.index(row), TextLinesModel::StyledRole).toString() == styled);
    if (!viewer.lines.coloured()) {
      RC_ASSERT(styled.isEmpty());
      continue;
    }
    RC_ASSERT(colour);
    const auto [offset, length] = lines[size_t(row)];
    const bool cut = length > model.limit;
    Drawn expected{model.text.mid(offset, cut ? model.limit : length), fresh->mid(offset, cut ? model.limit : length)};
    if (cut) {
      expected.text += QStringLiteral("…");
      expected.colours.append(0);
    }
    RC_ASSERT(draw(styled) == expected);
  }
}

void settle(Viewer& viewer) {
  QCoreApplication::processEvents();
  RC_ASSERT(halc2::prop::until([&] { return !viewer.lines.reading(); }));
}

using Command = rc::state::Command<Model, Viewer>;

QString code(const std::vector<QString>& pieces) {
  return QStringList(pieces.begin(), pieces.end()).join(QString());
}

struct Open : Command {
  QString path = *rc::gen::elementOf(kPaths);
  QString text = *rc::gen::map(rc::gen::container<std::vector<QString>>(*rc::gen::inRange(0, 6), rc::gen::elementOf(kPieces)), code);
  // Past the cap by a little.
  bool large = *rc::gen::weightedElement<bool>({{9, false}, {1, true}});
  void apply(Model& model) const override {
    model.path = path;
    model.text = large ? text + QString(codereader::kMaxChars + 1 - text.size(), QLatin1Char('x')) : text;
  }
  void run(const Model& before, Viewer& viewer) const override {
    Model after = before;
    apply(after);
    const quint64 reads = codereader::requested();
    viewer.lines.setText(after.text, after.path);
    // Read already, or the same file again, or nothing to read: no new read.
    const bool same = before.path == after.path && before.text == after.text;
    if (!after.readable() || same || after.kept.contains({after.path, after.text})) RC_ASSERT(codereader::requested() == reads);
    if (after.kept.contains({after.path, after.text}) && !same) RC_ASSERT(!viewer.lines.reading());
    check(after, viewer, !viewer.lines.reading());
  }
  void show(std::ostream& os) const override { os << "Open(" << path.toStdString() << ", " << text.toStdString() << (large ? ", large" : "") << ")"; }
};

struct Settle : Command {
  void apply(Model& model) const override {
    if (model.readable() && freshColours(model.path, QString(), 0)) model.kept.insert({model.path, model.text});
  }
  void run(const Model& before, Viewer& viewer) const override {
    Model after = before;
    apply(after);
    settle(viewer);
    check(after, viewer, true);
  }
  void show(std::ostream& os) const override { os << "Settle"; }
};

struct ThemeSwitch : Command {
  void apply(Model& model) const override { model.dark = !model.dark; }
  void run(const Model& before, Viewer& viewer) const override {
    Model after = before;
    apply(after);
    const quint64 reads = codereader::requested();
    const bool reading = viewer.lines.reading();
    QSignalSpy changed(&viewer.lines, &QAbstractItemModel::dataChanged);
    QSignalSpy reset(&viewer.lines, &QAbstractItemModel::modelReset);
    viewer.lines.setBackground(after.dark ? kDark : kLight);
    // Shown from what was read: nothing is read again, and only the styled
    // role changes.
    RC_ASSERT(codereader::requested() == reads && viewer.lines.reading() == reading && reset.isEmpty());
    for (const QList<QVariant>& signal : changed) RC_ASSERT(signal.at(2).value<QList<int>>() == QList<int>{TextLinesModel::StyledRole});
    check(after, viewer, !reading);
  }
  void show(std::ostream& os) const override { os << "ThemeSwitch"; }
};

struct Limit : Command {
  int limit = *rc::gen::inRange(0, 30);
  void apply(Model& model) const override { model.limit = limit; }
  void run(const Model& before, Viewer& viewer) const override {
    Model after = before;
    apply(after);
    const quint64 reads = codereader::requested();
    const bool reading = viewer.lines.reading();
    viewer.lines.setColumnLimit(limit);
    RC_ASSERT(codereader::requested() == reads);
    check(after, viewer, !reading);
  }
  void show(std::ostream& os) const override { os << "Limit(" << limit << ")"; }
};

}  // namespace

class TextLinesModelProp : public QObject {
  Q_OBJECT
private slots:
  void init() { codereader::clearCache(); }

  void lines() {
    QVERIFY(rc::check("a file's lines show the colours a fresh read gives, cut where they are cut", [] {
      codereader::clearCache();
      Model model;
      Viewer viewer;
      rc::state::check(model, viewer, rc::state::gen::execOneOfWithArgs<Open, Settle, ThemeSwitch, Limit>());
    }));
  }

  void markupIsEscaped() {
    TextLinesModel lines;
    lines.setText(QStringLiteral("const a = \"<b>&\";\t// x\n"), QStringLiteral("a.ts"));
    QTRY_VERIFY(lines.coloured());
    const Drawn drawn = draw(lines.styled(0));
    QCOMPARE(drawn.text, QStringLiteral("const a = \"<b>&\";\t// x"));
  }
};

HAL_C2_PROP_MAIN(TextLinesModelProp)
#include "tst_TextLinesModelProp.moc"
