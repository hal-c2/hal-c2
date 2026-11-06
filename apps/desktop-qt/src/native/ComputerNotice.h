#pragma once

#include <QCoreApplication>
#include <QHash>
#include <QString>

#include <optional>

// What a thread says about the computer it runs on when that computer is a
// member of the cluster other than the one this client connects to, and the
// member is down (ComputerNoticeController; the window's own MC has the
// ConnectionNotice). The MC keeps trying to reach a member that is down, so
// down reads as reconnecting:
//
//   updating         an update of it is running: the update, not a warning
//   finishingUpdate  it runs another version than this app and no update is
//                    known to run, so it is most likely restarting into one
//   reconnecting     down for longer than two seconds
//   (empty)          down for less: the thread knows, and says nothing yet
//
// Told what each computer is (`see`) and what time it is (milliseconds, any
// epoch); the owner calls `advance` at `nextDeadline`.
class ComputerNotice {
  Q_DECLARE_TR_FUNCTIONS(ComputerNotice)

public:
  static constexpr qint64 kGraceMs = 2000;

  struct Computer {
    QString id;
    QString label;
    bool online = true;
    bool updating = false;
    // It runs another version than this app.
    bool otherVersion = false;
  };

  struct Notice {
    QString kind;
    QString environmentId;
    QString title;
    QString detail;
    bool operator==(const Notice&) const = default;
  };

  // A computer's state now; true when the notice changed.
  bool see(const Computer& computer, qint64 nowMs) {
    if (computer.online) {
      m_downSince.remove(computer.id);
    } else if (!m_downSince.contains(computer.id)) {
      m_downSince.insert(computer.id, nowMs);
    }
    m_computers.insert(computer.id, computer);
    return refresh(nowMs);
  }
  // The computer is gone from the cluster.
  bool forget(const QString& id, qint64 nowMs) {
    m_downSince.remove(id);
    m_computers.remove(id);
    return refresh(nowMs);
  }
  // The thread shown is on `id`; empty for none, or for the computer this
  // client connects to.
  bool show(const QString& id, qint64 nowMs) {
    m_shown = id;
    return refresh(nowMs);
  }
  bool advance(qint64 nowMs) { return refresh(nowMs); }

  // When the shown computer's grace ends, none when nothing waits on it.
  std::optional<qint64> nextDeadline(qint64 nowMs) const {
    const auto since = m_downSince.constFind(m_shown);
    if (since == m_downSince.cend() || !m_notice || !m_notice->kind.isEmpty()) return std::nullopt;
    const qint64 deadline = *since + kGraceMs;
    return deadline > nowMs ? std::optional<qint64>(deadline) : std::nullopt;
  }

  // None while the shown computer is up; its kind is empty in the grace.
  const std::optional<Notice>& notice() const { return m_notice; }

private:
  bool refresh(qint64 nowMs) {
    std::optional<Notice> next;
    const auto computer = m_computers.constFind(m_shown);
    if (!m_shown.isEmpty() && computer != m_computers.cend() && !computer->online) {
      const QString label = computer->label.isEmpty() ? computer->id : computer->label;
      if (computer->updating) {
        next = Notice{QStringLiteral("updating"), computer->id, tr("Updating %1").arg(label),
                      tr("%1 is restarting on the new version.").arg(label)};
      } else if (computer->otherVersion) {
        next = Notice{QStringLiteral("finishingUpdate"), computer->id, tr("Reconnecting to %1").arg(label),
                      tr("Finishing an update")};
      } else if (nowMs - m_downSince.value(computer->id, nowMs) >= kGraceMs) {
        next = Notice{QStringLiteral("reconnecting"), computer->id, tr("%1 is reconnecting").arg(label), {}};
      } else {
        next = Notice{{}, computer->id, {}, {}};
      }
    }
    if (next == m_notice) return false;
    m_notice = next;
    return true;
  }

  QHash<QString, Computer> m_computers;
  QHash<QString, qint64> m_downSince;
  QString m_shown;
  std::optional<Notice> m_notice;
};
