#pragma once

#include <QColor>
#include <QPointer>
#include <QQuickTextDocument>
#include <QSyntaxHighlighter>

#include <memory>

struct HalC2Syntax;

// Code coloured by its language (native/syntax), on a TextEdit's document:
// a reply's or a page's code block, a file. QML:
//   CodeHighlighter { document: code.textDocument; language: "ts"; background: block.color }
//
// The code is read off the GUI thread; until it has been, it shows plain.
// While `streaming`, a last line without its newline waits, and each change
// reads only the lines added since the last. What was read is kept by
// language and text, so a block made again (a reply scrolled back into view)
// is coloured at once. Both the light and the dark colouring are kept; which
// one shows follows `background`, so a theme change reads nothing again.
//
// `path` names a file instead of a language (its name or extension picks the
// syntax). Unknown languages, and code past the first kMaxChars, stay plain.
class CodeHighlighter : public QSyntaxHighlighter {
  Q_OBJECT
  Q_PROPERTY(QQuickTextDocument* document READ quickDocument WRITE setQuickDocument NOTIFY documentChanged)
  Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY languageChanged)
  Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)
  Q_PROPERTY(QColor background READ background WRITE setBackground NOTIFY backgroundChanged)
  Q_PROPERTY(bool streaming READ streaming WRITE setStreaming NOTIFY streamingChanged)
  // Whether any of the text shows coloured now, and whether code is being read.
  Q_PROPERTY(bool coloured READ coloured NOTIFY colouredChanged)
  Q_PROPERTY(bool reading READ reading NOTIFY readingChanged)

public:
  static constexpr qsizetype kMaxChars = 512 * 1024;

  // A run of colour, as native/syntax hands it over.
  struct Run {
    quint32 start;
    quint32 length;
    quint32 color;
    quint8 flags;
  };
  // What reading some code made: its runs, light and dark.
  struct Runs {
    QList<Run> themes[2];
  };

  explicit CodeHighlighter(QObject* parent = nullptr);
  ~CodeHighlighter() override;

  QQuickTextDocument* quickDocument() const { return m_quickDocument; }
  void setQuickDocument(QQuickTextDocument* document);
  // A document C++ owns, in place of a TextEdit's.
  void setTextDocument(QTextDocument* document);
  QString language() const { return m_language; }
  void setLanguage(const QString& language);
  QString path() const { return m_path; }
  void setPath(const QString& path);
  QColor background() const { return m_background; }
  void setBackground(const QColor& background);
  bool streaming() const { return m_streaming; }
  void setStreaming(bool streaming);
  bool coloured() const { return m_coloured; }
  bool reading() const { return m_running; }

  // Drops what was kept of code already read (the native tests' fresh start).
  static void clearCache();
  // How many reads have started, ever (the native tests').
  static int readsStarted();

signals:
  void documentChanged();
  void languageChanged();
  void pathChanged();
  void backgroundChanged();
  void streamingChanged();
  void colouredChanged();
  void readingChanged();

protected:
  void highlightBlock(const QString& text) override;

private:
  struct SyntaxDeleter {
    void operator()(HalC2Syntax* syntax) const;
  };
  using Syntax = std::unique_ptr<HalC2Syntax, SyntaxDeleter>;
  struct Job;

  void setRunning(bool running);
  void textChanged();
  void restart();
  void schedule();
  void finished(const std::shared_ptr<Job>& job);
  void apply();
  void updateColoured();
  int theme() const;
  QString target() const;
  QString cacheKey(const QString& text) const;

  QPointer<QQuickTextDocument> m_quickDocument;
  QPointer<QTextDocument> m_attached;
  QString m_language;
  QString m_path;
  QColor m_background;
  bool m_streaming = false;
  bool m_coloured = false;

  // What the document holds, and whether `m_read` is the start of it.
  QString m_text;
  bool m_current = false;
  // The text read so far, its runs, and where reading it left off (null
  // after a fresh read of the whole text, which has nothing to go on from).
  QString m_read;
  std::shared_ptr<const Runs> m_runs;
  Syntax m_syntax;
  bool m_running = false;
  // The language has no syntax: nothing is read until it changes.
  bool m_unknown = false;
  // Lets a finished read find this highlighter only while it lives.
  std::shared_ptr<int> m_alive = std::make_shared<int>(0);
};
