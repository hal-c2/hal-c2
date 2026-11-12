#pragma once

#include <QByteArray>
#include <QElapsedTimer>
#include <QFuture>
#include <QFutureWatcher>
#include <QObject>
#include <QString>
#include <QTimer>

#include <functional>
#include <optional>

// Keeps one file holding the latest of what is written to it, without the GUI
// thread waiting on the disk (a QSaveFile commit fsyncs, which on a busy disk
// takes seconds). write() keeps the bytes and, once writes pause for delay()
// (and at most kMaxDelayMs after the first), replaces the file whole on a
// worker thread: a crash leaves the old file or the new one. One write is on
// its way at a time, so an older state never lands after a newer one, and what
// is written while one is on its way goes once it lands.
//
// flush() writes what is pending at once and waits for it; the destructor
// flushes, so nothing is lost at quit. writeNow() is for a change that must not
// be kept unless the disk has it (a stash, a new draft); one that fails is
// never written later. A write() that fails says failed() and stays pending:
// the next write or flush tries it again.
//
// A file other apps write too takes a merge (setMerge): what is given is then
// a change, put over what the file holds as the write goes.
class CoalescingWriter : public QObject {
  Q_OBJECT

 public:
  // The bytes to write, or nothing: the file is removed.
  using Content = std::optional<QByteArray>;
  // What to write, from what was given and what the file holds (nothing: there
  // is no file), made on the thread that writes. Nothing back fails the write
  // and leaves the file. Pure: it runs on any thread, and in this process one
  // merged write at a time reads, merges and replaces its file.
  using Merge = std::function<std::optional<QByteArray>(const QByteArray& given, const std::optional<QByteArray>& held)>;
  static constexpr int kDelayMs = 300;
  static constexpr int kMaxDelayMs = 2000;

  explicit CoalescingWriter(QObject* parent = nullptr);
  ~CoalescingWriter() override;

  // Where the content goes. What was pending for the old path is written there first.
  void setPath(const QString& path);
  QString path() const { return m_path; }
  void setDelay(int ms) { m_delay = ms; }
  // The file already holds `bytes` (read from it): writing them again is skipped.
  void setWritten(const QByteArray& bytes) { m_onDisk = Content(bytes); }
  // Writes go through `merge` from now on; a merged write is never skipped.
  void setMerge(Merge merge) { m_merge = std::move(merge); }

  void write(const QByteArray& bytes) { put(bytes); }
  void remove() { put(std::nullopt); }
  // Writes `bytes` before returning, after what is on its way; false if it
  // failed, and then `bytes` are dropped (the caller takes the change back).
  bool writeNow(const QByteArray& bytes);
  // Writes what is pending before returning; false if the file does not hold the latest.
  bool flush();
  // Nothing pending or on its way.
  bool idle() const { return !m_pending && !m_busy; }
  // A write is on its way.
  bool writing() const { return m_busy; }

 signals:
  // A write started off the GUI thread failed.
  void failed();
  // A write started off the GUI thread landed: `given` is what it was given,
  // and `written` what the file took (after a merge, what that made).
  void wrote(const QByteArray& given, const QByteArray& written);

 private:
  void put(Content content);
  void start();
  // Takes in the write on its way once it has landed, waiting for it if asked.
  void settle(bool wait);
  void landed(const Content& content, bool ok);
  // What another app wrote since may need the same change put over it again.
  bool known(const Content& content) const { return !m_merge && m_onDisk && *m_onDisk == content; }

  QString m_path;
  int m_delay = kDelayMs;
  Merge m_merge;
  QTimer m_timer;
  QElapsedTimer m_since;
  // What is still to be written, newest only.
  std::optional<Content> m_pending;
  // What the file was last written to hold, when that write succeeded.
  std::optional<Content> m_onDisk;
  bool m_busy = false;
  // The delay ran out while a write was on its way: the next goes once it lands.
  bool m_due = false;
  Content m_inFlightContent;
  // What the file took, or nothing: the write failed.
  QFuture<std::optional<QByteArray>> m_inFlight;
  QFutureWatcher<std::optional<QByteArray>> m_watcher;
};
