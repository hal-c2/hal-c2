#include "CodeReader.h"

#include <QCache>
#include <QCoreApplication>
#include <QPointer>
#include <QThreadPool>

#include <algorithm>
#include <atomic>

#include "hal_c2_syntax.h"

namespace codereader {

namespace {

// Readers for the whole app, two at a time at most. Its children are deleted
// with the app, after waiting for what they read.
QThreadPool* readers() {
  static QPointer<QThreadPool> pool;
  if (!pool) {
    pool = new QThreadPool(QCoreApplication::instance());
    pool->setMaxThreadCount(2);
  }
  return pool;
}

struct Cached {
  std::shared_ptr<const Runs> runs;
};
QCache<QString, Cached>& cache() {
  static QCache<QString, Cached> cache(32 * 1024 * 1024);
  return cache;
}

std::atomic<quint64> requests{0};
std::atomic<quint64> starts{0};

void collect(void* context, const HalC2SyntaxSpan* span) {
  auto* runs = static_cast<Runs*>(context);
  runs->themes[span->theme & 1].append({span->start, span->length, span->color, span->flags});
}

void escape(QString& out, QStringView text) {
  for (const QChar c : text) {
    switch (c.unicode()) {
    case u'<': out += QLatin1String("&lt;"); break;
    case u'>': out += QLatin1String("&gt;"); break;
    case u'&': out += QLatin1String("&amp;"); break;
    // StyledText runs spaces together and drops tabs; these keep them as
    // plain text draws them.
    case u' ': out += QLatin1String("&nbsp;"); break;
    case u'\t': out += QLatin1String("&#9;"); break;
    default: out += c;
    }
  }
}

}  // namespace

void SyntaxDeleter::operator()(HalC2Syntax* syntax) const {
  hal_c2_syntax_free(syntax);
}

void Job::run() {
  if (!syntax) {
    syntax.reset(byPath ? hal_c2_syntax_for_path(language.constData(), size_t(language.size()))
                        : hal_c2_syntax_for_language(language.constData(), size_t(language.size())));
    if (!syntax) {
      known = false;
      return;
    }
  }
  auto out = std::make_shared<Runs>(runs ? *runs : Runs{});
  const QByteArray code = delta.toUtf8();
  hal_c2_syntax_feed(syntax.get(), code.constData(), size_t(code.size()), collect, out.get());
  runs = std::move(out);
}

void start(const std::shared_ptr<Job>& job, std::weak_ptr<int> alive, std::function<void(const std::shared_ptr<Job>&)> done) {
  ++requests;
  QThreadPool* pool = readers();
  pool->start([job, alive = std::move(alive), done = std::move(done), pool] {
    // Its reader went while it waited, as a code block scrolled past does.
    if (alive.expired()) return;
    ++starts;
    job->run();
    QMetaObject::invokeMethod(pool, [job, alive, done] {
      if (alive.lock()) done(job);
      // Gone while it was read: what it read is kept for when it is back.
      else if (job->known && !job->key.isEmpty()) keep(job->key, job->runs);
    }, Qt::QueuedConnection);
  });
}

quint64 requested() {
  return requests.load();
}

quint64 started() {
  return starts.load();
}

QString cacheKey(const QString& language, const QString& path, const QString& text) {
  return (path.isEmpty() ? QStringLiteral("l:") + language : QStringLiteral("p:") + path) + QChar(0) + text;
}

std::shared_ptr<const Runs> cached(const QString& key) {
  const Cached* hit = cache().object(key);
  return hit ? hit->runs : nullptr;
}

void keep(const QString& key, const std::shared_ptr<const Runs>& runs) {
  qsizetype cost = key.size() * qsizetype(sizeof(QChar));
  for (const auto& theme : runs->themes) cost += theme.size() * qsizetype(sizeof(Run));
  cache().insert(key, new Cached{runs}, cost);
}

void clearCache() {
  cache().clear();
}

int themeFor(const QColor& background) {
  return background.isValid() && background.lightnessF() >= 0.5 ? 0 : 1;
}

QString styled(const QString& text, qsizetype from, qsizetype length, const QList<Run>& runs) {
  QString out;
  out.reserve(length * 2);
  const qsizetype to = from + length;
  qsizetype at = from;
  // The runs are in order; the first that ends past `from`.
  auto it = std::partition_point(runs.begin(), runs.end(), [from](const Run& run) { return qsizetype(run.start) + run.length <= from; });
  for (; it != runs.end() && qsizetype(it->start) < to; ++it) {
    const qsizetype start = std::max<qsizetype>(it->start, at);
    const qsizetype end = std::min<qsizetype>(qsizetype(it->start) + it->length, to);
    if (end <= start) continue;
    escape(out, QStringView(text).mid(at, start - at));
    const QColor colour = QColor::fromRgba(it->color);
    out += QLatin1String("<font color=\"") + colour.name(colour.alpha() == 255 ? QColor::HexRgb : QColor::HexArgb) + QLatin1String("\">");
    if (it->flags & 1) out += QLatin1String("<b>");
    if (it->flags & 2) out += QLatin1String("<i>");
    if (it->flags & 4) out += QLatin1String("<u>");
    escape(out, QStringView(text).mid(start, end - start));
    if (it->flags & 4) out += QLatin1String("</u>");
    if (it->flags & 2) out += QLatin1String("</i>");
    if (it->flags & 1) out += QLatin1String("</b>");
    out += QLatin1String("</font>");
    at = end;
  }
  escape(out, QStringView(text).mid(at, to - at));
  return out;
}

}  // namespace codereader
