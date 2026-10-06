#pragma once

#include <QAbstractListModel>
#include <QDateTime>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QLocale>
#include <QSet>
#include <QPair>
#include <QStringList>
#include <QTimer>
#include <QUrl>
#include <QVariant>

#include <functional>

#include "LocalCache.h"

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
//
// The model owns where its copy of the thread stands (cache::Cursor): the MC
// log it follows, the offset it reflects and the window it holds. A thread
// opens as its newest turns (windowItems); loadEarlier() adds the ones before.
// Every frame leaves the copy whole as of its offset, and what changed goes
// to the LocalCache with that offset, so a thread opened again (after a
// reconnect, an eviction or a restart) is restored and sent only what it lacks.
class TimelineModel : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(QString threadKey READ threadKey CONSTANT)
  Q_PROPERTY(int count READ rowCount NOTIFY countChanged)
  Q_PROPERTY(QString status READ status NOTIFY statusChanged)
  Q_PROPERTY(QString problem READ problem NOTIFY statusChanged)
  Q_PROPERTY(bool working READ working NOTIFY workingChanged)
  Q_PROPERTY(QDateTime workingSince READ workingSince NOTIFY workingChanged)
  Q_PROPERTY(bool hasEarlier READ hasEarlier NOTIFY earlierChanged)
  Q_PROPERTY(bool loadingEarlier READ loadingEarlier NOTIFY earlierChanged)

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
    // An assistant reply's message, which a quote of it names as its source.
    MessageIdRole,
    // A user message's images: [{id, name, url}]. `url` is empty until the
    // brick asks for it (loadAttachment) and the MC has signed one.
    AttachmentsRole,
  };

  // Calls shown per collapsed work group.
  static constexpr int visibleWorkEntries = 1;
  // The turn items a thread opens with, and that each load of earlier turns
  // adds; the MC rounds both up to whole runs.
  static constexpr int windowItems = 200;
  // How long changes wait for more before they go to the cache.
  static constexpr int flushDelayMs = 500;

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

  // The `kinds` a subscription to a thread's stream names: the entities the
  // model folds, so the MC sends no others.
  static QJsonObject streamKinds();
  // What a `sub` frame for the thread carries besides its shape: where the
  // copy stands (`offset`, `handle`) and the window it holds, or the window
  // to open with. Asked as each is sent, which starts the subscription over:
  // a catch-up or a page that was cut off part-way is dropped.
  QJsonObject subscribing();
  // A frame of the thread's stream: `snapshot` (part 0 starts over, `done`
  // swaps it in), `events` ([[seq, kind, id, patch, at]]), `live`, `page`
  // (earlier turns, added above) or `resync`.
  void receive(const QJsonObject& frame);

  // Where the copy is kept between runs; without one nothing is.
  void setCache(LocalCache* cache) { m_cache = cache; }
  // The copy the cache held, for a model that has none yet: its rows show at
  // once, `loading` until the MC says the thread is live.
  void restore(const cache::Thread& thread);
  // Hands the cache what changed since the last time, with the cursor it reflects.
  void flush();
  // The thread is closing: flushes, and trims the cached copy back to the
  // window a thread opens with.
  void park();
  const cache::Cursor& cursor() const { return m_cursor; }

  // Whether the thread has turns before the ones held, and whether they are
  // on their way.
  bool hasEarlier() const { return m_cursor.floor.has_value(); }
  bool loadingEarlier() const { return m_loadingEarlier; }
  // Asks for the turns before the ones held (earlierWanted). Their rows are
  // inserted above the first; the rows held keep their ids.
  Q_INVOKABLE void loadEarlier();

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
  // The run an assistant reply's row belongs to once it has finished (a fork
  // can start from it), else empty.
  Q_INVOKABLE QString finishedRunOf(const QString& rowId) const;
  // Where the thread rewinds to when the user edits from their message
  // `rowId`: {turn (the message's, from 1), checkpointId and scopeId (the
  // checkpoint the turn before it left), text, attachments (the message's:
  // [{type, id, name, mimeType, sizeBytes}])}. Empty for any other row, and
  // without `checkpointId` when no checkpoint precedes the message.
  Q_INVOKABLE QVariantMap rewindPointOf(const QString& rowId) const;
  // Puts a message's markdown on the clipboard; false for any other row.
  Q_INVOKABLE bool copy(const QString& rowId) const;
  // Asks for an image's address (attachmentWanted) unless one that still
  // works is known or on its way; its row's `attachments` carry it once
  // setAttachmentUrl lands.
  Q_INVOKABLE void loadAttachment(const QString& id);
  // The address the MC signed for an image and when it stops working; an
  // empty one when the MC had none, so the next ask tries again.
  void setAttachmentUrl(const QString& id, const QUrl& url, const QDateTime& expiresAt);

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
  // After a snapshot, or a command or file change starting or settling: the
  // workspace's files may have changed (WorkspaceFiles lists them again).
  void workspaceChanged();
  // An image on screen has no address yet (loadAttachment).
  void attachmentWanted(const QString& id);
  void earlierChanged();
  // loadEarlier(): the runs before the window holding `items` turn items are wanted.
  void earlierWanted(int items);

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

  // An image's signed address; invalid `expiresAt` while it is asked for.
  struct AttachmentUrl {
    QUrl url;
    QDateTime expiresAt;
  };

  using Entities = QHash<QString, QHash<QString, QJsonObject>>;

  QJsonObject entity(const QString& kind, const QString& id) const { return m_entities.value(kind).value(id); }
  void snapshot(const QJsonObject& frame);
  // One `events` frame's events, applied.
  void events(const QJsonArray& events);
  void eventsFrame(const QJsonObject& frame);
  void live(const QJsonObject& frame);
  void page(const QJsonObject& frame);
  // Whether the model folds this row of a snapshot or page.
  static bool folds(const QString& kind, const QJsonObject& entity);
  cache::Entity cached(const QString& kind, const QString& id, const QJsonObject& fields) const;
  void everythingChanged();
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
  // The turn items of the events being applied that changed in more than
  // streamed text.
  QSet<QString> m_reshaped;
  QSet<QString> m_expandedFolds;   // run ids
  // Work groups the user toggled, by row id: open ones, or closed ones of a
  // run stopped here (Row::startsOpen).
  QSet<QString> m_expandedGroups;
  QSet<QString> m_keptOpen;  // run ids
  QHash<QString, AttachmentUrl> m_attachmentUrls;  // by attachment id
  QDateTime m_workingSince;
  bool m_turnTouched = false;
  bool m_checkpointsTouched = false;
  bool m_agentsTouched = false;
  bool m_workspaceTouched = false;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  std::function<QString(const QString&)> m_threadTitle;
  QString m_timestampFormat = QStringLiteral("locale");
  QLocale m_locale;
  cache::Cursor m_cursor;
  // Between a `sub` frame and the `live` that answers it.
  bool m_catchingUp = false;
  // `events` frames of a catch-up whose last part has not come: its parts
  // only make sense together, so none is applied before it.
  QList<QJsonArray> m_catchUp;
  // The rows of a page whose last part has not come.
  QList<QJsonArray> m_page;
  bool m_loadingEarlier = false;
  LocalCache* m_cache = nullptr;
  // What the cache has not been handed: entities by (kind, id), everything
  // after a snapshot, or the cursor alone.
  QSet<QPair<QString, QString>> m_dirty;
  bool m_dirtyAll = false;
  bool m_cursorDirty = false;
  QTimer m_flushTimer;
};
