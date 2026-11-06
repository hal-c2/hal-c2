#pragma once

#include <QList>
#include <QString>

#include <algorithm>
#include <optional>

// The MC's requests that have waited too long for their answer, which the
// "Some requests are slow" warning lists (SlowRequestController). Told when a
// call starts and ends and what time it is (milliseconds, any epoch); a call
// is slow once it has waited its method's threshold: 15 s, or 2 min for a
// provider or server update, which install before they answer. Pull request
// lookups and subscriptions are never tracked, nor the usage summary. At most
// 256 calls are tracked: the oldest waiting one makes room.
class SlowRequests {
public:
  static constexpr qint64 kThresholdMs = 15'000;
  static constexpr qint64 kLongThresholdMs = 120'000;
  static constexpr qsizetype kMaxTracked = 256;

  struct Request {
    int id = 0;
    QString environment;
    QString method;
    qint64 startedAtMs = 0;
    qint64 thresholdMs = 0;
    bool operator==(const Request&) const = default;
  };

  static bool tracked(const QString& method) {
    return !method.contains(QLatin1String("subscribe")) && !method.startsWith(QLatin1String("pullRequests.")) &&
           method != QLatin1String("server.getUsageSummary") && method != QLatin1String("previewAutomation.connect");
  }

  static qint64 thresholdOf(const QString& method) {
    return method == QLatin1String("server.updateProvider") || method == QLatin1String("server.refreshProviders") ||
                   method == QLatin1String("server.updateServer")
               ? kLongThresholdMs
               : kThresholdMs;
  }

  // A call went out. True when the slow list changed (a slow one made room).
  bool start(int id, const QString& environment, const QString& method, qint64 nowMs) {
    if (!tracked(method)) return false;
    bool changed = end(id);
    if (m_waiting.size() + m_slow.size() >= kMaxTracked) {
      // The waiting ones go first; the slow ones are on screen.
      if (!m_waiting.isEmpty()) {
        m_waiting.removeFirst();
      } else {
        m_slow.removeFirst();
        changed = true;
      }
    }
    m_waiting.append({id, environment, method, nowMs, thresholdOf(method)});
    return changed;
  }

  // A call was answered, or failed. True when the slow list changed.
  bool end(int id) {
    const auto match = [id](const Request& request) { return request.id == id; };
    m_waiting.removeIf(match);
    return m_slow.removeIf(match) > 0;
  }

  // The time is `nowMs`: the calls that waited their threshold become slow.
  // True when the slow list changed.
  bool advance(qint64 nowMs) {
    bool changed = false;
    for (qsizetype index = 0; index < m_waiting.size();) {
      const Request& request = m_waiting.at(index);
      if (nowMs - request.startedAtMs >= request.thresholdMs) {
        m_slow.append(m_waiting.takeAt(index));
        changed = true;
      } else {
        ++index;
      }
    }
    return changed;
  }

  // When the next waiting call becomes slow, none when nothing waits.
  std::optional<qint64> nextDeadline() const {
    std::optional<qint64> next;
    for (const Request& request : m_waiting) {
      const qint64 deadline = request.startedAtMs + request.thresholdMs;
      if (!next || deadline < *next) next = deadline;
    }
    return next;
  }

  // The slow calls, in the order they became slow.
  const QList<Request>& slow() const { return m_slow; }
  qsizetype tracking() const { return m_waiting.size() + m_slow.size(); }

  // "2 requests waiting longer than 15s.": the smallest threshold they passed.
  QString description() const {
    if (m_slow.isEmpty()) return {};
    qint64 threshold = m_slow.first().thresholdMs;
    for (const Request& request : m_slow) threshold = std::min(threshold, request.thresholdMs);
    const qsizetype count = m_slow.size();
    return QStringLiteral("%1 request%2 waiting longer than %3s.")
        .arg(count)
        .arg(count == 1 ? QString() : QStringLiteral("s"))
        .arg((threshold + 500) / 1000);
  }

private:
  QList<Request> m_waiting;
  QList<Request> m_slow;
};
