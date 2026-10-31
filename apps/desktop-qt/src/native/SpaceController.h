#pragma once

#include <QAbstractListModel>
#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QSet>
#include <QString>
#include <QVariantMap>

#include <functional>
#include <optional>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// One stream of a Space as the MC sends it (the `spaces` index, or a
// `space:<id>`): its entities by kind and id, and where a `sub` resumes. A
// snapshot replaces the copy once its last part lands; events apply
// HalC2.Patch in log order and skip what the copy already holds (a frame sent
// again on a reconnect); a catch-up split over frames is applied as one.
class SpaceStream {
public:
  // The `sub` resume: no offset without a copy, else its offset and handle.
  // Starts a catch-up.
  QJsonObject subscribing();
  // Applies a frame; true when an entity changed.
  bool receive(const QJsonObject& frame);
  void clear() { *this = SpaceStream(); }

  bool live() const { return m_live; }
  bool hasCopy() const { return m_offset >= 0; }
  qint64 offset() const { return m_offset; }
  const QHash<QString, QJsonObject>& of(const QString& kind) const;
  QJsonObject entity(const QString& kind, const QString& id) const { return of(kind).value(id); }

private:
  bool events(const QJsonArray& events);

  QHash<QString, QHash<QString, QJsonObject>> m_entities;
  QHash<QString, QHash<QString, QJsonObject>> m_incoming;
  QList<QJsonArray> m_catchUp;
  qint64 m_offset = -1;
  QString m_handle;
  bool m_catchingUp = false;
  bool m_live = false;
};

// A list of rows keyed by their `id`, each a map of the roles it names.
// setRows changes it in place: rows that went are removed, rows that came are
// inserted, a row that moved is moved, and only a row whose roles changed is
// redrawn, so delegates (a block being edited) keep their state.
class SpaceRows : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(int count READ rowCount NOTIFY countChanged)

public:
  SpaceRows(const QList<QByteArray>& roles, QObject* parent = nullptr);

  void setRows(const QList<QVariantMap>& rows);
  const QList<QVariantMap>& rows() const { return m_rows; }
  Q_INVOKABLE int indexOf(const QString& id) const;
  Q_INVOKABLE QVariantMap get(int row) const { return m_rows.value(row); }

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

signals:
  void countChanged();

private:
  QList<QByteArray> m_roles;
  QList<QVariantMap> m_rows;
};

// What the Space view shows of the MC's Space streams: the Spaces, the
// selected Space's page tree and trash, and the selected page's blocks and
// comments. Everything comes from the streams; the one thing it adds is an
// edit the user made (a block's text, a tick) shown until the MC has answered
// it and the stream has moved past what it was, after which the stream's
// value is what shows.
//
// Rows:
//   spaces   {id, name}, in the order they were made
//   pages    {id, title, depth, parentPageId, hasChildren, fromThread}: the
//            page tree, depth first, untrashed and under no trashed page
//   trash    {id, title, trashedAt}: trashed pages, the latest first
//   blocks   {id, kind, text, checked, linkedPageId, linkedTitle, byAgent,
//            openComments}: the page's blocks by their `order`
//   comments {id, blockId, blockText, body, resolved, byAgent, createdAt}:
//            the page's comments, open ones first
class SpacePages : public QObject {
  Q_OBJECT
  Q_PROPERTY(SpaceRows* spaces READ spaces CONSTANT)
  Q_PROPERTY(SpaceRows* pages READ pages CONSTANT)
  Q_PROPERTY(SpaceRows* trash READ trash CONSTANT)
  Q_PROPERTY(SpaceRows* blocks READ blocks CONSTANT)
  Q_PROPERTY(SpaceRows* comments READ comments CONSTANT)
  Q_PROPERTY(QString spaceId READ spaceId NOTIFY changed)
  Q_PROPERTY(QString spaceName READ spaceName NOTIFY changed)
  Q_PROPERTY(QString pageId READ pageId NOTIFY changed)
  // {id, title, parentPageId, trashed, sourceThreadId, sourceThreadTitle}, or empty.
  Q_PROPERTY(QVariantMap page READ page NOTIFY changed)
  // loading, live or unreachable: the selected Space's stream (the index's
  // before a Space is selected).
  Q_PROPERTY(QString status READ status NOTIFY changed)

public:
  explicit SpacePages(QObject* parent = nullptr);

  SpaceRows* spaces() const { return m_spaces; }
  SpaceRows* pages() const { return m_pages; }
  SpaceRows* trash() const { return m_trash; }
  SpaceRows* blocks() const { return m_blocks; }
  SpaceRows* comments() const { return m_comments; }
  QString spaceId() const { return m_spaceId; }
  QString spaceName() const;
  QString pageId() const { return m_pageId; }
  QVariantMap page() const;
  QString status() const;

  SpaceStream& index() { return m_index; }
  SpaceStream& space() { return m_space; }
  // A frame of the `spaces` index, or of the selected Space's stream.
  void receiveIndex(const QJsonObject& frame);
  void receiveSpace(const QJsonObject& frame);
  void setUnreachable(bool unreachable);

  // Shows the Space `id` (a new copy of its stream follows) or page `id`
  // of it; one the streams do not hold is not selected.
  void selectSpace(const QString& id);
  void selectPage(const QString& id);
  // As select, for one the MC just made: selected once its stream holds it.
  void awaitSpace(const QString& id);
  void awaitPage(const QString& id);

  // The user's edit of a block's `field` (text or checked) to `value`, shown
  // until the MC answers it and the stream holds what it wrote, or anything later.
  int pend(const QString& blockId, const QString& field, const QVariant& value);
  // The MC answered the edit `token` with the block it wrote; nullopt when it
  // refused it, whose stream value shows at once.
  void settle(int token, const std::optional<QJsonObject>& block);
  bool pending(const QString& blockId, const QString& field) const { return m_pending.contains(blockId + QLatin1Char('\n') + field); }

  // Titles for what a page names: a page's own, or "Untitled".
  QString titleOf(const QString& pageId) const;
  QString threadTitle(const QString& threadId) const;
  void setThreadTitles(std::function<QString(const QString&)> title) { m_threadTitle = std::move(title); }

signals:
  void changed();
  // The selected Space changed: its stream is followed anew.
  void spaceSelected(const QString& id);

private:
  struct Pending {
    QString blockId;
    QString field;
    QVariant value;
    int token = 0;
    // The block's `updatedAt` in the MC's answer, once it answered.
    QString answeredAt;
  };

  void rebuild();
  // Drops the edits the stream has caught up with.
  void reconcile();
  // Keeps the selection on what the streams hold; true when it selected
  // another Space, which rebuilt the rows.
  bool reselect();
  bool live(const QJsonObject& page) const;

  SpaceStream m_index;
  SpaceStream m_space;
  bool m_unreachable = false;
  QString m_spaceId;
  QString m_pageId;
  QString m_awaitedSpace;
  QString m_awaitedPage;
  QHash<QString, Pending> m_pending;
  int m_tokens = 0;
  std::function<QString(const QString&)> m_threadTitle;
  SpaceRows* m_spaces;
  SpaceRows* m_pages;
  SpaceRows* m_trash;
  SpaceRows* m_blocks;
  SpaceRows* m_comments;
};

// The Space view (route kind `space`): follows the `spaces` index and the
// selected Space's stream while it is open, and makes every change with the
// MC's `space.*` calls, which the streams then show. A refusal is said in a
// toast and kept in `error`.
//
// Publishes `space`: {error (the last refusal, until the next request), busy
// (a page from a thread is being written)}.
//
// Actions (each payload's `spaceId` defaults to the selected Space):
// `space.open`, `space.select {spaceId}`, `space.selectPage {pageId}`,
// `space.create {name}`, `space.rename {spaceId, name}`, `space.delete {spaceId}`,
// `space.page.create {title, parentPageId, link}`, `space.page.rename {pageId, title}`,
// `space.page.move {pageId, parentPageId}`, `space.page.trash {pageId}`,
// `space.page.restore {pageId}`, `space.page.delete {pageId}`,
// `space.page.copyMarkdown {pageId}`, `space.page.saveMarkdown {pageId, url}`,
// `space.page.importMarkdown {markdown}`, `space.page.importFile {url}`,
// `space.pageFromThread {threadKey}`,
// `space.block.insert {pageId, kind, text, checked, linkedPageId, afterBlockId}`
// (afterBlockId: "" first, absent last), `space.block.update {blockId, text}`,
// `space.block.setChecked {blockId, checked}`, `space.block.move {blockId,
// afterBlockId}`, `space.block.delete {blockId}`, `space.comment.add {pageId,
// blockId, body}`, `space.comment.resolve {commentId}`, `space.comment.reopen
// {commentId}`.
class SpaceController : public SpacePages, public NativeController {
  Q_OBJECT

public:
  static inline const QString kOpen = QStringLiteral("space.open");
  static inline const QString kPageFromThread = QStringLiteral("space.pageFromThread");

  SpaceController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  QString error() const { return m_error; }
  // Whether this client has a Space view to open. One without offers no way
  // into Spaces: no palette commands, no thread menu item. Set before activate().
  void setViewed(bool viewed) { m_viewed = viewed; }
  bool viewed() const { return m_viewed; }

private:
  void setOpen(bool open);
  void follow();
  void unfollow();
  void followSpace();
  // `space.<method>` with the selected Space's id unless the payload names
  // one. A refusal is said (refuse) in the MC's words, or in what `refused`
  // returns for its detail.
  void call(const QString& method, QJsonObject payload, std::function<void(const QJsonObject& result)> done = {},
            std::function<QString(const QJsonObject& detail)> refused = {});
  void refuse(const QString& message);
  void exportPage(const QString& pageId, std::function<void(const QString& markdown)> done);
  void importMarkdown(const QString& markdown);
  void pageFromThread(const QString& threadKey);
  void toast(const QString& type, const QString& title, const QString& description = {});
  void publish();

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  bool m_viewed = true;
  bool m_open = false;
  bool m_listed = false;
  int m_indexSubscription = 0;
  int m_spaceSubscription = 0;
  QString m_followedSpace;
  QString m_error;
  int m_writing = 0;
};
