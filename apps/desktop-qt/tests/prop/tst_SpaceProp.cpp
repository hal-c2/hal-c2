// The pages of one Space as the MC streams them (SpacePages over SpaceStream),
// against a model of what a user should see.
//
// The model keeps the MC's Space (pages, blocks and comments) and its log, and
// what the client holds of it: the copy, the offset and log it holds it as of,
// and whether it follows the stream. The fake MC in it answers a `sub` as
// HalC2.Streams.Server does: a snapshot in parts when the copy is new or of
// another log, else the events since the offset (as the log has them, or one
// whole entity each when they take several frames, only the last of which moves
// the offset), then `live`. Answers can be cut off part-way, frames can come
// twice, the stream can be dropped or resynced, and the MC can restart on a new
// log. The user's edits of blocks wait on the MC's answers, which come before or
// after the events that carry them, or are refusals.
//
// After each step the client's copy is the model's, the rows equal the model's
// projection of it (the user's edits shown until the stream catches up with
// them), QAbstractItemModelTester finds nothing wrong with the row signals, every
// row whose roles changed was redrawn, and no row that stayed the same was.

#include "Prop.h"

#include <QAbstractItemModelTester>

#include <algorithm>
#include <memory>
#include <optional>
#include <vector>

#include "SpaceController.h"

namespace {

const QString kSpace = QStringLiteral("space-1");
const QString kPage = QStringLiteral("page");
const QString kBlock = QStringLiteral("block");
const QString kComment = QStringLiteral("comment");
constexpr int kMaxPages = 5;
constexpr int kMaxBlocks = 6;
constexpr int kMaxComments = 4;

// Entities by "kind\nid".
using Entities = QMap<QString, QJsonObject>;

QString keyOf(const QString& kind, const QString& id) { return kind + QLatin1Char('\n') + id; }

// One of `values` (RapidCheck's elementOf finds no begin() for a QList).
QString pick(const QStringList& values) {
  return *rc::gen::elementOf(std::vector<QString>(values.cbegin(), values.cend()));
}

// The MC's clock: later writes read later.
QString stamp(int at) { return QStringLiteral("2026-09-23T10:%1Z").arg(at, 6, 10, QLatin1Char('0')); }

QString str(const QJsonObject& entity, const char* field) { return entity.value(QLatin1String(field)).toString(); }

QJsonValue nullable(const QString& value) { return value.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(value); }

QMap<QString, QJsonObject> ofKind(const Entities& entities, const QString& kind) {
  QMap<QString, QJsonObject> all;
  const QString prefix = kind + QLatin1Char('\n');
  for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
    if (it.key().startsWith(prefix)) all.insert(it.key().mid(prefix.size()), *it);
  }
  return all;
}

// --- The model --------------------------------------------------------------------

struct Event {
  int seq = 0;
  QString kind;
  QString id;
  QJsonObject patch;
};

// An edit the client asked the MC for, not yet answered.
struct Request {
  int token = 0;
  QString block;
  QString field;
  QVariant value;
};

// An edit shown over the stream's value, and when the MC's answer wrote it.
struct Pend {
  int token = 0;
  QVariant value;
  QString answeredAt;
};

struct Model {
  // The MC's: the Space, this log's events, and the seq each entity last changed at.
  Entities mc;
  QList<Event> log;
  QMap<QString, int> changedAt;
  int seq = 0;
  int handle = 1;
  int clock = 0;
  // The client's: its copy, as of which offset of which log.
  Entities held;
  qint64 offset = -1;
  int heldHandle = 0;
  // Its subscription stands and is caught up: changes reach it.
  bool following = false;
  // What its stream says: caught up once, since it last subscribed.
  bool streamLive = false;
  bool unreachable = false;
  QJsonObject lastEvents;
  QString selected;
  // By "block\nfield".
  QMap<QString, Pend> pending;
  QList<Request> requests;
  int tokens = 0;
};

bool trashed(const QJsonObject& page) { return !str(page, "trashedAt").isEmpty(); }

QString titleOf(const Entities& held, const QString& id) {
  const QString title = str(held.value(keyOf(kPage, id)), "title").trimmed();
  return title.isEmpty() ? QStringLiteral("Untitled") : title;
}

// Pages sorted as they were made.
bool madeBefore(const QJsonObject& a, const QJsonObject& b) {
  const int order = QString::compare(str(a, "createdAt"), str(b, "createdAt"));
  return order != 0 ? order < 0 : str(a, "id") < str(b, "id");
}

// The page tree: untrashed pages under their parent when the copy holds it, else
// at the top; depth first, each page's subpages as they were made. A page under
// a trashed one is not shown.
QList<QVariantMap> treeOf(const Entities& held) {
  const QMap<QString, QJsonObject> pages = ofKind(held, kPage);
  const auto placedUnder = [&](const QJsonObject& page) {
    const QString parent = str(page, "parentPageId");
    return pages.contains(parent) ? parent : QString();
  };
  const auto children = [&](const QString& parent) {
    QList<QJsonObject> under;
    for (const QJsonObject& page : pages) {
      if (!trashed(page) && placedUnder(page) == parent) under.append(page);
    }
    std::sort(under.begin(), under.end(), madeBefore);
    return under;
  };
  QList<QVariantMap> tree;
  const std::function<void(const QString&, int)> place = [&](const QString& parent, int depth) {
    for (const QJsonObject& page : children(parent)) {
      const QString id = str(page, "id");
      tree.append({{QStringLiteral("id"), id},
                   {QStringLiteral("title"), titleOf(held, id)},
                   {QStringLiteral("depth"), depth},
                   {QStringLiteral("parentPageId"), parent},
                   {QStringLiteral("hasChildren"), !children(id).isEmpty()},
                   {QStringLiteral("fromThread"), !str(page, "sourceThreadId").isEmpty()}});
      place(id, depth + 1);
    }
  };
  place(QString(), 0);
  return tree;
}

// Trashed pages, the latest first.
QList<QVariantMap> trashOf(const Entities& held) {
  QList<QJsonObject> pages;
  for (const QJsonObject& page : ofKind(held, kPage)) {
    if (trashed(page)) pages.append(page);
  }
  std::sort(pages.begin(), pages.end(), [](const QJsonObject& a, const QJsonObject& b) {
    const int order = QString::compare(str(a, "trashedAt"), str(b, "trashedAt"));
    return order != 0 ? order > 0 : str(a, "id") > str(b, "id");
  });
  QList<QVariantMap> rows;
  for (const QJsonObject& page : pages) {
    const QString id = str(page, "id");
    rows.append({{QStringLiteral("id"), id}, {QStringLiteral("title"), titleOf(held, id)}, {QStringLiteral("trashedAt"), str(page, "trashedAt")}});
  }
  return rows;
}

bool byAgent(const QJsonObject& entity, const char* field) {
  return entity.value(QLatin1String(field)).toObject().value(QLatin1String("type")).toString() == QLatin1String("agent");
}

QList<QJsonObject> commentsOf(const Model& model) {
  QList<QJsonObject> comments;
  for (const QJsonObject& comment : ofKind(model.held, kComment)) {
    if (str(comment, "pageId") == model.selected) comments.append(comment);
  }
  return comments;
}

// The selected page's blocks by their order, each showing the user's edit of it.
QList<QVariantMap> blocksOf(const Model& model) {
  QList<QJsonObject> blocks;
  for (const QJsonObject& block : ofKind(model.held, kBlock)) {
    if (str(block, "pageId") == model.selected) blocks.append(block);
  }
  std::sort(blocks.begin(), blocks.end(), [](const QJsonObject& a, const QJsonObject& b) {
    const int order = QString::compare(str(a, "order"), str(b, "order"));
    return order != 0 ? order < 0 : str(a, "id") < str(b, "id");
  });
  const QList<QJsonObject> comments = commentsOf(model);
  QList<QVariantMap> rows;
  for (const QJsonObject& block : blocks) {
    const QString id = str(block, "id");
    const auto shown = [&](const QString& field, const QVariant& value) {
      const auto it = model.pending.constFind(keyOf(id, field));
      return it == model.pending.cend() ? value : it->value;
    };
    int open = 0;
    for (const QJsonObject& comment : comments) {
      if (str(comment, "blockId") == id && str(comment, "resolvedAt").isEmpty()) ++open;
    }
    const QString linked = str(block, "linkedPageId");
    rows.append({{QStringLiteral("id"), id},
                 {QStringLiteral("kind"), str(block, "kind")},
                 {QStringLiteral("text"), shown(QStringLiteral("text"), str(block, "text"))},
                 {QStringLiteral("checked"), shown(QStringLiteral("checked"), block.value(QLatin1String("checked")).toBool()).toBool()},
                 {QStringLiteral("linkedPageId"), linked},
                 {QStringLiteral("linkedTitle"), linked.isEmpty() ? QString() : titleOf(model.held, linked)},
                 {QStringLiteral("byAgent"), byAgent(block, "createdBy")},
                 {QStringLiteral("openComments"), open}});
  }
  return rows;
}

// The selected page's comments, open ones first, each as it was made.
QList<QVariantMap> commentRowsOf(const Model& model) {
  QList<QJsonObject> comments = commentsOf(model);
  std::sort(comments.begin(), comments.end(), [](const QJsonObject& a, const QJsonObject& b) {
    const bool aResolved = !str(a, "resolvedAt").isEmpty();
    const bool bResolved = !str(b, "resolvedAt").isEmpty();
    if (aResolved != bResolved) return !aResolved;
    return madeBefore(a, b);
  });
  QList<QVariantMap> rows;
  for (const QJsonObject& comment : comments) {
    const QString block = str(comment, "blockId");
    rows.append({{QStringLiteral("id"), str(comment, "id")},
                 {QStringLiteral("blockId"), block},
                 {QStringLiteral("blockText"), str(model.held.value(keyOf(kBlock, block)), "text")},
                 {QStringLiteral("body"), str(comment, "body")},
                 {QStringLiteral("resolved"), !str(comment, "resolvedAt").isEmpty()},
                 {QStringLiteral("byAgent"), byAgent(comment, "author")},
                 {QStringLiteral("createdAt"), str(comment, "createdAt")}});
  }
  return rows;
}

// Whether a page and the pages above it are out of the trash.
bool untrashed(const Entities& held, const QJsonObject& page) {
  QSet<QString> seen;
  for (QJsonObject at = page; !at.isEmpty();) {
    if (trashed(at)) return false;
    const QString parent = str(at, "parentPageId");
    if (parent.isEmpty() || seen.contains(parent)) break;
    seen.insert(parent);
    at = held.value(keyOf(kPage, parent));
  }
  return true;
}

QVariantMap pageOf(const Model& model) {
  const QJsonObject page = model.held.value(keyOf(kPage, model.selected));
  if (page.isEmpty()) return {};
  const QString thread = str(page, "sourceThreadId");
  return {{QStringLiteral("id"), model.selected},
          {QStringLiteral("title"), titleOf(model.held, model.selected)},
          {QStringLiteral("parentPageId"), str(page, "parentPageId")},
          {QStringLiteral("trashed"), !untrashed(model.held, page)},
          {QStringLiteral("sourceThreadId"), thread},
          {QStringLiteral("sourceThreadTitle"), thread.isEmpty() ? QString() : QStringLiteral("a thread")}};
}

// What follows a change to the copy or to the user's edits: a selected page the
// copy no longer holds gives way to the first of the tree, and an edit is dropped
// once its block went or the copy holds what the MC's answer wrote, or later.
void reconcile(Model& model) {
  for (auto it = model.pending.begin(); it != model.pending.end();) {
    const QJsonObject block = model.held.value(keyOf(kBlock, it.key().section(QLatin1Char('\n'), 0, 0)));
    const bool caughtUp = !it->answeredAt.isEmpty() && str(block, "updatedAt") >= it->answeredAt;
    it = block.isEmpty() || caughtUp ? model.pending.erase(it) : std::next(it);
  }
  if (model.offset >= 0 && !model.held.contains(keyOf(kPage, model.selected))) {
    const QList<QVariantMap> tree = treeOf(model.held);
    model.selected = tree.isEmpty() ? QString() : tree.first().value(QStringLiteral("id")).toString();
  }
}

QString handleOf(int handle) { return QStringLiteral("log-%1").arg(handle); }

QJsonArray json(const Event& event) {
  return {event.seq, event.kind, event.id, event.patch, stamp(event.seq)};
}

QJsonObject eventsFrame(const QList<Event>& events, qint64 offset) {
  QJsonArray all;
  for (const Event& event : events) all.append(json(event));
  return {{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("offset"), offset}, {QStringLiteral("events"), all}};
}

// The MC writes `after` (nullopt deletes) as `patch`; a client following the
// stream is sent it.
void write(Model& model, const QString& kind, const QString& id, const std::optional<QJsonObject>& after, const QJsonObject& patch) {
  const QString key = keyOf(kind, id);
  const int seq = ++model.seq;
  if (after) {
    model.mc.insert(key, *after);
  } else {
    model.mc.remove(key);
  }
  model.log.append({seq, kind, id, patch});
  model.changedAt.insert(key, seq);
  if (model.following) {
    model.held = model.mc;
    model.offset = seq;
    model.lastEvents = eventsFrame({model.log.last()}, seq);
  } else {
    model.lastEvents = {};
  }
}

// --- The client -------------------------------------------------------------------

int modelTestFailures = 0;
QtMessageHandler previousHandler = nullptr;

void countModelTestFailures(QtMsgType type, const QMessageLogContext& context, const QString& message) {
  if (context.category && qstrcmp(context.category, "qt.modeltest") == 0 && type >= QtWarningMsg) ++modelTestFailures;
  previousHandler(type, context, message);
}

struct Sut {
  SpacePages pages;
  std::vector<std::unique_ptr<QAbstractItemModelTester>> testers;
  // Every row dataChanged named since the step began, as "list\nid".
  QSet<QString> redrawn;
  // Each row when the step began, by "list\nid".
  QHash<QString, QVariantMap> before;

  Sut() {
    for (const auto& [name, rows] : lists()) {
      testers.push_back(std::make_unique<QAbstractItemModelTester>(rows, QAbstractItemModelTester::FailureReportingMode::Warning));
      QObject::connect(rows, &QAbstractItemModel::dataChanged, rows, [this, name, rows](const QModelIndex& top, const QModelIndex& bottom) {
        for (int row = top.row(); row <= bottom.row(); ++row) {
          redrawn.insert(name + QLatin1Char('\n') + rows->get(row).value(QStringLiteral("id")).toString());
        }
      });
    }
    // The index holds the one Space, which is selected as the first there is.
    const QJsonObject space{{QStringLiteral("id"), kSpace}, {QStringLiteral("name"), QStringLiteral("Research")}, {QStringLiteral("createdAt"), stamp(0)}};
    pages.receiveIndex({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0},
                        {QStringLiteral("rows"), QJsonArray{QJsonArray{QStringLiteral("space"), kSpace, space}}},
                        {QStringLiteral("done"), true}, {QStringLiteral("handle"), QStringLiteral("index-1")}});
    pages.receiveIndex({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), 1}, {QStringLiteral("handle"), QStringLiteral("index-1")}});
  }

  ~Sut() { testers.clear(); }

  QList<std::pair<QString, SpaceRows*>> lists() const {
    return {{QStringLiteral("spaces"), pages.spaces()}, {QStringLiteral("pages"), pages.pages()}, {QStringLiteral("trash"), pages.trash()},
            {QStringLiteral("blocks"), pages.blocks()}, {QStringLiteral("comments"), pages.comments()}};
  }

  QHash<QString, QVariantMap> rows() const {
    QHash<QString, QVariantMap> all;
    for (const auto& [name, rows] : lists()) {
      for (const QVariantMap& row : rows->rows()) all.insert(name + QLatin1Char('\n') + row.value(QStringLiteral("id")).toString(), row);
    }
    return all;
  }

  void begin() {
    redrawn.clear();
    before = rows();
    modelTestFailures = 0;
  }

  void send(const QJsonObject& frame) { pages.receiveSpace(frame); }

  void check(const Model& model) {
    RC_ASSERT(pages.spaceId() == kSpace);
    for (const QString& kind : {kPage, kBlock, kComment}) {
      QMap<QString, QJsonObject> got;
      for (auto it = pages.space().of(kind).cbegin(); it != pages.space().of(kind).cend(); ++it) got.insert(it.key(), *it);
      RC_ASSERT(got == ofKind(model.held, kind));
    }
    RC_ASSERT(pages.space().offset() == model.offset);
    RC_ASSERT(pages.pageId() == model.selected);
    RC_ASSERT(pages.pages()->rows() == treeOf(model.held));
    RC_ASSERT(pages.trash()->rows() == trashOf(model.held));
    RC_ASSERT(pages.blocks()->rows() == blocksOf(model));
    RC_ASSERT(pages.comments()->rows() == commentRowsOf(model));
    RC_ASSERT(pages.page() == pageOf(model));
    const QString status = model.unreachable ? QStringLiteral("unreachable") : model.streamLive ? QStringLiteral("live") : QStringLiteral("loading");
    RC_ASSERT(pages.status() == status);
    for (auto it = model.pending.cbegin(); it != model.pending.cend(); ++it) {
      RC_ASSERT(pages.pending(it.key().section(QLatin1Char('\n'), 0, 0), it.key().section(QLatin1Char('\n'), 1)));
    }
    RC_ASSERT(modelTestFailures == 0);
    const QHash<QString, QVariantMap> now = rows();
    for (const QString& row : std::as_const(redrawn)) {
      RC_ASSERT(before.contains(row));
      RC_ASSERT(before.value(row) != now.value(row));
    }
    for (auto it = now.cbegin(); it != now.cend(); ++it) {
      if (before.contains(it.key()) && before.value(it.key()) != *it) RC_ASSERT(redrawn.contains(it.key()));
    }
  }
};

using Command = rc::state::Command<Model, Sut>;

// --- The MC's writes --------------------------------------------------------------

QStringList idsOf(const Model& model, const QString& kind) { return ofKind(model.mc, kind).keys(); }

QString unused(const Model& model, const QString& kind, int most) {
  for (int n = 1; n <= most; ++n) {
    const QString id = QStringLiteral("%1-%2").arg(kind).arg(n);
    if (!model.mc.contains(keyOf(kind, id))) return id;
  }
  return {};
}

// The pages at and under `id` in the MC.
QSet<QString> subtree(const Model& model, const QString& id) {
  QSet<QString> under{id};
  for (bool grew = true; grew;) {
    grew = false;
    for (const QJsonObject& page : ofKind(model.mc, kPage)) {
      if (under.contains(str(page, "parentPageId")) && !under.contains(str(page, "id"))) {
        under.insert(str(page, "id"));
        grew = true;
      }
    }
  }
  return under;
}

// A change another client (or an agent) makes through the MC, which goes to
// this client's copy if it follows the stream (twice, when the frame comes again).
struct Write : Command {
  QString op;
  QString id;
  // What the change writes: a title, text, order, parent, kind, author.
  QString value;
  QString other;
  bool flag = false;
  bool twice = false;

  explicit Write(const Model& model) {
    const QStringList pages = idsOf(model, kPage);
    const QStringList blocks = idsOf(model, kBlock);
    const QStringList comments = idsOf(model, kComment);
    std::vector<QString> ops;
    const auto offer = [&ops](int weight, const char* name) { ops.insert(ops.end(), weight, QString::fromLatin1(name)); };
    if (pages.size() < kMaxPages) offer(3, "page.create");
    if (!pages.isEmpty()) {
      offer(2, "page.rename");
      offer(2, "page.move");
      offer(3, "page.trash");
      offer(1, "page.delete");
      if (blocks.size() < kMaxBlocks) offer(4, "block.create");
    }
    if (!blocks.isEmpty()) {
      offer(2, "block.text");
      offer(3, "block.append");
      offer(1, "block.order");
      offer(2, "block.check");
      offer(1, "block.replace");
      offer(1, "block.delete");
      if (comments.size() < kMaxComments) offer(2, "comment.create");
    }
    if (!comments.isEmpty()) {
      offer(2, "comment.resolve");
      offer(1, "comment.delete");
    }
    op = *rc::gen::elementOf(ops);
    const QString kind = op.section(QLatin1Char('.'), 0, 0);
    const bool creates = op.endsWith(QLatin1String(".create"));
    id = creates ? unused(model, kind, kind == kPage ? kMaxPages : kind == kBlock ? kMaxBlocks : kMaxComments)
                 : pick(kind == kPage ? pages : kind == kBlock ? blocks : comments);
    if (op == QLatin1String("page.create")) {
      value = pick({QStringLiteral("Roadmap"), QStringLiteral("Q3"), QStringLiteral("  "), QString()});
      other = pick(pages + QStringList{QString()});
      flag = *rc::gen::arbitrary<bool>();
    } else if (op == QLatin1String("page.rename")) {
      value = pick({QStringLiteral("Plans"), QStringLiteral("Roadmap"), QString()});
    } else if (op == QLatin1String("page.move")) {
      other = pick(pages + QStringList{QString()});
    } else if (op == QLatin1String("block.create")) {
      value = pick({QStringLiteral("paragraph"), QStringLiteral("checklist"), QStringLiteral("heading"), QStringLiteral("link")});
      other = pick(pages);
      flag = *rc::gen::arbitrary<bool>();
    } else if (op == QLatin1String("block.text") || op == QLatin1String("block.replace")) {
      value = pick({QStringLiteral("One"), QStringLiteral("Two"), QString()});
    } else if (op == QLatin1String("block.append")) {
      value = pick({QStringLiteral(" more"), QStringLiteral("!")});
    } else if (op == QLatin1String("block.order")) {
      value = pick({QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c")});
    } else if (op == QLatin1String("page.trash")) {
      // How a restore unsets trashedAt: as null, or by leaving it out.
      flag = *rc::gen::arbitrary<bool>();
    } else if (op == QLatin1String("comment.create")) {
      other = pick(blocks);
      flag = *rc::gen::arbitrary<bool>();
    }
    twice = *rc::gen::weightedElement<bool>({{4, false}, {1, true}});
  }

  struct Made {
    QString kind;
    std::optional<QJsonObject> after;
    QJsonObject patch;
  };

  // The change as the MC makes it of what it holds now, or nullopt when it
  // cannot (what it names is gone, or a page would go under itself).
  std::optional<Made> made(const Model& model) const {
    const QString kind = op.section(QLatin1Char('.'), 0, 0);
    if (id.isEmpty()) return std::nullopt;
    const QJsonObject current = model.mc.value(keyOf(kind, id));
    const bool creates = op.endsWith(QLatin1String(".create"));
    if (creates != current.isEmpty()) return std::nullopt;
    const QString at = stamp(model.clock + 1);
    const auto set = [&](const QJsonObject& fields) -> std::optional<Made> {
      QJsonObject after = current;
      for (auto it = fields.begin(); it != fields.end(); ++it) after.insert(it.key(), it.value());
      return Made{kind, after, {{QStringLiteral("s"), fields}}};
    };
    const auto author = [](bool agent) { return QJsonObject{{QStringLiteral("type"), agent ? QStringLiteral("agent") : QStringLiteral("user")}}; };
    if (op == QLatin1String("page.create")) {
      if (!other.isEmpty() && !model.mc.contains(keyOf(kPage, other))) return std::nullopt;
      return set({{QStringLiteral("id"), id}, {QStringLiteral("title"), value}, {QStringLiteral("parentPageId"), nullable(other)},
                  {QStringLiteral("sourceThreadId"), nullable(flag ? QStringLiteral("thread-1") : QString())},
                  {QStringLiteral("createdAt"), at}, {QStringLiteral("trashedAt"), QJsonValue::Null}});
    }
    if (op == QLatin1String("page.rename")) return set({{QStringLiteral("title"), value}, {QStringLiteral("updatedAt"), at}});
    if (op == QLatin1String("page.move")) {
      if (!other.isEmpty() && (!model.mc.contains(keyOf(kPage, other)) || subtree(model, id).contains(other))) return std::nullopt;
      return set({{QStringLiteral("parentPageId"), nullable(other)}, {QStringLiteral("updatedAt"), at}});
    }
    if (op == QLatin1String("page.trash")) {
      if (!trashed(current)) return set({{QStringLiteral("trashedAt"), at}});
      if (!flag) return set({{QStringLiteral("trashedAt"), QJsonValue::Null}});
      QJsonObject after = current;
      after.remove(QStringLiteral("trashedAt"));
      return Made{kind, after, {{QStringLiteral("u"), QJsonArray{QStringLiteral("trashedAt")}}}};
    }
    if (op.endsWith(QLatin1String(".delete"))) return Made{kind, std::nullopt, {{QStringLiteral("d"), true}}};
    if (op == QLatin1String("block.create")) {
      if (!model.mc.contains(keyOf(kPage, other))) return std::nullopt;
      QJsonObject block{{QStringLiteral("id"), id}, {QStringLiteral("pageId"), other}, {QStringLiteral("kind"), value},
                        {QStringLiteral("text"), QStringLiteral("New")}, {QStringLiteral("checked"), false},
                        {QStringLiteral("order"), QStringLiteral("b")}, {QStringLiteral("createdBy"), author(flag)},
                        {QStringLiteral("updatedAt"), at}};
      if (value == QLatin1String("link")) block.insert(QStringLiteral("linkedPageId"), other);
      return set(block);
    }
    if (op == QLatin1String("block.text")) return set({{QStringLiteral("text"), value}, {QStringLiteral("updatedAt"), at}});
    if (op == QLatin1String("block.append")) {
      QJsonObject after = current;
      after.insert(QStringLiteral("text"), str(current, "text") + value);
      after.insert(QStringLiteral("updatedAt"), at);
      return Made{kind, after, {{QStringLiteral("a"), QJsonObject{{QStringLiteral("text"), value}}}, {QStringLiteral("s"), QJsonObject{{QStringLiteral("updatedAt"), at}}}}};
    }
    if (op == QLatin1String("block.order")) return set({{QStringLiteral("order"), value}, {QStringLiteral("updatedAt"), at}});
    if (op == QLatin1String("block.check")) {
      return set({{QStringLiteral("checked"), !current.value(QLatin1String("checked")).toBool()}, {QStringLiteral("updatedAt"), at}});
    }
    if (op == QLatin1String("block.replace")) {
      // The whole block written anew, as a replay sends one: what it leaves out goes.
      QJsonObject after{{QStringLiteral("id"), id}, {QStringLiteral("pageId"), current.value(QLatin1String("pageId"))},
                        {QStringLiteral("kind"), current.value(QLatin1String("kind"))}, {QStringLiteral("text"), value},
                        {QStringLiteral("order"), current.value(QLatin1String("order"))}, {QStringLiteral("updatedAt"), at}};
      return Made{kind, after, {{QStringLiteral("d"), true}, {QStringLiteral("s"), after}}};
    }
    if (op == QLatin1String("comment.create")) {
      const QJsonObject block = model.mc.value(keyOf(kBlock, other));
      if (block.isEmpty()) return std::nullopt;
      return set({{QStringLiteral("id"), id}, {QStringLiteral("pageId"), block.value(QLatin1String("pageId"))},
                  {QStringLiteral("blockId"), other}, {QStringLiteral("body"), QStringLiteral("Which week?")},
                  {QStringLiteral("resolvedAt"), QJsonValue::Null}, {QStringLiteral("author"), author(flag)},
                  {QStringLiteral("createdAt"), at}});
    }
    // comment.resolve: resolves an open one, reopens a resolved one.
    return set({{QStringLiteral("resolvedAt"), str(current, "resolvedAt").isEmpty() ? QJsonValue(at) : QJsonValue(QJsonValue::Null)}});
  }

  void checkPreconditions(const Model& model) const override { RC_PRE(made(model).has_value()); }

  void apply(Model& model) const override {
    const Made change = *made(model);
    ++model.clock;
    write(model, change.kind, id, change.after, change.patch);
    reconcile(model);
  }

  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    if (model.following) {
      sut.send(next.lastEvents);
      if (twice) sut.send(next.lastEvents);
    }
    sut.check(next);
  }

  void show(std::ostream& os) const override {
    os << "Write(" << op.toStdString() << " " << id.toStdString() << " " << value.toStdString() << " " << other.toStdString()
       << (flag ? " flag" : "") << (twice ? " twice" : "") << ")";
  }
};

// --- Following the stream ---------------------------------------------------------

// The client subscribes and the MC answers: a snapshot in `parts` when the copy
// is new or of another log; else what changed since its offset, one whole entity
// each in `parts` frames when `whole` (only the last moving the offset), or the
// log's events in one (after one the copy holds, when `again`); then `live`.
// Cut, the answer stops before `live` and the connection drops.
struct Subscribe : Command {
  int parts = 1;
  bool whole = false;
  bool again = false;
  // Frames delivered before the cut, or -1.
  int cut = -1;

  explicit Subscribe(const Model&) {
    parts = *rc::gen::inRange(1, 4);
    whole = *rc::gen::arbitrary<bool>();
    again = *rc::gen::arbitrary<bool>();
    cut = *rc::gen::weightedElement<int>({{6, -1}, {1, 0}, {1, 1}, {1, 2}});
  }

  void checkPreconditions(const Model& model) const override { RC_PRE(!model.following); }

  QList<QJsonObject> frames(const Model& model) const {
    QList<QJsonObject> frames;
    const QString handle = handleOf(model.handle);
    if (model.offset < 0 || model.heldHandle != model.handle) {
      QJsonArray rows;
      for (auto it = model.mc.cbegin(); it != model.mc.cend(); ++it) {
        rows.append(QJsonArray{it.key().section(QLatin1Char('\n'), 0, 0), it.key().section(QLatin1Char('\n'), 1), *it});
      }
      const int count = int(std::max<qsizetype>(1, std::min<qsizetype>(parts, rows.size())));
      const int size = int((rows.size() + count - 1) / count);
      for (int part = 0; part < count; ++part) {
        QJsonArray chunk;
        for (int i = part * size; i < std::min<int>(int(rows.size()), (part + 1) * size); ++i) chunk.append(rows.at(i));
        frames.append({{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), model.seq}, {QStringLiteral("part"), part},
                       {QStringLiteral("rows"), chunk}, {QStringLiteral("done"), part == count - 1}, {QStringLiteral("handle"), handle}});
      }
    } else if (whole || parts > 1) {
      QList<Event> changed;
      for (auto it = model.changedAt.cbegin(); it != model.changedAt.cend(); ++it) {
        if (*it <= model.offset) continue;
        const QString kind = it.key().section(QLatin1Char('\n'), 0, 0);
        const QString id = it.key().section(QLatin1Char('\n'), 1);
        const auto entity = model.mc.constFind(it.key());
        changed.append({*it, kind, id,
                        entity == model.mc.cend() ? QJsonObject{{QStringLiteral("d"), true}}
                                                  : QJsonObject{{QStringLiteral("d"), true}, {QStringLiteral("s"), *entity}}});
      }
      std::sort(changed.begin(), changed.end(), [](const Event& a, const Event& b) { return a.seq < b.seq; });
      const int count = int(std::min<qsizetype>(parts, changed.size()));
      for (int part = 0; part < count; ++part) {
        const qsizetype from = changed.size() * part / count;
        const qsizetype to = changed.size() * (part + 1) / count;
        const QList<Event> chunk = changed.mid(from, to - from);
        frames.append(eventsFrame(chunk, part == count - 1 ? chunk.last().seq : model.offset));
      }
    } else {
      QList<Event> missed;
      const Event* held = nullptr;
      for (const Event& event : model.log) {
        if (event.seq > model.offset) {
          missed.append(event);
        } else {
          held = &event;
        }
      }
      if (!missed.isEmpty()) {
        if (again && held) missed.prepend(*held);
        frames.append(eventsFrame(missed, missed.last().seq));
      }
    }
    frames.append({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), model.seq}, {QStringLiteral("handle"), handle}});
    return frames;
  }

  int delivered(const QList<QJsonObject>& frames) const {
    return cut < 0 ? int(frames.size()) : std::min<int>(cut, int(frames.size()) - 1);
  }

  void apply(Model& model) const override {
    const QList<QJsonObject> sent = frames(model);
    const int count = delivered(sent);
    model.streamLive = false;
    model.lastEvents = {};
    // Caught up once the snapshot's last part, or the last events frame, landed.
    if (count >= sent.size() - 1) {
      model.held = model.mc;
      model.offset = model.seq;
      model.heldHandle = model.handle;
    }
    if (cut < 0) {
      model.following = true;
      model.streamLive = true;
      model.unreachable = false;
    } else {
      model.unreachable = true;
    }
    reconcile(model);
  }

  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    const QJsonObject sub = sut.pages.space().subscribing();
    if (model.offset < 0) {
      RC_ASSERT(sub.value(QLatin1String("offset")).isNull());
      RC_ASSERT(!sub.contains(QLatin1String("handle")));
    } else {
      RC_ASSERT(qint64(sub.value(QLatin1String("offset")).toDouble()) == model.offset);
      RC_ASSERT(sub.value(QLatin1String("handle")).toString() == handleOf(model.heldHandle));
    }
    const QList<QJsonObject> sent = frames(model);
    for (int i = 0; i < delivered(sent); ++i) sut.send(sent.at(i));
    if (cut >= 0) sut.pages.setUnreachable(true);
    sut.check(next);
  }

  void show(std::ostream& os) const override {
    os << "Subscribe(parts=" << parts << (whole ? " whole" : "") << (again ? " again" : "") << " cut=" << cut << ")";
  }
};

// The connection drops: the MC cannot be reached until the client subscribes again.
struct Drop : Command {
  explicit Drop(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.following || !model.unreachable); }
  void apply(Model& model) const override {
    model.following = false;
    model.unreachable = true;
    model.lastEvents = {};
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.pages.setUnreachable(true);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Drop"; }
};

// The stream's server stopped: `resync` ends the subscription, and the client
// subscribes again from what it holds.
struct Resync : Command {
  explicit Resync(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.following); }
  void apply(Model& model) const override {
    model.following = false;
    model.lastEvents = {};
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.send({{QStringLiteral("t"), QStringLiteral("resync")}});
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "Resync"; }
};

// The last events frame comes again (a reconnect sent it twice).
struct Duplicate : Command {
  explicit Duplicate(const Model&) {}
  void checkPreconditions(const Model& model) const override { RC_PRE(model.following && !model.lastEvents.isEmpty()); }
  void apply(Model&) const override {}
  void run(const Model& model, Sut& sut) const override {
    sut.begin();
    sut.send(model.lastEvents);
    sut.check(model);
  }
  void show(std::ostream& os) const override { os << "Duplicate"; }
};

// The MC restarts on another log, its seq starting again (perhaps below the
// client's offset); the Space is what it was.
struct NewLog : Command {
  int seq = 0;
  explicit NewLog(const Model&) { seq = *rc::gen::inRange(0, 3); }
  void apply(Model& model) const override {
    ++model.handle;
    model.seq = seq;
    model.log.clear();
    model.changedAt.clear();
    model.following = false;
    model.unreachable = true;
    model.lastEvents = {};
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.pages.setUnreachable(true);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "NewLog(seq=" << seq << ")"; }
};

// --- The user ---------------------------------------------------------------------

// The user opens a page; one the copy does not hold is not selected.
struct SelectPage : Command {
  QString id;
  explicit SelectPage(const Model&) {
    id = QStringLiteral("page-%1").arg(*rc::gen::inRange(1, kMaxPages + 1));
  }
  void apply(Model& model) const override {
    if (model.held.contains(keyOf(kPage, id))) model.selected = id;
    reconcile(model);
  }
  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    sut.pages.selectPage(id);
    sut.check(next);
  }
  void show(std::ostream& os) const override { os << "SelectPage(" << id.toStdString() << ")"; }
};

// The user writes a block's text or ticks it, and the client asks the MC for it.
struct Edit : Command {
  QString block;
  QString field;
  QVariant value;

  explicit Edit(const Model& model) {
    const QStringList blocks = ofKind(model.held, kBlock).keys();
    block = blocks.isEmpty() ? QStringLiteral("block-1") : pick(blocks);
    field = *rc::gen::arbitrary<bool>() ? QStringLiteral("text") : QStringLiteral("checked");
    value = field == QLatin1String("text") ? QVariant(pick({QStringLiteral("Mine"), QStringLiteral("One"), QString()}))
                                           : QVariant(*rc::gen::arbitrary<bool>());
  }

  void checkPreconditions(const Model& model) const override { RC_PRE(model.held.contains(keyOf(kBlock, block))); }

  void apply(Model& model) const override {
    const int token = ++model.tokens;
    model.pending.insert(keyOf(block, field), {token, value, {}});
    model.requests.append({token, block, field, value});
    reconcile(model);
  }

  void run(const Model& model, Sut& sut) const override {
    Model next = model;
    apply(next);
    sut.begin();
    RC_ASSERT(sut.pages.pend(block, field, value) == next.tokens);
    sut.check(next);
  }

  void show(std::ostream& os) const override {
    os << "Edit(" << block.toStdString() << " " << field.toStdString() << "=" << QJsonValue::fromVariant(value).toVariant().toString().toStdString() << ")";
  }
};

// The MC answers an edit: it writes it (its event reaching a following client
// before or after the answer), or refuses it, as it does one whose block went.
// An edit the user made again since is answered too, and changes nothing shown.
struct Answer : Command {
  int token = 0;
  bool accept = true;
  bool eventFirst = true;

  explicit Answer(const Model& model) {
    std::vector<int> tokens;
    for (const Request& request : model.requests) tokens.push_back(request.token);
    token = tokens.empty() ? 0 : *rc::gen::elementOf(tokens);
    accept = *rc::gen::weightedElement<bool>({{4, true}, {1, false}});
    eventFirst = *rc::gen::arbitrary<bool>();
  }

  std::optional<Request> request(const Model& model) const {
    for (const Request& request : model.requests) {
      if (request.token == token) return request;
    }
    return std::nullopt;
  }

  void checkPreconditions(const Model& model) const override { RC_PRE(request(model).has_value()); }

  bool written(const Model& model) const { return accept && model.mc.contains(keyOf(kBlock, request(model)->block)); }

  // The MC writes the edit.
  void writeIt(Model& model, const Request& request) const {
    const QString at = stamp(++model.clock);
    QJsonObject after = model.mc.value(keyOf(kBlock, request.block));
    const QJsonObject fields{{request.field, QJsonValue::fromVariant(request.value)}, {QStringLiteral("updatedAt"), at}};
    for (auto it = fields.begin(); it != fields.end(); ++it) after.insert(it.key(), it.value());
    write(model, kBlock, request.block, after, {{QStringLiteral("s"), fields}});
    reconcile(model);
  }

  // The answer reaches the client: the block the MC wrote, or nullopt.
  void settle(Model& model, const Request& request, const std::optional<QJsonObject>& block) const {
    model.requests.removeIf([this](const Request& at) { return at.token == token; });
    const auto it = model.pending.find(keyOf(request.block, request.field));
    if (it != model.pending.end() && it->token == token) {
      if (block) {
        it->answeredAt = str(*block, "updatedAt");
      } else {
        model.pending.erase(it);
      }
    }
    reconcile(model);
  }

  void apply(Model& model) const override {
    const Request asked = *request(model);
    if (!written(model)) {
      settle(model, asked, std::nullopt);
      return;
    }
    writeIt(model, asked);
    settle(model, asked, model.mc.value(keyOf(kBlock, asked.block)));
  }

  void run(const Model& model, Sut& sut) const override {
    const Request asked = *request(model);
    if (!written(model)) {
      Model next = model;
      apply(next);
      sut.begin();
      sut.pages.settle(token, std::nullopt);
      sut.check(next);
      return;
    }
    Model wrote = model;
    writeIt(wrote, asked);
    const QJsonObject block = wrote.mc.value(keyOf(kBlock, asked.block));
    const auto deliver = [&](Model& at) {
      sut.begin();
      if (model.following) sut.send(wrote.lastEvents);
      sut.check(at);
    };
    const auto answer = [&](Model& at) {
      settle(at, asked, block);
      sut.begin();
      sut.pages.settle(token, block);
      sut.check(at);
    };
    if (eventFirst) {
      deliver(wrote);
      answer(wrote);
    } else {
      // Answered first: the edit shows until the stream holds what it wrote.
      Model answered = model;
      settle(answered, asked, block);
      sut.begin();
      sut.pages.settle(token, block);
      sut.check(answered);
      Model next = model;
      apply(next);
      sut.begin();
      if (model.following) sut.send(wrote.lastEvents);
      sut.check(next);
    }
  }

  void show(std::ostream& os) const override {
    os << "Answer(" << token << (accept ? " accept" : " refuse") << (eventFirst ? " event-first" : " answer-first") << ")";
  }
};

}  // namespace

class SpaceProp : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() { previousHandler = qInstallMessageHandler(countModelTestFailures); }
  void cleanupTestCase() { qInstallMessageHandler(previousHandler); }

  void stream() {
    QVERIFY(rc::check("the Space's rows are the MC's Space as the client holds it, with the user's edits until it holds them", [] {
      Model model;
      Sut sut;
      rc::state::check(model, sut,
                       rc::state::gen::execOneOfWithArgs<Write, Write, Write, Write, Write, Subscribe, Subscribe, Drop, Resync,
                                                         Duplicate, NewLog, SelectPage, SelectPage, Edit, Edit, Answer, Answer>());
    }));
  }
};

HAL_C2_PROP_MAIN(SpaceProp)
#include "tst_SpaceProp.moc"
