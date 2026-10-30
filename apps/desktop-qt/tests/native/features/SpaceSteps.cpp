// Pages in a Space (features/space/pages.feature): the MC's `space.*` calls,
// faked here as the MC answers them (lib/hal_c2/space.ex and space/*.ex),
// its `spaces` and `space:<id>` streams (served as every `stream` is, by
// TimelineSteps.cpp), and what SpaceController shows of them.

#include <QAbstractItemModel>
#include <QJsonArray>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSet>

#include <algorithm>
#include <memory>
#include <optional>

#include "Harness.h"
#include "NavigationController.h"
#include "Space.h"
#include "SpaceController.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

const QString kIndex = QStringLiteral("spaces");

QString streamOf(const QString& spaceId) {
  return QStringLiteral("space:") + spaceId;
}

// A `space.*` answer: its result, or the refusal's message and detail.
struct Answer {
  QJsonObject result;
  QString error;
  QJsonObject detail;
};

// The MC's Spaces, beside the streams that hold them.
struct FakeSpaces {
  int ids = 0;
  int clock = 0;
  // Threads with something to summarise.
  QSet<QString> talked;
  // How text generation answers: available, unavailable or failed.
  QString generation = QStringLiteral("available");
  // The folder the last summary was written in, and the thread it was of.
  QString cwd;
  QString summarised;
  // How the client's last `space.*` was answered.
  QString lastMethod;
  Answer last;
  // The ids page titles, block texts and comment bodies named, kept after they go.
  QHash<QString, QString> named;
  // The Space the scenario writes in.
  QString current;
  // Where the log of the current Space stood when a block moved, and what
  // the client's blocks did since.
  qsizetype mark = 0;
  QStringList seen;
  // Another client following the Spaces (and, once it chose one, a Space).
  std::unique_ptr<SpacePages> second;
};

FakeSpaces& fake(FakeMc& mc) {
  return mc.part<FakeSpaces>();
}

QString stamp(FakeMc& mc) {
  return iso(now().addSecs(++fake(mc).clock));
}

QString newId(FakeMc& mc, const QString& kind) {
  return QStringLiteral("%1-%2").arg(kind).arg(++fake(mc).ids);
}

QString text(const QJsonObject& entity, QLatin1String field) {
  return entity.value(field).toString();
}

QList<QJsonObject> all(FakeMc& mc, const QString& stream, const QString& kind) {
  QList<QJsonObject> out;
  const QMap<QString, QJsonObject> entities = mc.part<FakeStreams>().threads.value(stream);
  for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
    if (it.key().startsWith(kind + QLatin1Char('\n'))) out.append(*it);
  }
  return out;
}

QJsonObject one(FakeMc& mc, const QString& stream, const QString& kind, const QString& id) {
  return mc.part<FakeStreams>().threads.value(stream).value(kind + QLatin1Char('\n') + id);
}

QList<QJsonObject> sortedBy(QList<QJsonObject> rows, QLatin1String field) {
  std::stable_sort(rows.begin(), rows.end(), [field](const QJsonObject& a, const QJsonObject& b) {
    const int order = QString::compare(text(a, field), text(b, field));
    return order != 0 ? order < 0 : text(a, QLatin1String("id")) < text(b, QLatin1String("id"));
  });
  return rows;
}

// The snapshot of `stream` a follower starting now is sent, and its `live`.
QList<QJsonObject> snapshot(FakeMc& mc, const QString& stream) {
  FakeStreams& streams = mc.part<FakeStreams>();
  QJsonArray rows;
  const QMap<QString, QJsonObject> entities = streams.threads.value(stream);
  for (auto it = entities.cbegin(); it != entities.cend(); ++it) {
    const QStringList key = it.key().split(QLatin1Char('\n'));
    rows.append(QJsonArray{key.at(0), key.at(1), *it});
  }
  return {{{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), streams.seq}, {QStringLiteral("part"), 0},
           {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("handle"), streams.handle}},
          {{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), streams.seq}, {QStringLiteral("handle"), streams.handle}}};
}

// One change to an entity of `stream`, appended to its log and sent to
// whoever follows it ({"s": set, "d": delete}).
void put(FakeMc& mc, const QString& stream, const QString& kind, const QString& id, const QJsonObject& patch) {
  FakeStreams& streams = mc.part<FakeStreams>();
  QMap<QString, QJsonObject>& entities = streams.threads[stream];
  const QString key = kind + QLatin1Char('\n') + id;
  if (patch.value(QLatin1String("d")).toBool()) {
    entities.remove(key);
  } else {
    QJsonObject& entity = entities[key];
    const QJsonObject set = patch.value(QLatin1String("s")).toObject();
    for (auto it = set.begin(); it != set.end(); ++it) entity.insert(it.key(), it.value());
  }
  const int seq = ++streams.seq;
  streams.log[stream].append({seq, kind, id, patch});
  QJsonObject events{{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("offset"), seq},
                     {QStringLiteral("events"), QJsonArray{QJsonValue(QJsonArray{seq, kind, id, patch, iso(now())})}}};
  for (const int follower : mc.subscribers(QStringLiteral("stream"))) {
    if (mc.shapeOf(follower).value(QLatin1String("stream")).toString() != stream) continue;
    events.insert(QStringLiteral("id"), follower);
    deliver(mc, events);
  }
  if (SpacePages* second = fake(mc).second.get()) {
    if (stream == kIndex) second->receiveIndex(events);
    if (!second->spaceId().isEmpty() && stream == streamOf(second->spaceId())) second->receiveSpace(events);
  }
}

void set(FakeMc& mc, const QString& stream, const QString& kind, const QString& id, const QJsonObject& fields) {
  put(mc, stream, kind, id, {{QStringLiteral("s"), fields}});
}

void remove(FakeMc& mc, const QString& stream, const QString& kind, const QString& id) {
  put(mc, stream, kind, id, {{QStringLiteral("d"), true}});
}

// --- The MC's answers -------------------------------------------------------

Answer refused(const QString& reason, const QString& message, const QString& tag = QStringLiteral("SpaceError")) {
  return {{}, message, {{QStringLiteral("_tag"), tag}, {QStringLiteral("reason"), reason}, {QStringLiteral("message"), message}}};
}

const QJsonObject kUser{{QStringLiteral("type"), QStringLiteral("user")}};

QJsonObject agent(const QString& threadId) {
  return {{QStringLiteral("type"), QStringLiteral("agent")}, {QStringLiteral("threadId"), threadId}};
}

// HalC2.Space.Order.between: a key after `low` and before `high` (none: the end).
QList<int> mid(const QList<int>& low, const std::optional<QList<int>>& high);

QList<int> midFirst(const QList<int>& low, const std::optional<QList<int>>& high) {
  const int lo = low.isEmpty() ? 0 : low.first();
  const int hi = high ? high->first() : 36;
  if (hi - lo > 1) return {(lo + hi) / 2};
  if (high && high->size() > 1) return {hi};
  return QList<int>{lo} + mid(low.mid(1), std::nullopt);
}

QList<int> mid(const QList<int>& low, const std::optional<QList<int>>& high) {
  if (!high) return midFirst(low, high);
  qsizetype common = 0;
  while (common < high->size() && (common < low.size() ? low.at(common) : 0) == high->at(common)) ++common;
  if (common == 0) return midFirst(low, high);
  return high->mid(0, common) + mid(low.mid(common), high->mid(common));
}

QString between(const QString& low, const std::optional<QString>& high) {
  static const QString digits = QStringLiteral("0123456789abcdefghijklmnopqrstuvwxyz");
  const auto toDigits = [](const QString& key) {
    QList<int> out;
    for (const QChar c : key) out.append(int(digits.indexOf(c)));
    return out;
  };
  QString key;
  for (const int digit : mid(toDigits(low), high ? std::optional(toDigits(*high)) : std::nullopt)) key.append(digits.at(digit));
  return key;
}

bool trashed(const QJsonObject& page) {
  return !text(page, QLatin1String("trashedAt")).isEmpty();
}

// Neither the page nor any page it sits in is in the trash.
bool live(FakeMc& mc, const QString& space, QJsonObject page) {
  QSet<QString> seen;
  while (!page.isEmpty()) {
    if (trashed(page)) return false;
    const QString parent = text(page, QLatin1String("parentPageId"));
    if (parent.isEmpty() || seen.contains(parent)) break;
    seen.insert(parent);
    page = one(mc, streamOf(space), QStringLiteral("page"), parent);
  }
  return true;
}

// The page and every page inside it.
QStringList within(FakeMc& mc, const QString& space, const QString& pageId) {
  QStringList found{pageId};
  for (qsizetype i = 0; i < found.size(); ++i) {
    for (const QJsonObject& page : all(mc, streamOf(space), QStringLiteral("page"))) {
      const QString id = text(page, QLatin1String("id"));
      if (text(page, QLatin1String("parentPageId")) == found.at(i) && !found.contains(id)) found.append(id);
    }
  }
  return found;
}

QList<QJsonObject> blocksOf(FakeMc& mc, const QString& space, const QString& pageId) {
  QList<QJsonObject> blocks;
  for (const QJsonObject& block : all(mc, streamOf(space), QStringLiteral("block"))) {
    if (text(block, QLatin1String("pageId")) == pageId) blocks.append(block);
  }
  return sortedBy(blocks, QLatin1String("order"));
}

// Where a page that can be written to is, or why it cannot be.
std::optional<Answer> writable(FakeMc& mc, const QString& space, const QString& pageId) {
  const QJsonObject page = one(mc, streamOf(space), QStringLiteral("page"), pageId);
  if (page.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no page %1.").arg(pageId));
  if (!live(mc, space, page)) return refused(QStringLiteral("trashed"), QStringLiteral("The page is in the trash."));
  return std::nullopt;
}

// The order key of a block placed after `after` (absent: last, null: first)
// on the page, without the block `moving`.
std::optional<QString> place(FakeMc& mc, const QString& space, const QString& pageId, const QJsonValue& after, const QString& moving = {}) {
  QList<QJsonObject> blocks = blocksOf(mc, space, pageId);
  blocks.removeIf([&](const QJsonObject& block) { return text(block, QLatin1String("id")) == moving; });
  const auto order = [&](qsizetype i) { return text(blocks.at(i), QLatin1String("order")); };
  if (after.isUndefined()) return between(blocks.isEmpty() ? QString() : order(blocks.size() - 1), std::nullopt);
  if (after.isNull()) return between(QString(), blocks.isEmpty() ? std::nullopt : std::optional(order(0)));
  for (qsizetype i = 0; i < blocks.size(); ++i) {
    if (text(blocks.at(i), QLatin1String("id")) != after.toString()) continue;
    return between(order(i), i + 1 < blocks.size() ? std::optional(order(i + 1)) : std::nullopt);
  }
  return std::nullopt;
}

QString titleOf(FakeMc& mc, const QString& space, const QString& pageId) {
  return text(one(mc, streamOf(space), QStringLiteral("page"), pageId), QLatin1String("title"));
}

// HalC2.Space.Markdown.export.
QString exportMarkdown(FakeMc& mc, const QString& space, const QJsonObject& page) {
  QStringList parts{QStringLiteral("# ") + text(page, QLatin1String("title"))};
  bool inList = false;
  for (const QJsonObject& block : blocksOf(mc, space, text(page, QLatin1String("id")))) {
    const QString kind = text(block, QLatin1String("kind"));
    const QString said = text(block, QLatin1String("text"));
    QString line;
    if (kind == QLatin1String("heading")) {
      line = QStringLiteral("## ") + said;
    } else if (kind == QLatin1String("checklist")) {
      line = (block.value(QLatin1String("checked")).toBool() ? QStringLiteral("- [x] ") : QStringLiteral("- [ ] ")) + said;
    } else if (kind == QLatin1String("callout")) {
      QStringList quoted;
      for (const QString& part : said.split(QLatin1Char('\n'))) quoted.append((QStringLiteral("> ") + part).trimmed());
      line = quoted.join(QLatin1Char('\n'));
    } else if (kind == QLatin1String("subpage_link")) {
      const QString linked = text(block, QLatin1String("linkedPageId"));
      const QString title = titleOf(mc, space, linked);
      line = QStringLiteral("[%1](#%2)").arg(title.isEmpty() ? said : title, linked);
    } else {
      line = said;
    }
    const bool item = kind == QLatin1String("checklist");
    if (item && inList) {
      parts.last() += QLatin1Char('\n') + line;
    } else {
      parts.append(line);
    }
    inList = item;
  }
  return parts.join(QStringLiteral("\n\n")) + QLatin1Char('\n');
}

// HalC2.Space.Markdown.parse: the title, and each block's kind, text,
// checked and linkedPageId.
std::pair<QString, QList<QJsonObject>> parseMarkdown(const QString& markdown) {
  static const QRegularExpression title(QStringLiteral("^#\\s+(.*)$"));
  static const QRegularExpression heading(QStringLiteral("^#{2,6}\\s+(.*)$"));
  static const QRegularExpression item(QStringLiteral("^\\s*[-*]\\s+\\[([ xX])\\]\\s?(.*)$"));
  static const QRegularExpression link(QStringLiteral("^\\[(.+)\\]\\(#([\\w-]+)\\)$"));
  static const QRegularExpression notParagraph(QStringLiteral("^(#{1,6}\\s|>|```|\\s*[-*]\\s+\\[[ xX]\\])"));
  const auto block = [](const QString& kind, const QString& said) {
    return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("text"), said}, {QStringLiteral("checked"), false},
                       {QStringLiteral("linkedPageId"), QJsonValue::Null}};
  };
  QStringList lines = QString(markdown).replace(QStringLiteral("\r\n"), QStringLiteral("\n")).split(QLatin1Char('\n'));
  QList<QJsonObject> blocks;
  QString pageTitle;
  for (qsizetype i = 0; i < lines.size();) {
    const QString line = lines.at(i);
    QRegularExpressionMatch match;
    if (line.trimmed().isEmpty()) {
      ++i;
    } else if (line.startsWith(QLatin1String("```"))) {
      QStringList code{line};
      while (++i < lines.size() && !lines.at(i).startsWith(QLatin1String("```"))) code.append(lines.at(i));
      if (i < lines.size()) code.append(lines.at(i++));
      blocks.append(block(QStringLiteral("paragraph"), code.join(QLatin1Char('\n'))));
    } else if ((match = title.match(line)).hasMatch()) {
      // A `# ` heading anywhere but the top is an ordinary heading.
      if (blocks.isEmpty() && pageTitle.isNull()) {
        pageTitle = match.captured(1).trimmed();
      } else {
        blocks.append(block(QStringLiteral("heading"), match.captured(1).trimmed()));
      }
      ++i;
    } else if ((match = heading.match(line)).hasMatch()) {
      blocks.append(block(QStringLiteral("heading"), match.captured(1).trimmed()));
      ++i;
    } else if ((match = item.match(line)).hasMatch()) {
      QJsonObject checklist = block(QStringLiteral("checklist"), match.captured(2));
      checklist.insert(QStringLiteral("checked"), match.captured(1) != QLatin1String(" "));
      blocks.append(checklist);
      ++i;
    } else if ((match = link.match(line.trimmed())).hasMatch()) {
      QJsonObject linked = block(QStringLiteral("subpage_link"), match.captured(1));
      linked.insert(QStringLiteral("linkedPageId"), match.captured(2));
      blocks.append(linked);
      ++i;
    } else if (line.startsWith(QLatin1Char('>'))) {
      QStringList quote;
      for (; i < lines.size() && lines.at(i).startsWith(QLatin1Char('>')); ++i) {
        QString part = lines.at(i).mid(1);
        if (part.startsWith(QLatin1Char(' '))) part.remove(0, 1);
        quote.append(part);
      }
      blocks.append(block(QStringLiteral("callout"), quote.join(QLatin1Char('\n'))));
    } else {
      QStringList paragraph;
      for (; i < lines.size() && !lines.at(i).trimmed().isEmpty() && !notParagraph.match(lines.at(i)).hasMatch(); ++i) {
        paragraph.append(lines.at(i));
      }
      blocks.append(block(QStringLiteral("paragraph"), paragraph.join(QLatin1Char('\n'))));
    }
  }
  return {pageTitle, blocks};
}

Answer createPage(FakeMc& mc, const QString& space, const QString& title, const QJsonValue& parent, const QJsonObject& extra = {}) {
  if (title.trimmed().isEmpty()) return refused(QStringLiteral("invalid"), QStringLiteral("A page needs a title."));
  if (parent.isString()) {
    if (const auto why = writable(mc, space, parent.toString())) return *why;
  }
  const QString id = newId(mc, QStringLiteral("page"));
  const QString at = stamp(mc);
  QJsonObject page{{QStringLiteral("id"), id},
                   {QStringLiteral("spaceId"), space},
                   {QStringLiteral("title"), title.trimmed()},
                   {QStringLiteral("parentPageId"), parent.isString() ? parent : QJsonValue(QJsonValue::Null)},
                   {QStringLiteral("sourceThreadId"), QJsonValue::Null},
                   {QStringLiteral("trashedAt"), QJsonValue::Null},
                   {QStringLiteral("createdAt"), at},
                   {QStringLiteral("updatedAt"), at}};
  for (auto it = extra.begin(); it != extra.end(); ++it) page.insert(it.key(), it.value());
  set(mc, streamOf(space), QStringLiteral("page"), id, page);
  return {{{QStringLiteral("page"), page}}};
}

Answer insertBlock(FakeMc& mc, const QString& space, const QString& pageId, const QJsonObject& spec, const QJsonValue& after,
                   const QJsonObject& author) {
  if (const auto why = writable(mc, space, pageId)) return *why;
  static const QStringList kinds{QStringLiteral("paragraph"), QStringLiteral("heading"), QStringLiteral("checklist"),
                                 QStringLiteral("callout"), QStringLiteral("subpage_link")};
  const QString kind = text(spec, QLatin1String("kind"));
  if (!kinds.contains(kind)) return refused(QStringLiteral("invalid"), QStringLiteral("There is no block kind %1.").arg(kind));
  const QString linked = text(spec, QLatin1String("linkedPageId"));
  if (kind == QLatin1String("subpage_link") && one(mc, streamOf(space), QStringLiteral("page"), linked).isEmpty()) {
    return refused(QStringLiteral("notFound"), QStringLiteral("A subpage link needs a page to link to."));
  }
  const std::optional<QString> order = place(mc, space, pageId, after);
  if (!order) return refused(QStringLiteral("notFound"), QStringLiteral("There is no block %1 on the page.").arg(after.toString()));
  const QString id = newId(mc, QStringLiteral("block"));
  const QString at = stamp(mc);
  QJsonObject block{{QStringLiteral("id"), id},
                    {QStringLiteral("pageId"), pageId},
                    {QStringLiteral("kind"), kind},
                    {QStringLiteral("text"), text(spec, QLatin1String("text"))},
                    {QStringLiteral("order"), *order},
                    {QStringLiteral("createdBy"), author},
                    {QStringLiteral("updatedBy"), author},
                    {QStringLiteral("createdAt"), at},
                    {QStringLiteral("updatedAt"), at}};
  if (kind == QLatin1String("checklist")) block.insert(QStringLiteral("checked"), spec.value(QLatin1String("checked")).toBool());
  if (kind == QLatin1String("subpage_link")) block.insert(QStringLiteral("linkedPageId"), linked);
  set(mc, streamOf(space), QStringLiteral("block"), id, block);
  return {{{QStringLiteral("block"), block}}};
}

Answer importMarkdown(FakeMc& mc, const QString& space, const QString& markdown, const QString& title, const QJsonValue& parent,
                      const QJsonObject& extra, const QJsonObject& author) {
  const auto [parsed, blocks] = parseMarkdown(markdown);
  const QString named = !title.trimmed().isEmpty() ? title : !parsed.trimmed().isEmpty() ? parsed : QStringLiteral("Untitled");
  const Answer made = createPage(mc, space, named, parent, extra);
  if (!made.error.isEmpty()) return made;
  const QString pageId = made.result.value(QLatin1String("page")).toObject().value(QLatin1String("id")).toString();
  for (const QJsonObject& block : blocks) insertBlock(mc, space, pageId, block, QJsonValue::Undefined, author);
  return made;
}

// The summary text generation writes of a thread.
const QString kSummaryTitle = QStringLiteral("Release plan");
const QString kSummary = QStringLiteral("Ship pages on Friday, once the Space streams are in.");

QJsonObject spaceOf(FakeMc& mc, const QString& id) {
  return one(mc, kIndex, QStringLiteral("space"), id);
}

QJsonObject makeSpace(FakeMc& mc, const QString& name) {
  const QString id = newId(mc, QStringLiteral("space"));
  const QString at = stamp(mc);
  const QJsonObject space{{QStringLiteral("id"), id}, {QStringLiteral("name"), name}, {QStringLiteral("createdAt"), at}, {QStringLiteral("updatedAt"), at}};
  set(mc, kIndex, QStringLiteral("space"), id, space);
  return space;
}

// Personal, for an MC that has no Space yet.
void seed(FakeMc& mc) {
  if (all(mc, kIndex, QStringLiteral("space")).isEmpty()) makeSpace(mc, QStringLiteral("Personal"));
}

Answer call(FakeMc& mc, const QString& method, const QJsonObject& in) {
  const QString space = text(in, QLatin1String("spaceId"));
  const QString stream = streamOf(space);
  const QString pageId = text(in, QLatin1String("pageId"));
  const QString blockId = text(in, QLatin1String("blockId"));
  const auto blank = [](const QJsonValue& value) { return value.toString().trimmed().isEmpty(); };

  if (method == QLatin1String("list")) {
    seed(mc);
    QJsonArray spaces;
    for (const QJsonObject& row : sortedBy(all(mc, kIndex, QStringLiteral("space")), QLatin1String("createdAt"))) spaces.append(row);
    return {{{QStringLiteral("spaces"), spaces}}};
  }
  if (method == QLatin1String("create")) {
    if (blank(in.value(QLatin1String("name")))) return refused(QStringLiteral("invalid"), QStringLiteral("A Space needs a name."));
    seed(mc);
    return {{{QStringLiteral("space"), makeSpace(mc, text(in, QLatin1String("name")).trimmed())}}};
  }
  if (spaceOf(mc, space).isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no Space %1.").arg(space));
  if (method == QLatin1String("rename")) {
    if (blank(in.value(QLatin1String("name")))) return refused(QStringLiteral("invalid"), QStringLiteral("A Space needs a name."));
    set(mc, kIndex, QStringLiteral("space"), space, {{QStringLiteral("name"), text(in, QLatin1String("name")).trimmed()}, {QStringLiteral("updatedAt"), stamp(mc)}});
    return {{{QStringLiteral("space"), spaceOf(mc, space)}}};
  }
  if (method == QLatin1String("delete")) {
    if (!all(mc, stream, QStringLiteral("page")).isEmpty()) {
      return refused(QStringLiteral("notEmpty"), QStringLiteral("A Space with pages cannot be deleted; delete its pages first."));
    }
    remove(mc, kIndex, QStringLiteral("space"), space);
    return {{{QStringLiteral("spaceId"), space}}};
  }
  if (method == QLatin1String("page.create")) return createPage(mc, space, text(in, QLatin1String("title")), in.value(QLatin1String("parentPageId")));
  if (method == QLatin1String("page.importMarkdown")) {
    return importMarkdown(mc, space, text(in, QLatin1String("markdown")), text(in, QLatin1String("title")), in.value(QLatin1String("parentPageId")), {}, kUser);
  }
  if (method == QLatin1String("page.createFromThread")) {
    const QString threadId = text(in, QLatin1String("threadId"));
    const QJsonObject thread = mc.threads.value(threadId);
    QString root = text(thread, QLatin1String("worktreePath"));
    if (root.isEmpty()) root = text(mc.projects.value(text(thread, QLatin1String("projectId"))), QLatin1String("workspaceRoot"));
    if (thread.isEmpty() || root.isEmpty()) {
      return refused(QStringLiteral("notFound"), QStringLiteral("There is no thread %1 with a project folder on this MC.").arg(threadId));
    }
    if (!fake(mc).talked.contains(threadId)) return refused(QStringLiteral("invalid"), QStringLiteral("The thread has nothing to summarise yet."));
    fake(mc).cwd = root;
    fake(mc).summarised = threadId;
    const QString tag = QStringLiteral("SpaceTextGenerationError");
    if (fake(mc).generation == QLatin1String("unavailable")) return refused(QStringLiteral("unavailable"), QStringLiteral("No text generation provider is set up."), tag);
    if (fake(mc).generation == QLatin1String("failed")) return refused(QStringLiteral("failed"), QStringLiteral("The provider stopped answering."), tag);
    return importMarkdown(mc, space, QStringLiteral("# %1\n\n%2\n").arg(kSummaryTitle, kSummary), kSummaryTitle, in.value(QLatin1String("parentPageId")),
                          {{QStringLiteral("sourceThreadId"), threadId}}, agent(threadId));
  }

  if (method.startsWith(QLatin1String("page."))) {
    const QJsonObject page = one(mc, stream, QStringLiteral("page"), pageId);
    if (page.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no page %1.").arg(pageId));
    const auto answer = [&] { return Answer{{{QStringLiteral("page"), one(mc, stream, QStringLiteral("page"), pageId)}}}; };
    if (method == QLatin1String("page.exportMarkdown")) return {{{QStringLiteral("markdown"), exportMarkdown(mc, space, page)}}};
    if (method == QLatin1String("page.restore")) {
      if (!trashed(page)) return refused(QStringLiteral("invalid"), QStringLiteral("The page is not in the trash."));
      // Back where it was, unless that page is gone or in the trash itself.
      const QJsonObject parent = one(mc, stream, QStringLiteral("page"), text(page, QLatin1String("parentPageId")));
      const bool keep = !parent.isEmpty() && live(mc, space, parent);
      set(mc, stream, QStringLiteral("page"), pageId,
          {{QStringLiteral("trashedAt"), QJsonValue::Null}, {QStringLiteral("parentPageId"), keep ? page.value(QLatin1String("parentPageId")) : QJsonValue::Null},
           {QStringLiteral("updatedAt"), stamp(mc)}});
      return answer();
    }
    if (method == QLatin1String("page.delete")) {
      if (!trashed(page)) return refused(QStringLiteral("invalid"), QStringLiteral("Only a page in the trash can be deleted for good."));
      const QStringList gone = within(mc, space, pageId);
      for (const QJsonObject& comment : all(mc, stream, QStringLiteral("comment"))) {
        if (gone.contains(text(comment, QLatin1String("pageId")))) remove(mc, stream, QStringLiteral("comment"), text(comment, QLatin1String("id")));
      }
      for (const QJsonObject& block : all(mc, stream, QStringLiteral("block"))) {
        if (gone.contains(text(block, QLatin1String("pageId"))) || gone.contains(text(block, QLatin1String("linkedPageId")))) {
          remove(mc, stream, QStringLiteral("block"), text(block, QLatin1String("id")));
        }
      }
      for (const QString& id : gone) remove(mc, stream, QStringLiteral("page"), id);
      return {{{QStringLiteral("deletedPageIds"), QJsonArray::fromStringList(gone)}}};
    }
    if (!live(mc, space, page)) return refused(QStringLiteral("trashed"), QStringLiteral("The page is in the trash."));
    if (method == QLatin1String("page.rename")) {
      if (blank(in.value(QLatin1String("title")))) return refused(QStringLiteral("invalid"), QStringLiteral("A page needs a title."));
      set(mc, stream, QStringLiteral("page"), pageId, {{QStringLiteral("title"), text(in, QLatin1String("title")).trimmed()}, {QStringLiteral("updatedAt"), stamp(mc)}});
      return answer();
    }
    if (method == QLatin1String("page.move")) {
      const QJsonValue parent = in.value(QLatin1String("parentPageId"));
      if (parent.isString()) {
        if (within(mc, space, pageId).contains(parent.toString())) return refused(QStringLiteral("cycle"), QStringLiteral("A page cannot move inside itself."));
        if (const auto why = writable(mc, space, parent.toString())) return *why;
      }
      set(mc, stream, QStringLiteral("page"), pageId,
          {{QStringLiteral("parentPageId"), parent.isString() ? parent : QJsonValue(QJsonValue::Null)}, {QStringLiteral("updatedAt"), stamp(mc)}});
      return answer();
    }
    if (method == QLatin1String("page.trash")) {
      const QString at = stamp(mc);
      set(mc, stream, QStringLiteral("page"), pageId, {{QStringLiteral("trashedAt"), at}, {QStringLiteral("updatedAt"), at}});
      return answer();
    }
  }

  if (method == QLatin1String("block.insert")) {
    return insertBlock(mc, space, pageId, in, in.contains(QLatin1String("afterBlockId")) ? in.value(QLatin1String("afterBlockId")) : QJsonValue::Undefined, kUser);
  }
  if (method.startsWith(QLatin1String("block."))) {
    const QJsonObject block = one(mc, stream, QStringLiteral("block"), blockId);
    if (block.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no block %1.").arg(blockId));
    if (const auto why = writable(mc, space, text(block, QLatin1String("pageId")))) return *why;
    const auto write = [&](QJsonObject fields) {
      fields.insert(QStringLiteral("updatedBy"), kUser);
      fields.insert(QStringLiteral("updatedAt"), stamp(mc));
      set(mc, stream, QStringLiteral("block"), blockId, fields);
      return Answer{{{QStringLiteral("block"), one(mc, stream, QStringLiteral("block"), blockId)}}};
    };
    if (method == QLatin1String("block.update")) return write({{QStringLiteral("text"), in.value(QLatin1String("text"))}});
    if (method == QLatin1String("block.setChecked")) {
      if (text(block, QLatin1String("kind")) != QLatin1String("checklist")) {
        return refused(QStringLiteral("invalid"), QStringLiteral("Only a checklist item can be ticked."));
      }
      return write({{QStringLiteral("checked"), in.value(QLatin1String("checked")).toBool()}});
    }
    if (method == QLatin1String("block.move")) {
      const QJsonValue after = in.contains(QLatin1String("afterBlockId")) ? in.value(QLatin1String("afterBlockId")) : QJsonValue::Undefined;
      const std::optional<QString> order = place(mc, space, text(block, QLatin1String("pageId")), after, blockId);
      if (!order) return refused(QStringLiteral("notFound"), QStringLiteral("There is no block %1 on the page.").arg(after.toString()));
      return write({{QStringLiteral("order"), *order}});
    }
    if (method == QLatin1String("block.delete")) {
      for (const QJsonObject& comment : all(mc, stream, QStringLiteral("comment"))) {
        if (text(comment, QLatin1String("blockId")) == blockId) remove(mc, stream, QStringLiteral("comment"), text(comment, QLatin1String("id")));
      }
      remove(mc, stream, QStringLiteral("block"), blockId);
      return {{{QStringLiteral("blockId"), blockId}}};
    }
  }

  if (method == QLatin1String("comment.add")) {
    if (const auto why = writable(mc, space, pageId)) return *why;
    if (blank(in.value(QLatin1String("body")))) return refused(QStringLiteral("invalid"), QStringLiteral("A comment needs a body."));
    if (!blockId.isEmpty() && text(one(mc, stream, QStringLiteral("block"), blockId), QLatin1String("pageId")) != pageId) {
      return refused(QStringLiteral("notFound"), QStringLiteral("There is no block %1 on the page.").arg(blockId));
    }
    const QString id = newId(mc, QStringLiteral("comment"));
    const QString at = stamp(mc);
    const QJsonObject comment{{QStringLiteral("id"), id},
                              {QStringLiteral("pageId"), pageId},
                              {QStringLiteral("blockId"), blockId.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(blockId)},
                              {QStringLiteral("author"), kUser},
                              {QStringLiteral("body"), text(in, QLatin1String("body")).trimmed()},
                              {QStringLiteral("resolvedAt"), QJsonValue::Null},
                              {QStringLiteral("createdAt"), at},
                              {QStringLiteral("updatedAt"), at}};
    set(mc, stream, QStringLiteral("comment"), id, comment);
    return {{{QStringLiteral("comment"), comment}}};
  }
  if (method == QLatin1String("comment.resolve") || method == QLatin1String("comment.reopen")) {
    const QString id = text(in, QLatin1String("commentId"));
    const QJsonObject comment = one(mc, stream, QStringLiteral("comment"), id);
    if (comment.isEmpty()) return refused(QStringLiteral("notFound"), QStringLiteral("There is no comment %1.").arg(id));
    const bool resolve = method == QLatin1String("comment.resolve");
    // Already so: nothing changes.
    if (resolve == !comment.value(QLatin1String("resolvedAt")).isNull()) return {{{QStringLiteral("comment"), comment}}};
    const QString at = stamp(mc);
    set(mc, stream, QStringLiteral("comment"), id, {{QStringLiteral("resolvedAt"), resolve ? QJsonValue(at) : QJsonValue(QJsonValue::Null)}, {QStringLiteral("updatedAt"), at}});
    return {{{QStringLiteral("comment"), one(mc, stream, QStringLiteral("comment"), id)}}};
  }
  return refused(QStringLiteral("invalid"), QStringLiteral("space.%1 is missing a required field.").arg(method));
}

const FakeMc::Extension spaceCalls([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("space."), [&mc](const FakeMc::Rpc& rpc) {
    const Answer answer = call(mc, rpc.method.mid(6), rpc.payload);
    fake(mc).lastMethod = rpc.method;
    fake(mc).last = answer;
    if (answer.error.isEmpty()) {
      mc.reply(rpc, answer.result);
    } else {
      mc.refuse(rpc, answer.error, answer.detail);
    }
  });
});

// --- The scenario's Spaces, pages and blocks, by name ------------------------

// Something the scenario made, kept by what the user calls it.
void name(World& world, const QString& kind, const QString& said, const QString& id) {
  fake(world.mc).named.insert(kind + QLatin1Char('\n') + said, id);
}

QString idOfSpace(World& world, const QString& name) {
  for (const QJsonObject& space : all(world.mc, kIndex, QStringLiteral("space"))) {
    if (text(space, QLatin1String("name")) == name) return text(space, QLatin1String("id"));
  }
  fail(QStringLiteral("the MC has no Space %1").arg(name));
}

QString current(World& world) {
  const QString space = fake(world.mc).current;
  expect(!space.isEmpty(), QStringLiteral("no Space was made for the scenario"));
  return space;
}

// The page `title` of the scenario's Space, or "" when there is none.
QString findPage(World& world, const QString& title) {
  for (const QJsonObject& page : all(world.mc, streamOf(current(world)), QStringLiteral("page"))) {
    if (text(page, QLatin1String("title")) == title) return text(page, QLatin1String("id"));
  }
  return {};
}

QString idOfPage(World& world, const QString& title) {
  const QString id = findPage(world, title);
  expect(!id.isEmpty(), QStringLiteral("the Space has no page %1").arg(title));
  return id;
}

QJsonObject findBlock(World& world, const QString& said) {
  for (const QJsonObject& block : all(world.mc, streamOf(current(world)), QStringLiteral("block"))) {
    if (text(block, QLatin1String("text")) == said) return block;
  }
  return {};
}

QJsonObject blockSaying(World& world, const QString& said) {
  const QJsonObject block = findBlock(world, said);
  expect(!block.isEmpty(), QStringLiteral("the Space has no block %1").arg(said));
  return block;
}

QString idOfComment(World& world, const QString& body) {
  for (const QJsonObject& comment : all(world.mc, streamOf(current(world)), QStringLiteral("comment"))) {
    if (text(comment, QLatin1String("body")) == body) return text(comment, QLatin1String("id"));
  }
  fail(QStringLiteral("the Space has no comment %1").arg(body));
}

// What the MC is told by the scenario's setting up, as a client would ask it.
QJsonObject given(World& world, const QString& method, QJsonObject in) {
  if (method != QLatin1String("create") && !in.contains(QLatin1String("spaceId"))) in.insert(QStringLiteral("spaceId"), current(world));
  const Answer answer = call(world.mc, method, in);
  expect(answer.error.isEmpty(), QStringLiteral("the MC refused space.%1: %2").arg(method, answer.error));
  world.sync();
  return answer.result;
}

void givenSpace(World& world, const QString& name) {
  const QJsonObject space = given(world, QStringLiteral("create"), {{QStringLiteral("name"), name}}).value(QLatin1String("space")).toObject();
  fake(world.mc).current = text(space, QLatin1String("id"));
}

QString givenPage(World& world, const QString& title, const QString& parent = {}) {
  if (const QString id = findPage(world, title); !id.isEmpty()) return id;
  const QJsonObject page = given(world, QStringLiteral("page.create"),
                                 {{QStringLiteral("title"), title}, {QStringLiteral("parentPageId"), parent.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(parent)}})
                               .value(QLatin1String("page"))
                               .toObject();
  name(world, QStringLiteral("page"), title, text(page, QLatin1String("id")));
  return text(page, QLatin1String("id"));
}

void givenBlock(World& world, const QString& page, const QString& kind, const QString& said, bool checked = false) {
  given(world, QStringLiteral("block.insert"),
        {{QStringLiteral("pageId"), givenPage(world, page)}, {QStringLiteral("kind"), kind}, {QStringLiteral("text"), said}, {QStringLiteral("checked"), checked}});
}

QStringList listed(const QString& names) {
  return names.isEmpty() ? QStringList() : names.split(QStringLiteral(", "));
}

QString threadNamed(World& world, const QString& title) {
  for (auto it = world.mc.threads.cbegin(); it != world.mc.threads.cend(); ++it) {
    if (it->value(QLatin1String("title")).toString() == title) return it.key();
  }
  fail(QStringLiteral("the MC has no thread %1").arg(title));
}

// --- The client -------------------------------------------------------------

SpaceController* viewOf(World& world) {
  auto* controller = world.native().controller<SpaceController>();
  if (!controller) fail(QStringLiteral("the shell has no SpaceController"));
  return controller;
}

QStringList column(const SpaceRows* rows, const QString& role) {
  QStringList values;
  for (const QVariantMap& row : rows->rows()) values.append(row.value(role).toString());
  return values;
}

QVariantList listOf(const SpaceRows* rows) {
  QVariantList list;
  for (const QVariantMap& row : rows->rows()) list.append(row);
  return list;
}

QVariantList tableOf(const Table& table) {
  QVariantList list;
  for (const QStringList& row : table) list.append(row);
  return list;
}

QString describe(World& world) {
  SpaceController* view = viewOf(world);
  return QStringLiteral("the Space view shows %1 (%2): spaces %3, pages %4, trash %5, blocks %6, comments %7; it says %8")
      .arg(view->spaceName(), view->status(), show(column(view->spaces(), QStringLiteral("name"))), show(column(view->pages(), QStringLiteral("title"))),
           show(column(view->trash(), QStringLiteral("title"))), show(listOf(view->blocks())),
           show(listOf(view->comments())), show(world.state(QStringLiteral("space"))));
}

// The Space view, open and following the MC's Spaces.
void openSpaces(World& world) {
  if (world.shellSubscriptions() == 0) world.connect();
  if (world.native().controller<NavigationController>()->route().kind != QLatin1String("space")) {
    world.bridge().dispatch(SpaceController::kOpen, QVariantMap{});
  }
  world.waitFor([&] { return viewOf(world)->index().live() && viewOf(world)->spaces()->rowCount() > 0; },
                [&] { return QStringLiteral("the Space view to follow the Spaces; %1").arg(describe(world)); });
}

// The Space `id`, shown and followed.
void look(World& world, const QString& id) {
  openSpaces(world);
  world.waitFor([&] { return viewOf(world)->spaces()->indexOf(id) >= 0; }, [&] { return QStringLiteral("the Space to be listed; %1").arg(describe(world)); });
  if (viewOf(world)->spaceId() != id) world.bridge().dispatch(QStringLiteral("space.select"), QVariantMap{{QStringLiteral("spaceId"), id}});
  world.waitFor([&] { return viewOf(world)->spaceId() == id && viewOf(world)->space().live(); },
                [&] { return QStringLiteral("the Space to be followed; %1").arg(describe(world)); });
}

// The page `id` of the scenario's Space, open.
void lookAtPage(World& world, const QString& id) {
  look(world, current(world));
  world.waitFor([&] { return viewOf(world)->space().of(QStringLiteral("page")).contains(id); },
                [&] { return QStringLiteral("the Space's copy to hold the page; %1").arg(describe(world)); });
  if (viewOf(world)->pageId() != id) world.bridge().dispatch(QStringLiteral("space.selectPage"), QVariantMap{{QStringLiteral("pageId"), id}});
  world.waitFor([&] { return viewOf(world)->pageId() == id; }, [&] { return QStringLiteral("the page to open; %1").arg(describe(world)); });
}

// The user does `action` on the Space view, and it has the MC's answer.
void act(World& world, const QString& action, const QVariantMap& payload) {
  world.bridge().dispatch(action, payload);
  world.sync();
}

void actOnPage(World& world, const QString& pageId, const QString& action, QVariantMap payload) {
  lookAtPage(world, pageId);
  payload.insert(QStringLiteral("pageId"), pageId);
  act(world, action, payload);
}

void actOnBlock(World& world, const QString& said, const QString& action, QVariantMap payload) {
  const QJsonObject block = blockSaying(world, said);
  lookAtPage(world, text(block, QLatin1String("pageId")));
  payload.insert(QStringLiteral("blockId"), text(block, QLatin1String("id")));
  act(world, action, payload);
}

void expectShown(World& world, const std::function<bool()>& shown, const QString& wanted) {
  world.waitFor(shown, [&] { return QStringLiteral("%1; %2").arg(wanted, describe(world)); });
}

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

bool toldOf(World& world, const QString& start) {
  for (const QVariant& toast : toasts(world)) {
    if (toast.toMap().value(QStringLiteral("title")).toString().startsWith(start)) return true;
  }
  return false;
}

// What the blocks of the open page say, in their order.
QStringList blockTexts(World& world) {
  return column(viewOf(world)->blocks(), QStringLiteral("text"));
}

// The rows of a page's blocks, as the feature's tables write them.
Table blockTable(World& world) {
  Table rows;
  for (const QVariantMap& block : viewOf(world)->blocks()->rows()) {
    const bool item = block.value(QStringLiteral("kind")) == QLatin1String("checklist");
    rows.append({block.value(QStringLiteral("kind")).toString(), block.value(QStringLiteral("text")).toString(),
                 item ? (block.value(QStringLiteral("checked")).toBool() ? QStringLiteral("yes") : QStringLiteral("no")) : QString()});
  }
  return rows;
}

std::optional<QVariantMap> rowOf(const SpaceRows* rows, const QString& id) {
  const int row = rows->indexOf(id);
  if (row < 0) return std::nullopt;
  return rows->get(row);
}

// Another client of the MC following the Spaces, and the Space `id` when set.
void watch(World& world, const QString& id = {}) {
  FakeSpaces& spaces = fake(world.mc);
  seed(world.mc);
  spaces.second = std::make_unique<SpacePages>();
  SpacePages* second = spaces.second.get();
  for (const QJsonObject& frame : snapshot(world.mc, kIndex)) second->receiveIndex(frame);
  if (id.isEmpty()) return;
  second->selectSpace(id);
  for (const QJsonObject& frame : snapshot(world.mc, streamOf(id))) second->receiveSpace(frame);
  expect(second->spaceId() == id && second->space().live(), QStringLiteral("the second client did not follow the Space"));
}

SpacePages& second(World& world) {
  SpacePages* pages = fake(world.mc).second.get();
  if (!pages) fail(QStringLiteral("no second client is watching"));
  return *pages;
}

}  // namespace

bool spaceTick(World& world, const QString& said, bool checked) {
  if (fake(world.mc).current.isEmpty()) return false;
  const QJsonObject block = findBlock(world, said);
  if (text(block, QLatin1String("kind")) != QLatin1String("checklist")) return false;
  actOnBlock(world, said, QStringLiteral("space.block.setChecked"), {{QStringLiteral("checked"), checked}});
  return true;
}

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  // Spaces.
  step(QStringLiteral("the user lists their Spaces"), [](World& world, const Captures&, const Table&) {
    openSpaces(world);
  });
  step(QStringLiteral("the user has listed their Spaces"), [](World& world, const Captures&, const Table&) {
    openSpaces(world);
    // Another start of the app lists them again.
    world.restart();
    world.connect();
  });
  step(QStringLiteral("the Spaces are %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openSpaces(world);
    expectShown(world, [&] { return column(viewOf(world)->spaces(), QStringLiteral("name")) == listed(c[0]); }, QStringLiteral("the Spaces to be %1").arg(c[0]));
    expect(column(viewOf(world)->spaces(), QStringLiteral("name")) == listed(c[0]), describe(world));
  });
  step(QStringLiteral("the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenSpace(world, c[0]);
  });
  step(QStringLiteral("the Space %1 with the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenSpace(world, c[0]);
    givenPage(world, c[1]);
  });
  step(QStringLiteral("the user makes the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    openSpaces(world);
    act(world, QStringLiteral("space.create"), {{QStringLiteral("name"), c[0]}});
  });
  step(QStringLiteral("the user renames the Space %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    act(world, QStringLiteral("space.rename"), {{QStringLiteral("spaceId"), idOfSpace(world, c[0])}, {QStringLiteral("name"), c[1]}});
  });
  step(QStringLiteral("the user deletes the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    act(world, QStringLiteral("space.delete"), {{QStringLiteral("spaceId"), idOfSpace(world, c[0])}});
  });
  step(QStringLiteral("the (Space|page) request is refused"), [](World& world, const Captures&, const Table&) {
    const FakeSpaces& spaces = fake(world.mc);
    expect(!spaces.last.error.isEmpty(), QStringLiteral("the MC answered %1 with %2").arg(spaces.lastMethod, show(spaces.last.result.toVariantMap())));
    const QString said = world.state(QStringLiteral("space")).toMap().value(QStringLiteral("error")).toString();
    expect(said == spaces.last.error && toldOf(world, said),
           QStringLiteral("the user is not told \"%1\": %2, toasts %3").arg(spaces.last.error, describe(world), show(toasts(world))));
  });
  step(QStringLiteral("a second client watching the Spaces"), [](World& world, const Captures&, const Table&) {
    watch(world);
  });
  step(QStringLiteral("the second client sees the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList names = column(second(world).spaces(), QStringLiteral("name"));
    expect(names.contains(c[0]), QStringLiteral("the second client shows the Spaces %1").arg(show(names)));
  });

  // Pages and their places.
  step(QStringLiteral("the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenPage(world, c[0]);
  });
  step(QStringLiteral("the pages %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenPage(world, c[0]);
    givenPage(world, c[1]);
  });
  step(QStringLiteral("the page %1 inside %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenPage(world, c[0], givenPage(world, c[1]));
  });
  step(QStringLiteral("the user makes the page %1(?: inside %1)?").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString parent = c.value(1).isEmpty() ? QString() : idOfPage(world, c[1]);
    look(world, current(world));
    act(world, QStringLiteral("space.page.create"), {{QStringLiteral("title"), c[0]}, {QStringLiteral("parentPageId"), parent}});
  });
  step(QStringLiteral("the pages of %1 are %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    expectShown(world, [&] { return column(viewOf(world)->pages(), QStringLiteral("title")) == listed(c[1]); }, QStringLiteral("the pages to be %1").arg(c[1]));
  });
  step(QStringLiteral("%1 is a subpage of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, current(world));
    const QString child = idOfPage(world, c[0]);
    const QString parent = idOfPage(world, c[1]);
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->pages(), child);
      const auto above = rowOf(viewOf(world)->pages(), parent);
      return row && above && row->value(QStringLiteral("parentPageId")) == parent &&
             row->value(QStringLiteral("depth")).toInt() == above->value(QStringLiteral("depth")).toInt() + 1;
    }, QStringLiteral("%1 to sit inside %2").arg(c[0], c[1]));
  });
  step(QStringLiteral("%1 is not inside another page").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, current(world));
    const QString page = idOfPage(world, c[0]);
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->pages(), page);
      return row && row->value(QStringLiteral("parentPageId")).toString().isEmpty() && row->value(QStringLiteral("depth")).toInt() == 0;
    }, QStringLiteral("%1 to sit at the top of the Space").arg(c[0]));
  });
  step(QStringLiteral("the user renames the page %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.rename"), {{QStringLiteral("title"), c[1]}});
  });
  step(QStringLiteral("the user moves the page %1 to the top of the Space").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.move"), {{QStringLiteral("parentPageId"), QString()}});
  });
  step(QStringLiteral("the user moves the page %1 into %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.move"), {{QStringLiteral("parentPageId"), idOfPage(world, c[1])}});
  });
  step(QStringLiteral("the page %1 reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], QStringLiteral("paragraph"), c[1]);
  });
  step(QStringLiteral("the MC restarts"), [](World& world, const Captures&, const Table&) {
    look(world, current(world));
    // What it kept is all a restarted MC has: no follower's offset resumes it.
    world.mc.part<FakeStreams>().handle = QStringLiteral("log-2.1");
    world.mc.drop();
    world.waitFor([&] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to see the MC go"));
  });
  step(QStringLiteral("the page %1 still reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.native().client()->isReady(); }, QStringLiteral("the shell to reconnect"));
    lookAtPage(world, idOfPage(world, c[0]));
    expectShown(world, [&] { return blockTexts(world).contains(c[1]); }, QStringLiteral("%1 to read %2").arg(c[0], c[1]));
  });

  // Trash.
  step(QStringLiteral("the user moves the page %1 to the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.trash"), {});
  });
  step(QStringLiteral("the page %1 is in the trash").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, QStringLiteral("page.trash"), {{QStringLiteral("pageId"), givenPage(world, c[0])}});
  });
  step(QStringLiteral("the trash of %1 holds %1").arg(q), [](World& world, const Captures& c, const Table&) {
    look(world, idOfSpace(world, c[0]));
    expectShown(world, [&] { return column(viewOf(world)->trash(), QStringLiteral("title")) == listed(c[1]); }, QStringLiteral("the trash to hold %1").arg(c[1]));
  });
  step(QStringLiteral("the user restores the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.restore"), {});
  });
  step(QStringLiteral("the user writes %1 on the page %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[1]), QStringLiteral("space.block.insert"), {{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("text"), c[0]}});
  });
  step(QStringLiteral("the user deletes the page %1 for good").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.delete"), {});
  });
  step(QStringLiteral("no blocks or comments of %1 or %1 remain").arg(q), [](World& world, const Captures& c, const Table&) {
    const FakeSpaces& spaces = fake(world.mc);
    const QSet<QString> gone{spaces.named.value(QStringLiteral("page\n") + c[0]), spaces.named.value(QStringLiteral("page\n") + c[1])};
    look(world, current(world));
    const SpaceStream& copy = viewOf(world)->space();
    for (const QString& kind : {QStringLiteral("page"), QStringLiteral("block"), QStringLiteral("comment")}) {
      for (const QJsonObject& entity : copy.of(kind)) {
        const bool left = gone.contains(text(entity, kind == QLatin1String("page") ? QLatin1String("id") : QLatin1String("pageId")));
        expect(!left, QStringLiteral("the client still holds the %1 %2").arg(kind, show(entity.toVariantMap())));
      }
    }
  });

  // Blocks.
  step(QStringLiteral("the user adds a (paragraph|heading|checklist|callout) block %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[2]), QStringLiteral("space.block.insert"), {{QStringLiteral("kind"), c[0]}, {QStringLiteral("text"), c[1]}});
  });
  step(QStringLiteral("%1 has a (paragraph|heading|checklist|callout) block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    expectShown(world, [&] {
      const QList<QVariantMap>& rows = viewOf(world)->blocks()->rows();
      return std::any_of(rows.cbegin(), rows.cend(), [&](const QVariantMap& block) {
        return block.value(QStringLiteral("kind")) == c[1] && block.value(QStringLiteral("text")) == c[2];
      });
    }, QStringLiteral("a %1 block %2").arg(c[1], c[2]));
  });
  step(QStringLiteral("the user links %1 from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[1]), QStringLiteral("space.block.insert"),
              {{QStringLiteral("kind"), QStringLiteral("subpage_link")}, {QStringLiteral("text"), c[0]}, {QStringLiteral("linkedPageId"), idOfPage(world, c[0])}});
  });
  step(QStringLiteral("%1 links to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    const QString linked = idOfPage(world, c[1]);
    expectShown(world, [&] {
      const QList<QVariantMap>& rows = viewOf(world)->blocks()->rows();
      return std::any_of(rows.cbegin(), rows.cend(), [&](const QVariantMap& block) {
        return block.value(QStringLiteral("kind")) == QLatin1String("subpage_link") && block.value(QStringLiteral("linkedPageId")) == linked &&
               block.value(QStringLiteral("linkedTitle")) == c[1];
      });
    }, QStringLiteral("a link to %1").arg(c[1]));
  });
  step(QStringLiteral("%1 has the blocks %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QString& said : listed(c[1])) givenBlock(world, c[0], QStringLiteral("paragraph"), said);
  });
  step(QStringLiteral("%1 has the checklist item %1").arg(q), [](World& world, const Captures& c, const Table&) {
    givenBlock(world, c[0], QStringLiteral("checklist"), c[1]);
  });
  step(QStringLiteral("the user adds %1 after %1 on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnPage(world, idOfPage(world, c[2]), QStringLiteral("space.block.insert"),
              {{QStringLiteral("kind"), QStringLiteral("paragraph")}, {QStringLiteral("text"), c[0]},
               {QStringLiteral("afterBlockId"), text(blockSaying(world, c[1]), QLatin1String("id"))}});
  });
  step(QStringLiteral("the blocks of %1 read %1").arg(q), [](World& world, const Captures& c, const Table&) {
    lookAtPage(world, idOfPage(world, c[0]));
    expectShown(world, [&] { return blockTexts(world) == listed(c[1]); }, QStringLiteral("the blocks to read %1").arg(c[1]));
  });
  step(QStringLiteral("the user changes the block %1 to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnBlock(world, c[0], QStringLiteral("space.block.update"), {{QStringLiteral("text"), c[1]}});
  });
  step(QStringLiteral("the user ticks %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnBlock(world, c[0], QStringLiteral("space.block.setChecked"), {{QStringLiteral("checked"), true}});
  });
  step(QStringLiteral("%1 is (not )?ticked").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = text(blockSaying(world, c[0]), QLatin1String("id"));
    const bool wanted = c.value(1).isEmpty();
    lookAtPage(world, text(blockSaying(world, c[0]), QLatin1String("pageId")));
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->blocks(), id);
      // What the MC wrote, not only what the user asked for.
      return row && row->value(QStringLiteral("checked")).toBool() == wanted && !viewOf(world)->pending(id, QStringLiteral("checked")) &&
             viewOf(world)->space().entity(QStringLiteral("block"), id).value(QLatin1String("checked")).toBool() == wanted;
    }, QStringLiteral("%1 to be %2").arg(c[0], wanted ? QStringLiteral("ticked") : QStringLiteral("unticked")));
  });
  step(QStringLiteral("the user moves the block %1 before %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject before = blockSaying(world, c[1]);
    lookAtPage(world, text(before, QLatin1String("pageId")));
    // The block above the one it goes before, if any.
    const QStringList ids = column(viewOf(world)->blocks(), QStringLiteral("id"));
    const qsizetype at = ids.indexOf(text(before, QLatin1String("id")));
    expect(at >= 0, describe(world));
    // What the move changes, on the MC and in the client's rows.
    FakeSpaces& spaces = fake(world.mc);
    spaces.mark = world.mc.part<FakeStreams>().log.value(streamOf(current(world))).size();
    spaces.seen.clear();
    SpaceRows* rows = viewOf(world)->blocks();
    const auto idAt = [rows](int row) { return rows->get(row).value(QStringLiteral("id")).toString(); };
    QObject::connect(rows, &QAbstractItemModel::rowsAboutToBeMoved, rows, [&spaces, idAt](const QModelIndex&, int first, int, const QModelIndex&, int) {
      spaces.seen.append(QStringLiteral("moved ") + idAt(first));
    });
    QObject::connect(rows, &QAbstractItemModel::dataChanged, rows, [&spaces, idAt](const QModelIndex& first, const QModelIndex& last) {
      for (int row = first.row(); row <= last.row(); ++row) spaces.seen.append(QStringLiteral("changed ") + idAt(row));
    });
    for (const auto signal : {&QAbstractItemModel::rowsInserted, &QAbstractItemModel::rowsRemoved}) {
      QObject::connect(rows, signal, rows, [&spaces] { spaces.seen.append(QStringLiteral("rows came or went")); });
    }
    QObject::connect(rows, &QAbstractItemModel::modelReset, rows, [&spaces] { spaces.seen.append(QStringLiteral("reset")); });
    actOnBlock(world, c[0], QStringLiteral("space.block.move"), {{QStringLiteral("afterBlockId"), at > 0 ? ids.at(at - 1) : QString()}});
  });
  step(QStringLiteral("only the block %1 changed").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = text(blockSaying(world, c[0]), QLatin1String("id"));
    const FakeSpaces& spaces = fake(world.mc);
    const QList<FakeStreams::Change> log = world.mc.part<FakeStreams>().log.value(streamOf(current(world)));
    expect(log.size() > spaces.mark, QStringLiteral("the MC wrote nothing"));
    for (qsizetype i = spaces.mark; i < log.size(); ++i) {
      expect(log.at(i).kind == QLatin1String("block") && log.at(i).id == id,
             QStringLiteral("the MC also wrote the %1 %2: %3").arg(log.at(i).kind, log.at(i).id, show(log.at(i).patch.toVariantMap())));
    }
    expect(spaces.seen == QStringList{QStringLiteral("moved ") + id}, QStringLiteral("the client's blocks: %1").arg(show(spaces.seen)));
  });
  step(QStringLiteral("the user deletes the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    actOnBlock(world, c[0], QStringLiteral("space.block.delete"), {});
  });
  step(QStringLiteral("a second client watching the Space %1").arg(q), [](World& world, const Captures& c, const Table&) {
    watch(world, idOfSpace(world, c[0]));
  });
  step(QStringLiteral("the second client sees the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList texts = column(second(world).blocks(), QStringLiteral("text"));
    expect(texts.contains(c[0]), QStringLiteral("the second client shows the blocks %1").arg(show(texts)));
  });

  // Comments.
  step(QStringLiteral("the user comments %1 on the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject block = blockSaying(world, c[1]);
    actOnBlock(world, c[1], QStringLiteral("space.comment.add"), {{QStringLiteral("pageId"), text(block, QLatin1String("pageId"))}, {QStringLiteral("body"), c[0]}});
  });
  step(QStringLiteral("the comment %1 on the block %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject block = blockSaying(world, c[1]);
    given(world, QStringLiteral("comment.add"),
          {{QStringLiteral("pageId"), text(block, QLatin1String("pageId"))}, {QStringLiteral("blockId"), text(block, QLatin1String("id"))}, {QStringLiteral("body"), c[0]}});
  });
  step(QStringLiteral("the comment %1 is resolved already").arg(q), [](World& world, const Captures& c, const Table&) {
    given(world, QStringLiteral("comment.resolve"), {{QStringLiteral("commentId"), idOfComment(world, c[0])}});
  });
  step(QStringLiteral("the user (resolves|reopens) the comment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOfComment(world, c[1]);
    lookAtPage(world, text(one(world.mc, streamOf(current(world)), QStringLiteral("comment"), id), QLatin1String("pageId")));
    act(world, c[0] == QLatin1String("resolves") ? QStringLiteral("space.comment.resolve") : QStringLiteral("space.comment.reopen"), {{QStringLiteral("commentId"), id}});
  });
  step(QStringLiteral("the block %1 has the open comment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QJsonObject block = blockSaying(world, c[0]);
    lookAtPage(world, text(block, QLatin1String("pageId")));
    expectShown(world, [&] {
      const QList<QVariantMap>& rows = viewOf(world)->comments()->rows();
      return std::any_of(rows.cbegin(), rows.cend(), [&](const QVariantMap& comment) {
        return comment.value(QStringLiteral("body")) == c[1] && comment.value(QStringLiteral("blockId")) == text(block, QLatin1String("id")) &&
               comment.value(QStringLiteral("blockText")) == c[0] && !comment.value(QStringLiteral("resolved")).toBool();
      });
    }, QStringLiteral("the open comment %1 on %2").arg(c[1], c[0]));
    const auto row = rowOf(viewOf(world)->blocks(), text(block, QLatin1String("id")));
    expect(row && row->value(QStringLiteral("openComments")).toInt() == 1, QStringLiteral("the block does not count its open comment: %1").arg(describe(world)));
  });
  step(QStringLiteral("the comment %1 is resolved").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString id = idOfComment(world, c[0]);
    lookAtPage(world, text(one(world.mc, streamOf(current(world)), QStringLiteral("comment"), id), QLatin1String("pageId")));
    expectShown(world, [&] {
      const auto row = rowOf(viewOf(world)->comments(), id);
      return row && row->value(QStringLiteral("resolved")).toBool();
    }, QStringLiteral("the comment %1 to be resolved").arg(c[0]));
  });

  // Markdown.
  step(QStringLiteral("the page %1 with the blocks:").arg(q), [](World& world, const Captures& c, const Table& table) {
    for (const QStringList& row : table.mid(1)) givenBlock(world, c[0], row.value(0), row.value(1), row.value(2) == QLatin1String("yes"));
  });
  step(QStringLiteral("the user exports %1 as Markdown").arg(q), [](World& world, const Captures& c, const Table&) {
    world.clipboard.clear();
    actOnPage(world, idOfPage(world, c[0]), QStringLiteral("space.page.copyMarkdown"), {});
  });
  step(QStringLiteral("the Markdown is:"), [](World& world, const Captures&, const Table& doc) {
    const QString wanted = doc.value(0).value(0) + QLatin1Char('\n');
    world.waitFor([&] { return world.clipboard == wanted; }, [&] { return QStringLiteral("the clipboard to hold the page; it holds \"%1\"").arg(world.clipboard); });
    expect(toldOf(world, QStringLiteral("Page copied as Markdown")), QStringLiteral("the user is not told: %1").arg(show(toasts(world))));
  });
  step(QStringLiteral("the user imports this Markdown into %1:").arg(q), [](World& world, const Captures& c, const Table& doc) {
    look(world, idOfSpace(world, c[0]));
    act(world, QStringLiteral("space.page.importMarkdown"), {{QStringLiteral("markdown"), doc.value(0).value(0)}});
  });
  step(QStringLiteral("the page %1 has the blocks:").arg(q), [](World& world, const Captures& c, const Table& table) {
    const QString page = idOfPage(world, c[0]);
    look(world, current(world));
    // The page imported is the one the user is shown.
    expectShown(world, [&] { return viewOf(world)->pageId() == page; }, QStringLiteral("%1 to open").arg(c[0]));
    const Table wanted = table.mid(1);
    expectShown(world, [&] { return blockTable(world) == wanted; }, QStringLiteral("the blocks %1").arg(show(tableOf(wanted))));
  });

  // A page from a thread.
  step(QStringLiteral("the thread %1 talked about a release plan").arg(q), [](World& world, const Captures& c, const Table&) {
    fake(world.mc).talked.insert(threadNamed(world, c[0]));
  });
  step(QStringLiteral("text generation is available"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).generation = QStringLiteral("available");
  });
  step(QStringLiteral("no text generation provider is available"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).generation = QStringLiteral("unavailable");
  });
  step(QStringLiteral("text generation fails"), [](World& world, const Captures&, const Table&) {
    fake(world.mc).generation = QStringLiteral("failed");
  });
  step(QStringLiteral("the user makes a page in %1 from the thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The Space the page goes in is the one the user last had open.
    look(world, idOfSpace(world, c[0]));
    const QString key = world.mc.environmentId + QLatin1Char(':') + threadNamed(world, c[1]);
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
    world.sync();
    // From the thread's menu.
    world.bridge().dispatch(QStringLiteral("thread.menu"), QVariantMap{{QStringLiteral("key"), key}, {QStringLiteral("x"), 40}, {QStringLiteral("y"), 120}});
    const QVariant menu = world.state(QStringLiteral("menu"));
    expect(menu.typeId() == QMetaType::QVariantMap, QStringLiteral("no thread menu opened"));
    world.bridge().dispatch(QStringLiteral("menu.select"),
                            QVariantMap{{QStringLiteral("requestId"), at(menu, QStringLiteral("requestId"))}, {QStringLiteral("id"), QStringLiteral("page-from-thread")}});
    world.sync();
  });
  step(QStringLiteral("the new page holds the generated summary"), [](World& world, const Captures&, const Table&) {
    expectShown(world, [&] {
      return world.native().controller<NavigationController>()->route().kind == QLatin1String("space") && viewOf(world)->spaceId() == current(world) &&
             viewOf(world)->page().value(QStringLiteral("title")) == kSummaryTitle && blockTexts(world) == QStringList{kSummary};
    }, QStringLiteral("the summary to open as a page"));
    const QVariantMap block = viewOf(world)->blocks()->get(0);
    expect(block.value(QStringLiteral("byAgent")).toBool(), QStringLiteral("the summary is not shown as the agent's: %1").arg(show(block)));
  });
  step(QStringLiteral("the new page remembers it came from %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap page = viewOf(world)->page();
    expect(page.value(QStringLiteral("sourceThreadId")) == threadNamed(world, c[0]) && page.value(QStringLiteral("sourceThreadTitle")) == c[0],
           QStringLiteral("the page shows %1").arg(show(page)));
  });
  step(QStringLiteral("the summary was written in the project's folder"), [](World& world, const Captures&, const Table&) {
    // The client names the thread; the MC finds its folder.
    const FakeSpaces& spaces = fake(world.mc);
    const QJsonObject thread = world.mc.threads.value(spaces.summarised);
    const QString folder = world.mc.projects.value(thread.value(QLatin1String("projectId")).toString()).value(QLatin1String("workspaceRoot")).toString();
    expect(!spaces.summarised.isEmpty() && !folder.isEmpty() && spaces.cwd == folder,
           QStringLiteral("the summary of %1 was written in \"%2\", not \"%3\"").arg(spaces.summarised, spaces.cwd, folder));
  });
  step(QStringLiteral("the user is told text generation (is unavailable|failed)"), [](World& world, const Captures& c, const Table&) {
    const QString start = c[0] == QLatin1String("failed") ? QStringLiteral("Text generation failed, so no page was written: The provider stopped answering.")
                                                          : QStringLiteral("Text generation is unavailable, so no page was written.");
    world.waitFor([&] { return toldOf(world, start); }, [&] { return QStringLiteral("the user to be told \"%1\"; toasts %2").arg(start, show(toasts(world))); });
    expect(!world.state(QStringLiteral("space")).toMap().value(QStringLiteral("busy")).toBool(), QStringLiteral("the Space view still says it is writing"));
  });
});

}  // namespace
