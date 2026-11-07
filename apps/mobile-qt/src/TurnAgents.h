#pragma once

#include <QAbstractListModel>
#include <QDateTime>
#include <QJsonObject>
#include <QList>
#include <QMetaObject>
#include <QPointer>
#include <QTimer>

#include <functional>

#include "TimelineModel.h"

// The subagents of a thread's latest turn, which the phone's thread shows
// above its composer (packages/client-runtime/src/state/threadSubagents.ts):
// the running turn's, else the turn of the subagent heard from last, in the
// order they started. `summary` reads "2 of 3 agents working" while any works,
// "3 agents done" once all finished and the turn has not, and nothing once the
// turn settled with none working. Its rows are the list the summary opens
// (ThreadAgentsSheet): a provider-managed subagent has no thread to open.
//
// Read again from the timeline whenever its subagents or runs change. A
// working row's elapsed time moves once a second, only while the list shows
// (`active`).
class TurnAgents : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(TimelineModel* timeline READ timeline WRITE setTimeline NOTIFY timelineChanged)
  Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
  Q_PROPERTY(int count READ rowCount NOTIFY changed)
  Q_PROPERTY(QString summary READ summary NOTIFY changed)

public:
  enum Role {
    IdRole = Qt::UserRole + 1,
    TitleRole,
    StatusRole,
    // Working, Idle · resumable, Completed, Failed or Stopped.
    StatusLabelRole,
    RunningRole,
    // "12s", "1m 15s": to now while it works, else to when it ended.
    ElapsedRole,
    // Its thread ("<environment>:<thread id>"), empty for one the provider manages.
    ThreadRole,
  };

  explicit TurnAgents(QObject* parent = nullptr);

  TimelineModel* timeline() const { return m_timeline; }
  void setTimeline(TimelineModel* timeline);
  bool active() const { return m_active; }
  void setActive(bool active);
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }
  QString summary() const { return m_summary; }
  // The turn's agents counted: working, and in all.
  int live() const { return m_live; }
  QVariant value(int row, int role) const { return data(index(row), role); }

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

signals:
  void timelineChanged();
  void activeChanged();
  void changed();

private:
  void read();
  void updateTimer();

  QPointer<TimelineModel> m_timeline;
  QMetaObject::Connection m_connection;
  QString m_environment;
  QList<QJsonObject> m_rows;
  QString m_summary;
  int m_live = 0;
  bool m_active = false;
  QTimer m_timer;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
};
