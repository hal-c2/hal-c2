#include "AgentsModel.h"

#include <QSet>

#include <algorithm>

#include "TimelineModel.h"

namespace {

const QSet<QString> kLive{QStringLiteral("pending"), QStringLiteral("running"), QStringLiteral("waiting")};

QString text(const QJsonObject& object, QLatin1StringView field) {
  return object.value(field).toString();
}

QDateTime timeOf(const QJsonObject& object, QLatin1StringView field) {
  return QDateTime::fromString(text(object, field), Qt::ISODateWithMs);
}

// apps/web/src/components/chat/V2LifecycleRow.tsx STATUS_VISUALS.
QString statusLabel(const QString& status) {
  if (kLive.contains(status)) return QStringLiteral("Working");
  if (status == QLatin1String("idle")) return QStringLiteral("Idle · resumable");
  if (status == QLatin1String("completed")) return QStringLiteral("Completed");
  if (status == QLatin1String("failed")) return QStringLiteral("Failed");
  if (status == QLatin1String("cancelled") || status == QLatin1String("interrupted")) return QStringLiteral("Stopped");
  return {};
}

// The web's AgentsPanel formatElapsedSeconds: 12s, 3m 04s, 1h 02m.
QString formatElapsed(qint64 total) {
  const qint64 seconds = std::max<qint64>(0, total);
  const qint64 minutes = seconds / 60;
  if (minutes == 0) return QStringLiteral("%1s").arg(seconds);
  const qint64 hours = minutes / 60;
  if (hours == 0) return QStringLiteral("%1m %2s").arg(minutes).arg(seconds % 60, 2, 10, QLatin1Char('0'));
  return QStringLiteral("%1h %2m").arg(hours).arg(minutes % 60, 2, 10, QLatin1Char('0'));
}

}  // namespace

AgentsModel::AgentsModel(QObject* parent) : QAbstractListModel(parent) {
  m_timer.setInterval(1000);
  connect(&m_timer, &QTimer::timeout, this, &AgentsModel::tick);
}

void AgentsModel::setThread(const QString& environmentId, TimelineModel* timeline) {
  if (environmentId == m_environment && timeline == m_timeline) return;
  m_environment = environmentId;
  disconnect(m_connection);
  m_timeline = timeline;
  if (timeline) m_connection = connect(timeline, &TimelineModel::agentsChanged, this, &AgentsModel::read);
  read();
}

void AgentsModel::setActive(bool active) {
  if (active == m_active) return;
  m_active = active;
  // Hidden, the times stood still; shown, they catch up at once.
  if (active) tick();
  updateTimer();
}

void AgentsModel::read() {
  QList<Row> rows;
  if (m_timeline) {
    const QHash<QString, QJsonObject> agents = m_timeline->entities(QStringLiteral("subagent"));
    for (auto it = agents.cbegin(); it != agents.cend(); ++it) rows.append({it.key(), QStringLiteral("subagent"), it.value()});
    // Spawn order, which settling does not change.
    std::sort(rows.begin(), rows.end(), [](const Row& a, const Row& b) {
      const QString left = text(a.entity, QLatin1String("startedAt"));
      const QString right = text(b.entity, QLatin1String("startedAt"));
      return left != right ? left < right : a.id < b.id;
    });
    QSet<QString> rolledBack;
    const QHash<QString, QJsonObject> runs = m_timeline->entities(QStringLiteral("run"));
    for (auto it = runs.cbegin(); it != runs.cend(); ++it) {
      if (text(it.value(), QLatin1String("status")) == QLatin1String("rolled_back")) rolledBack.insert(it.key());
    }
    QList<Row> commands;
    const QHash<QString, QJsonObject> items = m_timeline->entities(QStringLiteral("turn-item"));
    for (auto it = items.cbegin(); it != items.cend(); ++it) {
      const QJsonObject& item = it.value();
      if (text(item, QLatin1String("type")) != QLatin1String("command_execution")) continue;
      if (!kLive.contains(text(item, QLatin1String("status")))) continue;
      if (rolledBack.contains(text(item, QLatin1String("runId")))) continue;
      commands.append({it.key(), QStringLiteral("command"), item});
    }
    std::sort(commands.begin(), commands.end(), [](const Row& a, const Row& b) {
      const double left = a.entity.value(QLatin1String("ordinal")).toDouble();
      const double right = b.entity.value(QLatin1String("ordinal")).toDouble();
      return left != right ? left < right : a.id < b.id;
    });
    rows.append(commands);
  }

  // Rows that stay in place are redrawn; new ones at the end are inserted;
  // anything else (a row gone, one in between) starts the list over.
  const qsizetype before = m_rows.size();
  bool prefix = rows.size() >= before;
  for (qsizetype i = 0; prefix && i < before; ++i) prefix = rows.at(i).id == m_rows.at(i).id;
  if (!prefix) {
    beginResetModel();
    m_rows = rows;
    endResetModel();
  } else {
    for (qsizetype i = 0; i < before; ++i) {
      if (rows.at(i).entity == m_rows.at(i).entity) continue;
      m_rows[i] = rows.at(i);
      emit dataChanged(index(int(i)), index(int(i)));
    }
    if (rows.size() > before) {
      beginInsertRows({}, int(before), int(rows.size() - 1));
      m_rows = rows;
      endInsertRows();
    }
  }
  if (m_rows.size() != before || !prefix) emit countChanged();
  updateTimer();
}

void AgentsModel::tick() {
  for (qsizetype i = 0; i < m_rows.size(); ++i) {
    if (kLive.contains(text(m_rows.at(i).entity, QLatin1String("status")))) {
      emit dataChanged(index(int(i)), index(int(i)), {ElapsedRole});
    }
  }
}

void AgentsModel::updateTimer() {
  const bool running = std::any_of(m_rows.cbegin(), m_rows.cend(), [](const Row& row) {
    return kLive.contains(text(row.entity, QLatin1String("status")));
  });
  if (m_active && running) {
    if (!m_timer.isActive()) m_timer.start();
  } else {
    m_timer.stop();
  }
}

int AgentsModel::agentCount() const {
  return int(std::count_if(m_rows.cbegin(), m_rows.cend(), [](const Row& row) { return row.kind == QLatin1String("subagent"); }));
}

int AgentsModel::indexOf(const QString& id) const {
  for (qsizetype i = 0; i < m_rows.size(); ++i) {
    if (m_rows.at(i).id == id) return int(i);
  }
  return -1;
}

int AgentsModel::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : int(m_rows.size());
}

QVariant AgentsModel::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() >= m_rows.size()) return {};
  const Row& row = m_rows.at(index.row());
  const QJsonObject& entity = row.entity;
  const QString status = text(entity, QLatin1String("status"));
  const bool live = kLive.contains(status);
  const bool agent = row.kind == QLatin1String("subagent");
  switch (role) {
    case IdRole:
      return row.id;
    case KindRole:
      return row.kind;
    case TitleRole: {
      if (!agent) return text(entity, QLatin1String("input")).trimmed();
      const QString title = text(entity, QLatin1String("title")).trimmed();
      if (!title.isEmpty()) return title;
      const QString prompt = text(entity, QLatin1String("prompt")).trimmed().section(QLatin1Char('\n'), 0, 0);
      return prompt.isEmpty() ? QStringLiteral("Subagent") : prompt;
    }
    case StatusRole:
      return status;
    case StatusLabelRole:
      return statusLabel(status);
    case RunningRole:
      return live;
    case ElapsedRole: {
      const QDateTime started = timeOf(entity, QLatin1String("startedAt"));
      if (!started.isValid()) return QString();
      QDateTime ended = live ? m_now() : timeOf(entity, QLatin1String("completedAt"));
      if (!ended.isValid()) ended = timeOf(entity, QLatin1String("updatedAt"));
      return ended.isValid() ? formatElapsed(started.secsTo(ended)) : QString();
    }
    case DetailRole: {
      if (!agent) return QString();
      const QString progress = text(entity, QLatin1String("progress")).trimmed();
      const QString result = text(entity, QLatin1String("result")).trimmed();
      if (live) return progress.isEmpty() ? result : progress;
      return result.isEmpty() ? progress : result;
    }
    case ModelRole:
      return text(entity, QLatin1String("model"));
    case ChildThreadKeyRole: {
      const QString child = text(entity, QLatin1String("childThreadId"));
      return agent && !child.isEmpty() ? QStringLiteral("%1:%2").arg(m_environment, child) : QString();
    }
    default:
      return {};
  }
}

QHash<int, QByteArray> AgentsModel::roleNames() const {
  return {
      {IdRole, "agentId"},
      {KindRole, "kind"},
      {TitleRole, "title"},
      {StatusRole, "status"},
      {StatusLabelRole, "statusLabel"},
      {RunningRole, "running"},
      {ElapsedRole, "elapsed"},
      {DetailRole, "detail"},
      {ModelRole, "modelName"},
      {ChildThreadKeyRole, "childThreadKey"},
  };
}
