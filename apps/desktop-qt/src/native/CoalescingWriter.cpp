#include "CoalescingWriter.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMutex>
#include <QPromise>
#include <QSaveFile>
#include <QThreadPool>

#include <algorithm>
#include <memory>
#include <utility>

namespace {

// Writes the files apart from the app's other background work, so a long
// task there never holds a save back.
QThreadPool& pool() {
  static QThreadPool threads;
  return threads;
}

bool replace(const QString& path, const QByteArray& bytes) {
  QDir().mkpath(QFileInfo(path).absolutePath());
  QSaveFile file(path);
  return file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size() && file.commit();
}

// What the file took (nothing for a removal), or nothing at all: it failed.
std::optional<QByteArray> store(const QString& path, const CoalescingWriter::Content& content, const CoalescingWriter::Merge& merge) {
  const auto taken = [](bool ok, const QByteArray& bytes) { return ok ? std::optional(bytes) : std::nullopt; };
  // Gone, and not merely out of reach behind a file where its folder goes.
  if (!content) {
    if (QFile::remove(path)) return QByteArray();
    const QFileInfo folder(QFileInfo(path).absolutePath());
    return taken(!QFile::exists(path) && (folder.isDir() || !folder.exists()), {});
  }
  if (!merge) return taken(replace(path, *content), *content);
  // Another writer in this process reads only once this one has replaced the
  // file. Another process can still save between the read and the replace.
  static QMutex merging;
  const QMutexLocker hold(&merging);
  QFile file(path);
  std::optional<QByteArray> held;
  if (file.open(QIODevice::ReadOnly)) held = file.readAll();
  else if (file.exists()) return std::nullopt;
  const std::optional<QByteArray> merged = merge(*content, held);
  return merged ? taken(replace(path, *merged), *merged) : std::nullopt;
}

}  // namespace

CoalescingWriter::CoalescingWriter(QObject* parent) : QObject(parent) {
  m_timer.setSingleShot(true);
  connect(&m_timer, &QTimer::timeout, this, [this] {
    if (m_busy) m_due = true;
    else start();
  });
  connect(&m_watcher, &QFutureWatcherBase::finished, this, [this] {
    settle(false);
    // What came while it was on its way, and is already due.
    if (!m_busy && m_due) {
      m_due = false;
      start();
    }
  });
}

CoalescingWriter::~CoalescingWriter() {
  // Its owner is being destroyed: no one to tell of a failure.
  blockSignals(true);
  flush();
}

void CoalescingWriter::setPath(const QString& path) {
  if (path == m_path) return;
  flush();
  m_path = path;
  m_pending.reset();
  m_onDisk.reset();
}

void CoalescingWriter::put(Content content) {
  if (m_path.isEmpty()) return;
  if (!m_pending && !m_busy && known(content)) return;
  if (!m_pending) m_since.start();
  m_pending = std::move(content);
  m_timer.start(int(std::clamp<qint64>(kMaxDelayMs - m_since.elapsed(), 0, m_delay)));
}

void CoalescingWriter::start() {
  if (m_busy || !m_pending) return;
  Content content = *std::exchange(m_pending, std::nullopt);
  if (known(content)) return;
  auto promise = std::make_shared<QPromise<std::optional<QByteArray>>>();
  promise->start();
  m_busy = true;
  m_inFlightContent = content;
  m_inFlight = promise->future();
  m_watcher.setFuture(m_inFlight);
  pool().start([promise, path = m_path, content = std::move(content), merge = m_merge] {
    promise->addResult(store(path, content, merge));
    promise->finish();
  });
}

void CoalescingWriter::settle(bool wait) {
  if (!m_busy || (!wait && !m_inFlight.isFinished())) return;
  m_inFlight.waitForFinished();
  const std::optional<QByteArray> written = m_inFlight.resultCount() > 0 ? m_inFlight.result() : std::nullopt;
  m_busy = false;
  landed(m_inFlightContent, written.has_value());
  if (!written) emit failed();
  else if (m_inFlightContent) emit wrote(*m_inFlightContent, *written);
}

void CoalescingWriter::landed(const Content& content, bool ok) {
  if (ok) {
    m_onDisk = content;
    return;
  }
  m_onDisk.reset();
  // Tried again with the next write or flush, unless something newer replaces it.
  if (!m_pending) m_pending = content;
}

bool CoalescingWriter::writeNow(const QByteArray& bytes) {
  if (m_path.isEmpty()) return true;
  m_timer.stop();
  m_due = false;
  settle(true);
  const std::optional<Content> before = m_pending;
  m_pending = bytes;
  if (flush()) return true;
  // Its owner takes the change back: what was waiting before is still to be written, never this.
  m_pending = before;
  return false;
}

bool CoalescingWriter::flush() {
  m_timer.stop();
  m_due = false;
  settle(true);
  if (!m_pending || m_path.isEmpty()) return !m_pending;
  Content content = *std::exchange(m_pending, std::nullopt);
  if (!known(content)) landed(content, store(m_path, content, m_merge).has_value());
  return !m_pending;
}
