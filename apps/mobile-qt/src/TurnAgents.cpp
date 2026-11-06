#include "TurnAgents.h"

#include "SubagentDisplay.h"

#include <QSet>

#include <algorithm>


namespace {

const QSet<QString> kLive{QStringLiteral("pending"), QStringLiteral("running"), QStringLiteral("waiting")};
const QSet<QString> kRunActive{QStringLiteral("preparing"), QStringLiteral("starting"), QStringLiteral("running")};

QString text(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

QDateTime timeOf(const QJsonObject& object, QLatin1StringView field) {
  return QDateTime::fromString(text(object, field), Qt::ISODateWithMs);
}

// When it started, else when it was last heard from.
QDateTime orderOf(const QJsonObject& agent) {
  const QDateTime started = timeOf(agent, QLatin1String("startedAt"));
  return started.isValid() ? started : timeOf(agent, QLatin1String("updatedAt"));
}

QString statusLabel(const QString& status) {
  if (kLive.contains(status)) return QStringLiteral("Working");
  if (status == QLatin1String("idle")) return QStringLiteral("Idle · resumable");
  if (status == QLatin1String("completed")) return QStringLiteral("Completed");
  if (status == QLatin1String("failed")) return QStringLiteral("Failed");
  if (status == QLatin1String("cancelled") || status == QLatin1String("interrupted")) return QStringLiteral("Stopped");
  return {};
}

// 12s, 3m 04s, 1h 02m (AgentsModel's).
QString formatElapsed(qint64 total) {
  const qint64 seconds = std::max<qint64>(0, total);
  const qint64 minutes = seconds / 60;
  if (minutes == 0) return QStringLiteral("%1s").arg(seconds);
  const qint64 hours = minutes / 60;
  if (hours == 0) return QStringLiteral("%1m %2s").arg(minutes).arg(seconds % 60, 2, 10, QLatin1Char('0'));
  return QStringLiteral("%1h %2m").arg(hours).arg(minutes % 60, 2, 10, QLatin1Char('0'));
}

}  // namespace

TurnAgents::TurnAgents(QObject* parent) : QAbstractListModel(parent) {
  m_timer.setInterval(1000);
  connect(&m_timer, &QTimer::timeout, this, [this] {
    for (int row = 0; row < m_rows.size(); ++row) {
      if (kLive.contains(text(m_rows.at(row), QLatin1String("status")))) emit dataChanged(index(row), index(row), {ElapsedRole});
    }
  });
}

void TurnAgents::setTimeline(TimelineModel* timeline) {
  if (timeline == m_timeline) return;
  disconnect(m_connection);
  m_timeline = timeline;
  if (timeline) m_connection = connect(timeline, &TimelineModel::agentsChanged, this, &TurnAgents::read);
  emit timelineChanged();
  read();
}

void TurnAgents::setActive(bool active) {
  if (active == m_active) return;
  m_active = active;
  emit activeChanged();
  // Shown again, the times catch up at once.
  if (active && !m_rows.isEmpty()) emit dataChanged(index(0), index(int(m_rows.size()) - 1), {ElapsedRole});
  updateTimer();
}

void TurnAgents::read() {
  QList<QJsonObject> rows;
  bool turnActive = false;
  if (m_timeline) {
    const QString key = m_timeline->threadKey();
    m_environment = key.left(std::max<qsizetype>(0, key.lastIndexOf(QLatin1Char(':'))));
    const QHash<QString, QJsonObject> agents = m_timeline->entities(QStringLiteral("subagent"));
    // The running turn, the latest when several are.
    QString runId;
    double ordinal = -1;
    const QHash<QString, QJsonObject> runs = m_timeline->entities(QStringLiteral("run"));
    for (auto it = runs.cbegin(); it != runs.cend(); ++it) {
      if (!kRunActive.contains(text(*it, QLatin1String("status")))) continue;
      const double at = it->value(QLatin1String("ordinal")).toDouble();
      if (at > ordinal || (at == ordinal && it.key() > runId)) {
        ordinal = at;
        runId = it.key();
      }
    }
    turnActive = !runId.isEmpty();
    // Else the turn of the subagent heard from last: a turn that just ended
    // leaves results the user has not read yet.
    if (!turnActive) {
      QDateTime latest;
      QString latestId;
      for (auto it = agents.cbegin(); it != agents.cend(); ++it) {
        const QDateTime updated = timeOf(*it, QLatin1String("updatedAt"));
        if (latestId.isEmpty() || updated > latest || (updated == latest && it.key() > latestId)) {
          latest = updated;
          latestId = it.key();
          runId = text(*it, QLatin1String("runId"));
        }
      }
    }
    for (auto it = agents.cbegin(); it != agents.cend(); ++it) {
      if (runId.isEmpty() || text(*it, QLatin1String("runId")) != runId) continue;
      QJsonObject agent = *it;
      agent.insert(QStringLiteral("id"), it.key());
      rows.append(agent);
    }
    std::sort(rows.begin(), rows.end(), [](const QJsonObject& a, const QJsonObject& b) {
      const QDateTime left = orderOf(a);
      const QDateTime right = orderOf(b);
      return left != right ? left < right : text(a, QLatin1String("id")) < text(b, QLatin1String("id"));
    });
  }
  const int live = int(std::count_if(rows.cbegin(), rows.cend(), [](const QJsonObject& agent) {
    return kLive.contains(text(agent, QLatin1String("status")));
  }));
  QString summary;
  if (!rows.isEmpty() && (turnActive || live > 0)) {
    const int total = int(rows.size());
    summary = live > 0 ? QStringLiteral("%1 of %2 agents working").arg(live).arg(total)
                       : (total == 1 ? QStringLiteral("1 agent done") : QStringLiteral("%1 agents done").arg(total));
  }
  // A handful of rows, read anew: the list is small and opened for a glance.
  if (rows != m_rows) {
    beginResetModel();
    m_rows = rows;
    endResetModel();
  }
  const bool moved = summary != m_summary || live != m_live;
  m_summary = summary;
  m_live = live;
  if (moved) emit changed();
  updateTimer();
}

void TurnAgents::updateTimer() {
  if (m_active && m_live > 0) {
    if (!m_timer.isActive()) m_timer.start();
  } else {
    m_timer.stop();
  }
}

int TurnAgents::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : int(m_rows.size());
}

QVariant TurnAgents::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() >= m_rows.size()) return {};
  const QJsonObject& agent = m_rows.at(index.row());
  const QString status = text(agent, QLatin1String("status"));
  switch (role) {
    case IdRole:
      return text(agent, QLatin1String("id"));
    case TitleRole: {
      const QString title = subagents::displayTitle(text(agent, QLatin1String("title")).trimmed());
      if (!title.isEmpty()) return title;
      const QString prompt = text(agent, QLatin1String("prompt")).trimmed().section(QLatin1Char('\n'), 0, 0);
      return prompt.isEmpty() ? QStringLiteral("Subagent") : prompt;
    }
    case StatusRole:
      return status;
    case StatusLabelRole:
      return statusLabel(status);
    case RunningRole:
      return kLive.contains(status);
    case ElapsedRole: {
      const QDateTime started = timeOf(agent, QLatin1String("startedAt"));
      if (!started.isValid()) return QString();
      QDateTime ended = kLive.contains(status) ? m_now() : timeOf(agent, QLatin1String("completedAt"));
      if (!ended.isValid()) ended = timeOf(agent, QLatin1String("updatedAt"));
      return ended.isValid() ? formatElapsed(started.secsTo(ended)) : QString();
    }
    case ThreadRole: {
      const QString child = text(agent, QLatin1String("childThreadId"));
      return child.isEmpty() ? QString() : QStringLiteral("%1:%2").arg(m_environment, child);
    }
    default:
      return {};
  }
}

QHash<int, QByteArray> TurnAgents::roleNames() const {
  return {{IdRole, "agentId"},          {TitleRole, "title"},     {StatusRole, "status"}, {StatusLabelRole, "statusLabel"},
          {RunningRole, "running"},     {ElapsedRole, "elapsed"}, {ThreadRole, "thread"}};
}
