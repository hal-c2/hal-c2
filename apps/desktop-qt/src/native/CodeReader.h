#pragma once

#include <QColor>
#include <QList>
#include <QString>

#include <functional>
#include <memory>

struct HalC2Syntax;

// Code read for its colours by native/syntax (hal_c2_syntax.h), off the GUI
// thread, for whatever draws it: a code block's CodeHighlighter, the file
// viewer's lines (TextLinesModel). One read gives the runs of both the light
// and the dark theme, so a theme switch reads nothing again.
//
//   auto job = std::make_shared<codereader::Job>();
//   job->byPath = true; job->language = path.toUtf8(); job->delta = text;
//   codereader::start(job, alive, [this](const auto& job) { ... job->runs ... });
//
// What was read whole is kept by language or path and text (cached/keep), up
// to about 32 MB, so the same code drawn again is coloured at once.
namespace codereader {

// The most of a text that is read; past it, code stays plain.
inline constexpr qsizetype kMaxChars = 512 * 1024;

// A run of colour, as native/syntax hands it over: UTF-16 offsets from the
// start of all that was read, 0xAARRGGBB, flags 1 bold, 2 italic, 4 underline.
struct Run {
  quint32 start;
  quint32 length;
  quint32 color;
  quint8 flags;
};
// What reading some code made: its runs, light (0) and dark (1).
struct Runs {
  QList<Run> themes[2];
};

struct SyntaxDeleter {
  void operator()(HalC2Syntax* syntax) const;
};
using Syntax = std::unique_ptr<HalC2Syntax, SyntaxDeleter>;

// One read: what to go on from, what to read, and what came of it. `run`
// reads `delta` after `base` (whose syntax state `syntax` holds, and whose
// runs `runs` are), or from the start when `syntax` is null.
struct Job {
  QByteArray language;
  bool byPath = false;
  Syntax syntax;
  QString base;
  QString delta;
  std::shared_ptr<const Runs> runs;
  // Whether the language or path has a syntax at all.
  bool known = true;
  // Where a whole read of text not being written is kept, else empty. Kept
  // by `start` when its reader went while it was read (the reader keeps it
  // itself otherwise), so it is coloured at once when it is back.
  QString key;

  void run();
};

// Runs `job` on the readers (two threads for the whole app), then `done` on
// the GUI thread, unless `alive` has expired by then. A job whose `alive`
// expired before a reader took it up is not read at all: what is still shown
// is read first.
void start(const std::shared_ptr<Job>& job, std::weak_ptr<int> alive, std::function<void(const std::shared_ptr<Job>&)> done);
// How many reads were asked for (`start`), and how many a reader took up,
// since the app started: the tests' ways to see that none was.
quint64 requested();
quint64 started();

// The key `text` is kept by: a language, or a file's path.
QString cacheKey(const QString& language, const QString& path, const QString& text);
std::shared_ptr<const Runs> cached(const QString& key);
void keep(const QString& key, const std::shared_ptr<const Runs>& runs);
void clearCache();

// The runs a background shows: 0, light, for a light one, else 1, dark.
int themeFor(const QColor& background);

// `length` units of `text` from `from` as StyledText, coloured by `runs`
// (whose offsets count from the start of `text`). Spaces and tabs are kept,
// the markup's characters escaped.
QString styled(const QString& text, qsizetype from, qsizetype length, const QList<Run>& runs);

}  // namespace codereader
