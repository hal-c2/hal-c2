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

// The Agents tab: a thread's work in two sections, as the sidebar keeps its
// threads. Active on top: the subagents working, in the order they started,
// then the commands still running. Finished below: the settled subagents, the
// latest to end first. Read from the thread's timeline (its `subagent`
// entities and `command_execution` turn items) and updated in place as they
// change, rows moving between sections, so the list keeps its scroll.
//
// A running row's elapsed time moves once a second, and only while the tab
// shows (setActive) and something is running; a settled one stays at the
// time it took. When each ended is redrawn at midnight, when it shows.
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
    // active or finished
    SectionRole,
    // When a settled subagent ended, with its status: "Completed at 9:41 AM",
    // "Failed yesterday at 9:41 AM"; empty while it works.
    EndedRole,
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
  // When the tab next redraws its end times by itself: at local midnight, while
  // it shows, as "Completed at" becomes "yesterday"; invalid when it will not.
  QDateTime nextDay() const;
  // The end times read anew: the day, the time format or the locale changed.
  void redrawEnded();

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
  void apply(const QList<Row>& rows);
  void updateTimer();

  QString m_environment;
  QPointer<TimelineModel> m_timeline;
  QMetaObject::Connection m_connection;
  QMetaObject::Connection m_timesConnection;
  QList<Row> m_rows;
  bool m_active = false;
  QTimer m_timer;
  QTimer m_dayTimer;
  QDateTime m_nextDay;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
};
