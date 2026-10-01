#pragma once

#include <QAbstractListModel>
#include <QDateTime>
#include <QJsonObject>
#include <QList>
#include <QMetaObject>
#include <QPointer>
#include <QTimer>

#include <functional>

class TimelineModel;

// The Agents tab: a thread's subagents, running and finished, in the order
// they started, then the commands still running. Read from the thread's
// timeline (its `subagent` entities and `command_execution` turn items) and
// updated as they change.
//
// A running row's elapsed time moves once a second, and only while the tab
// shows (setActive) and something is running; a settled one stays at the
// time it took.
class AgentsModel : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
  // Subagents listed (commands aside).
  Q_PROPERTY(int agentCount READ agentCount NOTIFY countChanged)

public:
  enum Role {
    IdRole = Qt::UserRole + 1,
    // subagent or command
    KindRole,
    // A subagent's title (its prompt's first line without one), a command's text.
    TitleRole,
    // The MC's status (pending, running, idle, completed, ...).
    StatusRole,
    // Working, Idle · resumable, Completed, Failed or Stopped.
    StatusLabelRole,
    RunningRole,
    // "12s", "3m 04s", "1h 02m": to now while running, else to when it ended.
    ElapsedRole,
    // What a subagent is doing (progress) or came to (result).
    DetailRole,
    ModelRole,
    // The thread the subagent's work is in ("<environment>:<thread id>"), or empty.
    ChildThreadKeyRole,
  };

  explicit AgentsModel(QObject* parent = nullptr);

  // The thread shown (its environment names the child threads) and its
  // timeline, which may come later than the thread.
  void setThread(const QString& environmentId, TimelineModel* timeline);
  void setActive(bool active);
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }
  // Whether the elapsed times are moving.
  bool ticking() const { return m_timer.isActive(); }
  // One second passing: running rows show their new elapsed time.
  void tick();

  int agentCount() const;
  Q_INVOKABLE int indexOf(const QString& id) const;
  QVariant value(int row, int role) const { return data(index(row), role); }

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

signals:
  void countChanged();

private:
  struct Row {
    QString id;
    QString kind;
    QJsonObject entity;
  };

  void read();
  void updateTimer();

  QString m_environment;
  QPointer<TimelineModel> m_timeline;
  QMetaObject::Connection m_connection;
  QList<Row> m_rows;
  bool m_active = false;
  QTimer m_timer;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
};
