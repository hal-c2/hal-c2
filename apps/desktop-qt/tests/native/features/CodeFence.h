#pragma once

// A fenced code block as HalC2.Space.Markdown reads and writes it, for the fake
// MC's page import and export on the desktop and the phone (both SpaceSteps.cpp).
// tst_CodeFence checks it against what the MC reads in
// apps/server-ex/test/fixtures/space/code-fences.json, which the MC's own
// space_markdown_test.exs holds it to.

#include <QJsonObject>
#include <QRegularExpression>
#include <QStringList>

#include <algorithm>
#include <utility>

namespace codeFence {

// The marks of the fence `line` opens, or "" (fence/1): up to three spaces in,
// and no backtick in what follows backticks.
inline QString opens(const QString& line) {
  static const QRegularExpression open(QStringLiteral("^ {0,3}(`{3,}|~{3,})(.*)$"));
  const QRegularExpressionMatch match = open.match(line);
  if (!match.hasMatch()) return {};
  const QString marks = match.captured(1);
  return marks.startsWith(QLatin1Char('`')) && match.captured(2).contains(QLatin1Char('`')) ? QString() : marks;
}

// Whether `line` closes a fence opened with `marks` (closes_fence?/2): the same
// mark, at least as many, and nothing after them but spaces.
inline bool closes(const QString& line, const QString& marks) {
  static const QRegularExpression close(QStringLiteral("^ {0,3}(`{3,}|~{3,})\\s*$"));
  const QRegularExpressionMatch match = close.match(line);
  return match.hasMatch() && match.captured(1).at(0) == marks.at(0) && match.captured(1).size() >= marks.size();
}

// A code block's Markdown (render/2): its fence, made longer while a line of
// its text would close it (fence_for/2).
inline QString write(const QJsonObject& code) {
  const QString text = code.value(QLatin1String("text")).toString();
  const QStringList lines = text.isEmpty() ? QStringList() : text.split(QLatin1Char('\n'));
  QString marks = code.value(QLatin1String("fence")).toString();
  if (marks.isEmpty()) marks = QStringLiteral("```");
  while (std::any_of(lines.begin(), lines.end(), [&](const QString& line) { return closes(line, marks); })) marks += marks.at(0);
  const QString open = marks + code.value(QLatin1String("language")).toString() + code.value(QLatin1String("info")).toString();
  return (QStringList{open} + lines + QStringList{marks}).join(QLatin1Char('\n'));
}

// The block the fence `opens` at `lines[at]` is, made by `block(kind, text)`, and
// the line after it. Fenced from the start of the line, its language the first
// word and the rest of the line its info, it is code when write() gives it back
// as it was; else it is raw (closed/3, block(:code), blocks_of/2). One never
// closed is raw to its last line that is not blank (unclosed/1).
template <typename Block>
std::pair<QJsonObject, qsizetype> read(const QStringList& lines, qsizetype at, Block&& block) {
  static const QRegularExpression code(QStringLiteral("^(`{3,}|~{3,})(?:(\\S+)(.*))?$"), QRegularExpression::UseUnicodePropertiesOption);
  const QString marks = opens(lines.at(at));
  qsizetype end = at + 1;
  while (end < lines.size() && !closes(lines.at(end), marks)) ++end;
  if (end == lines.size()) {
    while (end > at + 1 && lines.at(end - 1).trimmed().isEmpty()) --end;
    return {block(QStringLiteral("raw"), lines.mid(at, end - at).join(QLatin1Char('\n'))), lines.size()};
  }
  const QString written = lines.mid(at, end + 1 - at).join(QLatin1Char('\n'));
  const QRegularExpressionMatch match = code.match(lines.at(at));
  if (!match.hasMatch()) return {block(QStringLiteral("raw"), written), end + 1};
  QJsonObject fenced = block(QStringLiteral("code"), lines.mid(at + 1, end - at - 1).join(QLatin1Char('\n')));
  if (match.captured(1) != QLatin1String("```")) fenced.insert(QStringLiteral("fence"), match.captured(1));
  if (!match.captured(2).isEmpty()) fenced.insert(QStringLiteral("language"), match.captured(2));
  if (!match.captured(3).isEmpty()) fenced.insert(QStringLiteral("info"), match.captured(3));
  return {write(fenced) == written ? fenced : block(QStringLiteral("raw"), written), end + 1};
}

}  // namespace codeFence
