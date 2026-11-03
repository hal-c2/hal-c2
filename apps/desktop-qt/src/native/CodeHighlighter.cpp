#include "CodeHighlighter.h"

#include <QCoreApplication>
#include <QQmlEngine>
#include <QTextBlock>
#include <QTextCharFormat>
#include <QTextDocument>

#include <algorithm>

namespace {

void registerCodeHighlighter() {
  qmlRegisterType<CodeHighlighter>("HalC2.Shell", 1, 0, "CodeHighlighter");
}

}  // namespace

Q_COREAPP_STARTUP_FUNCTION(registerCodeHighlighter)

CodeHighlighter::CodeHighlighter(QObject* parent) : QSyntaxHighlighter(parent) {}

CodeHighlighter::~CodeHighlighter() {
  // The base's destructor clears the document's colours, a change this must
  // not hear of once its own members are gone.
  if (m_attached) disconnect(m_attached, nullptr, this, nullptr);
}

void CodeHighlighter::clearCache() {
  codereader::clearCache();
}

void CodeHighlighter::setQuickDocument(QQuickTextDocument* document) {
  if (document == m_quickDocument) return;
  m_quickDocument = document;
  setTextDocument(document ? document->textDocument() : nullptr);
  emit documentChanged();
}

void CodeHighlighter::setTextDocument(QTextDocument* document) {
  if (m_attached) disconnect(m_attached, nullptr, this, nullptr);
  m_attached = document;
  // Before the highlighter's own connection, so a change is known here
  // before its blocks are coloured again.
  if (document) connect(document, &QTextDocument::contentsChange, this, &CodeHighlighter::textChanged);
  setDocument(document);
  m_text = document ? document->toPlainText() : QString();
  restart();
}

void CodeHighlighter::setLanguage(const QString& language) {
  if (language == m_language) return;
  m_language = language;
  if (m_path.isEmpty()) restart();
  emit languageChanged();
}

void CodeHighlighter::setPath(const QString& path) {
  if (path == m_path) return;
  m_path = path;
  restart();
  emit pathChanged();
}

void CodeHighlighter::setBackground(const QColor& background) {
  if (background == m_background) return;
  const int before = theme();
  m_background = background;
  emit backgroundChanged();
  if (theme() != before) apply();
}

void CodeHighlighter::setStreaming(bool streaming) {
  if (streaming == m_streaming) return;
  m_streaming = streaming;
  emit streamingChanged();
  schedule();
}

int CodeHighlighter::theme() const {
  return codereader::themeFor(m_background);
}

void CodeHighlighter::textChanged() {
  if (!m_attached) return;
  QString text = m_attached->toPlainText();
  // Colouring marks the blocks it changed, which is no change to the text.
  if (text == m_text) return;
  m_text = std::move(text);
  const bool was = m_current;
  m_current = !m_read.isEmpty() && m_text.startsWith(m_read);
  // A whole new text comes as two changes, emptied and then filled, so an
  // empty text may be gone again at once: it is settled a moment later,
  // never plain for the moment in between. Still empty then, what was read
  // is gone.
  if (m_text.isEmpty()) {
    QMetaObject::invokeMethod(this, [this] {
      if (m_text.isEmpty()) restart();
      else updateColoured();
    }, Qt::QueuedConnection);
    return;
  }
  // What was read is no longer what is shown: plain until it is read again.
  // (The text filled can start with it again; its blocks are coloured as
  // they change.)
  if (was && !m_current) apply();
  else updateColoured();
  schedule();
}

void CodeHighlighter::restart() {
  // A read under way finishes and is let go: it is for what was before.
  m_alive = std::make_shared<int>(0);
  setRunning(false);
  m_unknown = false;
  m_syntax.reset();
  m_read.clear();
  m_runs.reset();
  m_current = false;
  apply();
  schedule();
}

QString CodeHighlighter::target() const {
  QString text = m_text.left(kMaxChars);
  // Only whole lines: one being written, and one cut by the cap, wait.
  if (m_streaming || text.size() < m_text.size()) text.truncate(text.lastIndexOf(QLatin1Char('\n')) + 1);
  return text;
}

QString CodeHighlighter::cacheKey(const QString& text) const {
  return codereader::cacheKey(m_language, m_path, text);
}

void CodeHighlighter::schedule() {
  if (!m_attached || m_running || m_unknown) return;
  const QString text = target();
  // Nothing new to read; a last line already read stays coloured.
  if (text.isEmpty() || (m_current && m_read.size() >= text.size())) return;

  auto job = std::make_shared<Job>();
  job->byPath = !m_path.isEmpty();
  job->language = (job->byPath ? m_path : m_language).toUtf8();
  // Going on from where the last read stopped, which must be a line's end.
  if (m_current && m_syntax && m_read.endsWith(QLatin1Char('\n'))) {
    job->syntax = std::move(m_syntax);
    job->base = m_read;
    job->delta = text.mid(m_read.size());
    job->runs = m_runs;
  } else if (auto hit = codereader::cached(cacheKey(text))) {
    m_syntax.reset();
    m_read = text;
    m_runs = std::move(hit);
    m_current = true;
    apply();
    return;
  } else {
    m_syntax.reset();
    job->delta = text;
  }

  setRunning(true);
  codereader::start(job, m_alive, [this](const std::shared_ptr<Job>& job) { finished(job); });
}

void CodeHighlighter::setRunning(bool running) {
  if (running == m_running) return;
  m_running = running;
  emit readingChanged();
}

void CodeHighlighter::finished(const std::shared_ptr<Job>& job) {
  if (!job->known) {
    m_unknown = true;
    setRunning(false);
    return;
  }
  m_syntax = std::move(job->syntax);
  m_read = job->base + job->delta;
  m_runs = job->runs;
  m_current = m_text.startsWith(m_read);
  if (!m_streaming && m_current) codereader::keep(cacheKey(m_read), m_runs);
  apply();
  // Straight on to what was written meanwhile, reading all along.
  m_running = false;
  schedule();
  if (!m_running) emit readingChanged();
}

void CodeHighlighter::apply() {
  if (document()) rehighlight();
  updateColoured();
}

void CodeHighlighter::updateColoured() {
  const bool coloured = m_current && m_runs && !m_runs->themes[theme()].isEmpty();
  if (coloured != m_coloured) {
    m_coloured = coloured;
    emit colouredChanged();
  }
}

void CodeHighlighter::highlightBlock(const QString& text) {
  if (!m_current || !m_runs) return;
  const QList<Run>& runs = m_runs->themes[theme()];
  const quint32 from = quint32(currentBlock().position());
  const quint32 to = from + quint32(text.size());
  // The runs are in order; the first that ends past this block's start.
  auto it = std::partition_point(runs.begin(), runs.end(), [from](const Run& run) { return run.start + run.length <= from; });
  for (; it != runs.end() && it->start < to; ++it) {
    const quint32 start = std::max(it->start, from);
    const quint32 end = std::min(it->start + it->length, to);
    QTextCharFormat format;
    format.setForeground(QColor::fromRgba(it->color));
    if (it->flags & 1) format.setFontWeight(QFont::Bold);
    if (it->flags & 2) format.setFontItalic(true);
    if (it->flags & 4) format.setFontUnderline(true);
    setFormat(int(start - from), int(end - start), format);
  }
}
