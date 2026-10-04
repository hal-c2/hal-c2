#pragma once

#include <QAbstractListModel>
#include <QDateTime>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QLocale>
#include <QSet>
#include <QStringList>
#include <QVariant>

#include <functional>

// One thread's timeline: the MC's `stream` shape folded into its entities
// (packages/client-runtime/src/v3/threadShape.ts) and projected into rows
// (apps/tui/src/timeline.ts, apps/web/src/components/chat/MessagesTimeline.logic.ts).
//
// Rows are messages, groups of consecutive tool calls (the latest shown, the
// rest behind "+N previous tool calls"), folds of settled turns ("Worked for
// 2m"), plan cards, subagents, errors and context markers. Each row keeps its
// id across updates. Streamed text and output only touch the row that shows
// the item (dataChanged); new items, visibility and run changes re-derive the
// row list once per frame and apply it as inserts, removes and moves.
class TimelineModel : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(QString threadKey READ threadKey CONSTANT)
  Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
  Q_PROPERTY(QString status READ status NOTIFY statusChanged)
  Q_PROPERTY(QString problem READ problem NOTIFY statusChanged)
  Q_PROPERTY(bool working READ working NOTIFY workingChanged)
  Q_PROPERTY(QDateTime workingSince READ workingSince NOTIFY workingChanged)

public:
  enum Role {
    IdRole = Qt::UserRole + 1,
    // message, work, fold, plan, subagent, error or marker
    KindRole,
    // A message's: user or assistant.
    AuthorRole,
    // A message's text, a plan's markdown under its title, an error's
    // message, a marker's or subagent's detail.
    TextRole,
    StreamingRole,
    // A fold's, plan's, marker's or subagent's heading.
    TitleRole,
    StatusRole,
    // What the row's status reads as ("Working", "Failed", ...).
    StatusLabelRole,
    // How a user message reached the agent, when not as a new turn.
    MarkerRole,
    // A work group's calls on screen: [{id, type, label, detail, command,
    // status, statusLabel, exitCode, path (a changed file's)}].
    EntriesRole,
    // A work group's calls behind "+N previous tool calls", a fold's rows.
    HiddenCountRole,
    ExpandedRole,
    // The files an assistant reply's turn changed: [{path, additions, deletions}].
    FilesRole,
    // When the row happened, as the web's formatDayAwareTimestamp reads it in
    // the device's timestampFormat: "9:41 AM", "yesterday at 9:41 AM",
    // "9/20 9:41 AM". A reply's once it has finished streaming; empty when
    // the MC sent no time.
    TimeRole,
    // The lucide icon of a marker, error or subagent row (a call's is its
    // entry's `icon`), after the web's workEntryIconName.
    IconRole,
    // A user message's inputIntent: queued_turn, steer,
    // promoted_queued_to_steer or empty.
    IntentRole,
    // Who sent a user message when not the user: "Sent by automation",
    // "From <thread>" for an agent whose thread is known (ThreadRole opens
    // it), "Sent by another agent", or empty.
    AttributionRole,
    // Whether an assistant reply carries its time and actions: a settled
    // turn's last reply does, commentary before it does not (the web's
    // showAssistantMeta).
    MetaRole,
    // What a settled turn's group of calls did, in a sentence ("Ran 2 commands
    // and sent messages to 3 threads", TimelineSummary.h): the group collapses
    // into it and opens into its calls. Empty for a single call and while the
    // turn runs, when the latest call shows instead.
    SummaryRole,
    // Whether a call the group's summary counts failed.
    SummaryFailedRole,
    // The id of the thread a row leads to: a subagent's own thread, or the
    // thread of the agent that sent a message. Empty when there is none.
    ThreadRole,
    // The model a subagent runs on (its `subagent` entity's), or empty.
    ModelRole,
    // The first pull (or merge) request address a message mentions, for
    // linking it to the thread; empty when it mentions none.
    PullRequestUrlRole,
  };

  // Calls shown per collapsed work group.
  static constexpr int visibleWorkEntries = 1;

  explicit TimelineModel(const QString& threadKey, QObject* parent = nullptr);

  QString threadKey() const { return m_threadKey; }
  // loading until the first snapshot lands, live, or unreachable (with the
  // MC's reason in `problem`). Rows stay while it reloads or is unreachable.
  QString status() const { return m_status; }
  QString problem() const { return m_problem; }
  void setStatus(const QString& status, const QString& problem = {});
  bool working() const { return m_workingSince.isValid(); }
  QDateTime workingSince() const { return m_workingSince; }
  // "Working for 12s", from the clock; the brick asks once a second.
  Q_INVOKABLE QString workingLabel() const;
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }
  // Names another thread of this one's environment by id, for messages its
  // agent sent here; empty when the thread is not known.
  void setThreadTitles(std::function<QString(const QString& threadId)> titleOf) { m_threadTitle = std::move(titleOf); }
  // The device's timestampFormat (locale, 12-hour, 24-hour) and the locale
  // times are read in; a change redraws every row's time.
  void setTimestampFormat(const QString& format);
  void setLocale(const QLocale& locale);
  // The long form of a row's time, or of one of its calls' (`entryId`), for
  // its tooltip: "9:41 AM, 23rd September 2026".
  Q_INVOKABLE QString timeTitle(const QString& rowId, const QString& entryId = {}) const;

  // A `snapshot` frame's part: part 0 starts over, `done` swaps it in.
  void snapshot(int part, const QJsonArray& rows, bool done);
  // An `events` frame: [[seq, kind, id, patch, at]].
  void events(const QJsonArray& events);

  // The thread's entities of one stream kind (run, runtime-request, plan,
  // turn-item, ...) by id, for the composer's turn state.
  QHash<QString, QJsonObject> entities(const QString& kind) const { return m_entities.value(kind); }

  // Opens or closes a fold ("fold:<runId>") or a work group ("work:<itemId>").
  Q_INVOKABLE void toggle(const QString& rowId);
  // The user stopped this run here: once it settles its work stays open, fold
  // and calls, so they see where it stopped. A stop from elsewhere, or one a
  // restart forgot, folds as any turn does; toggle() still closes it.
  void keepOpen(const QString& runId);
  Q_INVOKABLE int indexOf(const QString& rowId) const;
  // The checkpoint an agent reply's settled turn left, to revert the thread
  // to: {checkpointId, scopeId, turn} (turn counts from 1), or empty.
  Q_INVOKABLE QVariantMap checkpointOf(const QString& rowId) const;
  // Puts a message's markdown on the clipboard; false for any other row.
  Q_INVOKABLE bool copy(const QString& rowId) const;

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

signals:
  void countChanged();
  void statusChanged();
  void workingChanged();
  // After a snapshot, or events that touched runs, requests, plans or the
  // request and user message items: what entities() gives the composer.
  void turnChanged();
  // After a snapshot, or events that touched checkpoints: what
  // entities("checkpoint") gives the diff panel.
  void checkpointsChanged();
  // After a snapshot, or events that touched subagents, runs or commands
  // starting and settling: what the Agents tab lists.
  void agentsChanged();

private:
  struct Row {
    QString id;
    QString kind;
    // The turn items it shows, oldest first: a message's one, a group's calls.
    QStringList items;
    // A reply's: the checkpoint item whose files it lists.
    QString checkpoint;
    // A fold's.
    QString label;
    int hidden = 0;
    bool expanded = false;
    // A fold's: when its turn started.
    QDateTime at;
    // A reply's: whether it is its settled turn's last.
    bool meta = false;
    // A work group's: its turn settled and it has several calls, so it
    // collapses into its summary.
    bool summarized = false;
    // A work group's: its run was stopped here, so it starts open.
    bool startsOpen = false;

    bool operator==(const Row&) const = default;
  };

  using Entities = QHash<QString, QHash<QString, QJsonObject>>;

  QJsonObject entity(const QString& kind, const QString& id) const { return m_entities.value(kind).value(id); }
  // Applies one event; true when the row list has to be derived again.
  bool apply(const QString& kind, const QString& id, const QJsonObject& patch, QSet<QString>& changed);
  void place(const QString& itemId);
  void unplace(const QString& itemId);
  void sortItems();
  void restructure(const QSet<QString>& changed, bool all);
  QList<Row> project() const;
  void applyRows(const QList<Row>& rows, const QSet<QString>& changed, bool all);
  void updateWorking();
  QVariantMap entry(const QJsonObject& item) const;
  // When a row or turn item happened, or invalid.
  QDateTime rowTime(const Row& row) const;
  QString stamp(const QDateTime& at) const;
  void redrawTimes();

  QString m_threadKey;
  QString m_status = QStringLiteral("loading");
  QString m_problem;
  Entities m_entities;
  // A snapshot arriving in parts.
  Entities m_incoming;
  // Turn item ids by (ordinal, id).
  QStringList m_order;
  QList<Row> m_rows;
  QHash<QString, int> m_rowOfItem;
  QSet<QString> m_expandedFolds;   // run ids
  // Work groups the user toggled, by row id: open ones, or closed ones of a
  // run stopped here (Row::startsOpen).
  QSet<QString> m_expandedGroups;
  QSet<QString> m_keptOpen;  // run ids
  QDateTime m_workingSince;
  bool m_turnTouched = false;
  bool m_checkpointsTouched = false;
  bool m_agentsTouched = false;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  std::function<QString(const QString&)> m_threadTitle;
  QString m_timestampFormat = QStringLiteral("locale");
  QLocale m_locale;
};
