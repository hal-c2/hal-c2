#pragma once

#include <QAbstractListModel>
#include <QDateTime>
#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QSet>
#include <QString>
#include <QTimer>
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
// selected Space's page tree, decks and trash, the selected page's blocks and
// comments, and the selected deck's slides. A selected deck is shown instead of
// the selected page, and it alone can be presented. Everything comes from the streams; the one thing it adds is an
// edit the user made (a block's text, a tick) shown until the MC has answered
// it and the stream has moved past what it was, after which the stream's
// value is what shows. Who else is on the open page comes from the
// `spacePresence` shape, not a stream, and is gone with the page.
//
// Rows:
//   spaces   {id, name}, in the order they were made
//   pages    {id, title, depth, parentPageId, hasChildren, fromThread}: the
//            page tree, depth first, untrashed and under no trashed page
//   trash    {id, title, trashedAt}: trashed pages, the latest first
//   blocks   {id, kind, text, checked, linkedPageId, linkedTitle, byAgent,
//            openComments, imageId, imageState, imageUrl, imageWidth,
//            imageHeight}: the page's blocks by their `order`; imageState is
//            shown, trashed or deleted on an image block, else ""
//   comments {id, blockId, blockText, body, resolved, byAgent, createdAt}:
//            the page's comments, open ones first
//   decks     {id, title}: decks out of the trash, in the order they were made
//   deckTrash {id, title, trashedAt}: trashed decks, the latest first
//   slides    {id, title, body}: the selected deck's slides by their `order`
//   images, imageTrash {id, name, prompt, mimeType, width, height, generatedBy,
//            url}: the Space's images and those in its trash, the latest first
//
// An image's bytes are never in the stream: `url` is a signed address, "" until
// it is signed, kept while a newer one is on its way. Only an image on the open
// page, or any image while the browser is open (setImagesShown), is asked for
// (imagesNeeded); a deleted one never is.
class SpacePages : public QObject {
  Q_OBJECT
  Q_PROPERTY(SpaceRows* spaces READ spaces CONSTANT)
  Q_PROPERTY(SpaceRows* pages READ pages CONSTANT)
  Q_PROPERTY(SpaceRows* trash READ trash CONSTANT)
  Q_PROPERTY(SpaceRows* blocks READ blocks CONSTANT)
  Q_PROPERTY(SpaceRows* comments READ comments CONSTANT)
  Q_PROPERTY(SpaceRows* decks READ decks CONSTANT)
  Q_PROPERTY(SpaceRows* deckTrash READ deckTrash CONSTANT)
  Q_PROPERTY(SpaceRows* slides READ slides CONSTANT)
  Q_PROPERTY(SpaceRows* images READ images CONSTANT)
  Q_PROPERTY(SpaceRows* imageTrash READ imageTrash CONSTANT)
  Q_PROPERTY(QString spaceId READ spaceId NOTIFY changed)
  Q_PROPERTY(QString spaceName READ spaceName NOTIFY changed)
  Q_PROPERTY(QString pageId READ pageId NOTIFY changed)
  // {id, title, parentPageId, trashed, sourceThreadId, sourceThreadTitle, site},
  // or empty. `site` is what the page has published, {url, localOnly, behind,
  // publishedAt}, or empty.
  Q_PROPERTY(QVariantMap page READ page NOTIFY changed)
  Q_PROPERTY(QString deckId READ deckId NOTIFY changed)
  // {id, title, trashed}, or empty.
  Q_PROPERTY(QVariantMap deck READ deck NOTIFY changed)
  // The presenter over the selected deck: the slide it shows ({id, title, body},
  // or empty), which that is counting from 1, and how many there are.
  Q_PROPERTY(bool presenting READ presenting NOTIFY changed)
  Q_PROPERTY(QVariantMap slide READ slide NOTIFY changed)
  Q_PROPERTY(int slideNumber READ slideNumber NOTIFY changed)
  Q_PROPERTY(int slideCount READ slideCount NOTIFY changed)
  // loading, live or unreachable: the selected Space's stream (the index's
  // before a Space is selected).
  Q_PROPERTY(QString status READ status NOTIFY changed)
  // Who else is on the open page: {devices: [label], agents: [thread title]}.
  Q_PROPERTY(QVariantMap viewers READ viewers NOTIFY viewersChanged)

public:
  explicit SpacePages(QObject* parent = nullptr);

  SpaceRows* spaces() const { return m_spaces; }
  SpaceRows* pages() const { return m_pages; }
  SpaceRows* trash() const { return m_trash; }
  SpaceRows* blocks() const { return m_blocks; }
  SpaceRows* comments() const { return m_comments; }
  SpaceRows* decks() const { return m_decks; }
  SpaceRows* deckTrash() const { return m_deckTrash; }
  SpaceRows* slides() const { return m_slides; }
  SpaceRows* images() const { return m_images; }
  SpaceRows* imageTrash() const { return m_imageTrash; }
  QString spaceId() const { return m_spaceId; }
  QString spaceName() const;
  QString pageId() const { return m_pageId; }
  QVariantMap page() const;
  QString deckId() const { return m_deckId; }
  bool imagesShown() const { return m_imagesShown; }
  QVariantMap deck() const;
  bool presenting() const { return m_presenting; }
  QVariantMap slide() const { return m_presenting ? m_slides->get(m_slideIndex) : QVariantMap(); }
  int slideNumber() const { return m_presenting ? m_slideIndex + 1 : 0; }
  int slideCount() const { return m_presenting ? m_slides->rowCount() : 0; }
  QVariantMap siteOf(const QString& pageId) const;
  QString status() const;
  QVariantMap viewers() const { return m_viewers; }

  SpaceStream& index() { return m_index; }
  SpaceStream& space() { return m_space; }
  // A frame of the `spaces` index, or of the selected Space's stream.
  void receiveIndex(const QJsonObject& frame);
  void receiveSpace(const QJsonObject& frame);
  void setUnreachable(bool unreachable);
  // A `spacePresence` frame of the page `pageId`; only the open page's shows,
  // and whoever was on a page stops showing when another opens.
  void receiveViewers(const QString& pageId, const QJsonObject& frame);
  void clearViewers();

  // Shows the Space `id` (a new copy of its stream follows) or page `id`
  // of it; one the streams do not hold is not selected.
  void selectSpace(const QString& id);
  void selectPage(const QString& id);
  // Shows the deck `id` in place of the page; one the stream does not hold is
  // not selected.
  void selectDeck(const QString& id);
  // As select, for one the MC just made: selected once its stream holds it.
  void awaitSpace(const QString& id);
  void awaitPage(const QString& id);
  void awaitDeck(const QString& id);

  // Opens the presenter on the first slide of the deck `id`, selecting it; false
  // when that deck is not there to present or has no slides. It goes on showing the
  // same slide wherever that moves to, and closes with the deck or its last slide.
  bool present(const QString& id);
  // Moves `by` slides, stopping at either end.
  void step(int by);
  void leave();

  // The user's edit of a block's `field` (text or checked) to `value`, shown
  // until the MC answers it and the stream holds what it wrote, or anything later.
  int pend(const QString& blockId, const QString& field, const QVariant& value);
  // The MC answered the edit `token` with the block it wrote; nullopt when it
  // refused it, whose stream value shows at once.
  void settle(int token, const std::optional<QJsonObject>& block);
  bool pending(const QString& blockId, const QString& field) const { return m_pending.contains(blockId + QLatin1Char('\n') + field); }

  // Whether the Space's images are being browsed, so all of them need an address.
  void setImagesShown(bool shown);
  // The address asked for by imagesNeeded, good until `expiresAt` (ms since the
  // epoch). One asked for before the Space changed is dropped.
  void setImageAddress(const QString& imageId, const QString& url, qint64 expiresAt);
  // It could not be signed: asked for again the next time the rows change.
  void imageAddressFailed(const QString& imageId);
  // What "now" is for an address's end, for a test to move.
  void setClock(std::function<qint64()> now) { m_now = std::move(now); }

  // Titles for what a page names: a page's own, or "Untitled".
  QString titleOf(const QString& pageId) const;
  QString threadTitle(const QString& threadId) const;
  void setThreadTitles(std::function<QString(const QString&)> title) { m_threadTitle = std::move(title); }

signals:
  void changed();
  // The selected Space changed: its stream is followed anew.
  void spaceSelected(const QString& id);
  void viewersChanged();
  // These images should be shown and have no good address, nor one on its way.
  void imagesNeeded(const QStringList& imageIds);

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
  // Keeps the presenter on a slide of the deck as it stands.
  void followPresenter();
  // The images whose address should now be asked for, marked as asked.
  QStringList imagesToSign(const QSet<QString>& wanted);
  void armAddressRefresh(const QSet<QString>& wanted);

  SpaceStream m_index;
  SpaceStream m_space;
  bool m_unreachable = false;
  QString m_spaceId;
  QString m_pageId;
  QString m_awaitedSpace;
  QString m_awaitedPage;
  QVariantMap m_viewers;
  QString m_viewersPage;
  QString m_deckId;
  QString m_awaitedDeck;
  bool m_presenting = false;
  QString m_slideId;
  int m_slideIndex = 0;
  QHash<QString, Pending> m_pending;
  int m_tokens = 0;
  std::function<QString(const QString&)> m_threadTitle;
  struct Address {
    QString url;
    qint64 expiresAt = 0;
  };
  bool m_imagesShown = false;
  QHash<QString, Address> m_addresses;
  QSet<QString> m_signing;
  std::function<qint64()> m_now = &QDateTime::currentMSecsSinceEpoch;
  // Fires when the first address on screen is due to be signed anew, as nothing
  // else may change in the Space while it lasts.
  QTimer* m_addressRefresh;
  // One rebuild for all the addresses answered in one turn of the event loop.
  QTimer* m_rebuildSoon;
  SpaceRows* m_spaces;
  SpaceRows* m_pages;
  SpaceRows* m_trash;
  SpaceRows* m_blocks;
  SpaceRows* m_comments;
  SpaceRows* m_decks;
  SpaceRows* m_deckTrash;
  SpaceRows* m_slides;
  SpaceRows* m_images;
  SpaceRows* m_imageTrash;
};

// The Space view (route kind `space`): follows the `spaces` index and the
// selected Space's stream while it is open, and makes every change with the
// MC's `space.*` calls, which the streams then show. A refusal is said in a
// toast and kept in `error`.
//
// Publishes `space`: {error (the last refusal, until the next request), busy
// (a page from a thread is being written), drawing (a chart is being asked for),
// written, addingImage, generatingImage, imageProviders ({providers, selection},
// `space.image.providers`' answer)}.
//
// Actions (each payload's `spaceId` defaults to the selected Space):
// `space.open`, `space.select {spaceId}`, `space.selectPage {pageId}`,
// `space.create {name}`, `space.rename {spaceId, name}`, `space.delete {spaceId}`,
// `space.page.create {title, parentPageId, link}`, `space.page.rename {pageId, title}`,
// `space.page.move {pageId, parentPageId}`, `space.page.trash {pageId}`,
// `space.page.restore {pageId}`, `space.page.delete {pageId}`,
// `space.page.copyMarkdown {pageId}`, `space.page.saveMarkdown {pageId, url}`,
// `space.page.publish {pageId, tailscale}`, `space.page.unpublish {pageId}`,
// `space.page.copySiteLink {pageId}`,
// `space.page.importMarkdown {markdown}`, `space.page.importFile {url}`,
// `space.pageFromThread {threadKey}`,
// `space.block.insert {pageId, kind, text, checked, linkedPageId, imageId, afterBlockId}`
// (afterBlockId: "" first, absent last), `space.block.visualize {pageId, request,
// blockId (the chart it replaces), afterBlockId}`, `space.block.update {blockId, text}`,
// `space.block.setChecked {blockId, checked}`, `space.block.move {blockId,
// afterBlockId}`, `space.block.delete {blockId}`, `space.comment.add {pageId,
// blockId, body}`, `space.comment.resolve {commentId}`, `space.comment.reopen
// {commentId}`, `space.selectDeck {deckId}`, `space.deck.create {title}`,
// `space.deck.createFromPage {pageId}`, `space.deck.rename {deckId, title}`,
// `space.deck.trash {deckId}`, `space.deck.restore {deckId}`, `space.deck.delete
// {deckId}`, `space.slide.insert {deckId, title, body, afterSlideId}` (afterSlideId:
// "" first, absent last), `space.slide.update {slideId, title, body}`,
// `space.slide.move {slideId, afterSlideId}`, `space.slide.delete {slideId}`,
// `space.deck.present {deckId}`, `space.deck.step {by}`, `space.deck.leave`,
// `space.images.show {shown}`, `space.image.providers`,
// `space.image.addFile {url}`, `space.image.generate {prompt, modelSelection}`,
// `space.image.trash {imageId}`, `space.image.restore {imageId}`,
// `space.image.delete {imageId}`.
class SpaceController : public SpacePages, public NativeController {
  Q_OBJECT

public:
  static inline const QString kOpen = QStringLiteral("space.open");
  static inline const QString kPageFromThread = QStringLiteral("space.pageFromThread");
  static inline const QString kDeckFromPage = QStringLiteral("space.deck.fromOpenPage");
  static inline const QString kPresentDeck = QStringLiteral("space.deck.presentOpen");

  SpaceController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  QString error() const { return m_error; }
  // The phone layout's Space screen selects a page before showing it: the user
  // is on it only while the screen says so (`space.pageShown`). On the desktop
  // and in the phone's wide layout the selected page is the one on show.
  void setPageShownBySteps(bool bySteps);

private:
  void setOpen(bool open);
  void follow();
  void unfollow();
  void followSpace();
  // Follows who else is on the open page, only while it is on show and the
  // client connected: a new connection follows it anew.
  void followViewers();
  // `space.<method>` with the selected Space's id unless the payload names
  // one. A refusal is said (refuse) in the MC's words, or in what `refused`
  // returns for its detail.
  void call(const QString& method, QJsonObject payload, std::function<void(const QJsonObject& result)> done = {},
            std::function<QString(const QJsonObject& detail)> refused = {});
  void refuse(const QString& message);
  void exportPage(const QString& pageId, std::function<void(const QString& markdown)> done);
  void importMarkdown(const QString& markdown);
  void pageFromThread(const QString& threadKey);
  void presentDeck(const QString& id);
  void signImages(const QStringList& imageIds);
  void addImageFile(const QString& url);
  void generateImage(const QString& prompt, const QJsonObject& selection);
  void toast(const QString& type, const QString& title, const QString& description = {});
  void publish();

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  bool m_open = false;
  bool m_listed = false;
  int m_indexSubscription = 0;
  int m_spaceSubscription = 0;
  int m_viewersSubscription = 0;
  QString m_followedSpace;
  QString m_followedViewers;
  bool m_pageShownBySteps = false;
  bool m_pageShown = false;
  QString m_error;
  int m_writing = 0;
  int m_drawing = 0;
  int m_addingImages = 0;
  int m_generatingImages = 0;
  QVariantMap m_imageProviders;
  // The page last written from a thread.
  QString m_written;
};
