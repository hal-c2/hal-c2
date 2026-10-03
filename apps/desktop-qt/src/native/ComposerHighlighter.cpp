#include "ComposerHighlighter.h"

#include <QCoreApplication>
#include <QQmlEngine>
#include <QRegularExpression>
#include <QTextCharFormat>

ComposerHighlighter::ComposerHighlighter(QObject* parent) : QSyntaxHighlighter(parent) {}

void ComposerHighlighter::setQuickDocument(QQuickTextDocument* document) {
  if (document == m_document) return;
  m_document = document;
  setDocument(document ? document->textDocument() : nullptr);
  emit documentChanged();
}

void ComposerHighlighter::setRich(bool rich) {
  if (rich == m_rich) return;
  m_rich = rich;
  rehighlight();
  emit richChanged();
}

void ComposerHighlighter::setMarkerColor(const QColor& color) {
  if (color == m_markerColor) return;
  m_markerColor = color;
  if (m_rich) rehighlight();
  emit markerColorChanged();
}

void ComposerHighlighter::setCodeFont(const QString& family) {
  if (family == m_codeFont) return;
  m_codeFont = family;
  if (m_rich) rehighlight();
  emit codeFontChanged();
}

void ComposerHighlighter::highlightBlock(const QString& text) {
  if (!m_rich) return;
  QTextCharFormat marker;
  if (m_markerColor.isValid()) marker.setForeground(m_markerColor);

  static const QRegularExpression heading(QStringLiteral("^ {0,3}#{1,6} +\\S.*$"));
  if (const auto match = heading.match(text); match.hasMatch()) {
    QTextCharFormat bold;
    bold.setFontWeight(QFont::Bold);
    setFormat(0, int(text.size()), bold);
    setFormat(0, int(text.indexOf(QLatin1Char(' '), text.indexOf(QLatin1Char('#')))), marker);
  }

  // Each: the pattern, how wide its marker is, and what the text between reads as.
  struct Rule {
    QRegularExpression pattern;
    int width;
    std::function<void(QTextCharFormat&)> style;
  };
  static const QList<Rule> rules{
      {QRegularExpression(QStringLiteral("`[^`\\n]+`")), 1, nullptr},
      {QRegularExpression(QStringLiteral("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")), 2, [](QTextCharFormat& format) { format.setFontWeight(QFont::Bold); }},
      {QRegularExpression(QStringLiteral("~~(?=\\S)(.+?)(?<=\\S)~~")), 2, [](QTextCharFormat& format) { format.setFontStrikeOut(true); }},
      {QRegularExpression(QStringLiteral("(?<![\\*\\w])\\*(?=[^\\s\\*])([^\\*\\n]+?)(?<=[^\\s\\*])\\*(?![\\*\\w])|(?<![_\\w])_(?=[^\\s_])([^_\\n]+?)(?<=[^\\s_])_(?![_\\w])")), 1,
       [](QTextCharFormat& format) { format.setFontItalic(true); }},
  };
  for (const Rule& rule : rules) {
    auto matches = rule.pattern.globalMatch(text);
    while (matches.hasNext()) {
      const auto match = matches.next();
      const int start = int(match.capturedStart());
      const int length = int(match.capturedLength());
      for (int at = start + rule.width; at < start + length - rule.width; ++at) {
        QTextCharFormat inner = format(at);
        if (rule.style) {
          rule.style(inner);
        } else if (!m_codeFont.isEmpty()) {
          inner.setFontFamilies({m_codeFont});
        } else {
          inner.setFontFixedPitch(true);
        }
        setFormat(at, 1, inner);
      }
      setFormat(start, rule.width, marker);
      setFormat(start + length - rule.width, rule.width, marker);
    }
  }
}

namespace {

void registerComposerHighlighter() {
  qmlRegisterType<ComposerHighlighter>("HalC2.Shell", 1, 0, "ComposerHighlighter");
}

}  // namespace

Q_COREAPP_STARTUP_FUNCTION(registerComposerHighlighter)
