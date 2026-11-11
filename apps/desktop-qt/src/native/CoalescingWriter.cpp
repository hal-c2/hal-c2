#include "CoalescingWriter.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
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

bool store(const QString& path, const CoalescingWriter::Content& content) {
  // Gone, and not merely out of reach behind a file where its folder goes.
  if (!content) {
    if (QFile::remove(path)) return true;
    const QFileInfo folder(QFileInfo(path).absolutePath());
    return !QFile::exists(path) && (folder.isDir() || !folder.exists());
  }
  QDir().mkpath(QFileInfo(path).absolutePath());
  QSaveFile file(path);
  return file.open(QIODevice::WriteOnly) && file.write(*content) == content->size() && file.commit();
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
  auto promise = std::make_shared<QPromise<bool>>();
  promise->start();
  m_busy = true;
  m_inFlightContent = content;
  m_inFlight = promise->future();
  m_watcher.setFuture(m_inFlight);
  pool().start([promise, path = m_path, content = std::move(content)] {
    promise->addResult(store(path, content));
    promise->finish();
  });
}

void CoalescingWriter::settle(bool wait) {
  if (!m_busy || (!wait && !m_inFlight.isFinished())) return;
  m_inFlight.waitForFinished();
  const bool ok = m_inFlight.resultCount() > 0 && m_inFlight.result();
  m_busy = false;
  landed(m_inFlightContent, ok);
  if (!ok) emit failed();
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
  if (!known(content)) landed(content, store(m_path, content));
  return !m_pending;
}
