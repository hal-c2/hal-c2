#include "CommandPaletteController.h"

#include <QJsonArray>
#include <QJsonObject>

#include <algorithm>
#include <limits>

#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarModel.h"

namespace {

const NativeControllerRegistrar<CommandPaletteController> registrar(QStringLiteral("palette"), {}, "PaletteModel");

enum Group { Actions, RecentThreads, Projects, Settings, Threads };

QString groupLabel(int group) {
  switch (group) {
    case Actions:
      return CommandPaletteController::tr("Actions");
    case RecentThreads:
      return CommandPaletteController::tr("Recent Threads");
    case Projects:
      return CommandPaletteController::tr("Projects");
    case Settings:
      return CommandPaletteController::tr("Settings");
    default:
      return CommandPaletteController::tr("Threads");
  }
}

// The web's normalizeSearchText: compatibility-decomposed, marks dropped,
// lower case, whitespace collapsed.
QString normalize(const QString& text) {
  const QString decomposed = text.normalized(QString::NormalizationForm_KD);
  QString out;
  out.reserve(decomposed.size());
  for (const QChar c : decomposed) {
    if (!c.isMark()) out.append(c.toLower());
  }
  return out.simplified();
}

bool hasAll(const QString& field, const QStringList& tokens) {
  return std::all_of(tokens.cbegin(), tokens.cend(), [&field](const QString& token) { return field.contains(token); });
}

// rankCommandPaletteItemMatch: the first field every token is in decides, by
// its place and how well the whole query matches it (exact, prefix, then
// substring); recency breaks ties.
int rank(const QStringList& terms, const QString& query, const QStringList& tokens) {
  int index = 0;
  for (const QString& field : terms) {
    if (field.isEmpty()) continue;
    if (hasAll(field, tokens)) {
      const int fieldRank = field == query ? 3 : field.startsWith(query) ? 2 : field.contains(query) ? 1 : 0;
      return 1000 - index * 100 + fieldRank;
    }
    ++index;
  }
  return 0;
}

QStringList pullRequestTerms(const QJsonObject& row) {
  QStringList terms;
  for (const QJsonValue& value : row.value(QLatin1String("pullRequests")).toArray()) {
    const QJsonObject link = value.toObject();
    if (link.value(QLatin1String("source")).toString() == QLatin1String("stack-dismissed")) continue;
    const QString number = QLatin1Char('#') + QString::number(link.value(QLatin1String("number")).toInteger());
    terms << number << link.value(QLatin1String("repository")).toString() + number
          << link.value(QLatin1String("url")).toString()
          << link.value(QLatin1String("snapshot")).toObject().value(QLatin1String("title")).toString();
  }
  return terms;
}

}  // namespace

CommandPaletteController::CommandPaletteController(ShellBridge* bridge, NodeClient*, ShellStore* store, QObject* parent)
    : QAbstractListModel(parent), m_bridge(bridge), m_store(store) {
  connect(store, &ShellStore::changed, this, &CommandPaletteController::rebuild);
}

void CommandPaletteController::activate() {
  if (m_active) return;
  m_active = true;
  auto* shell = NativeShell::of(this);
  auto* commands = shell->controller<KeybindingController>()->commands();
  commands->add(kToggle, keybindings::commandLabel(kToggle), [this] { toggle(); });
  for (const auto signal : {&QAbstractItemModel::rowsInserted, &QAbstractItemModel::rowsRemoved}) {
    connect(commands, signal, this, &CommandPaletteController::rebuild);
  }
  connect(commands, &QAbstractItemModel::dataChanged, this, &CommandPaletteController::rebuild);
  // The current thread's mark.
  connect(shell->controller<NavigationController>(), &NavigationController::changed, this,
          &CommandPaletteController::rebuild);
}

int CommandPaletteController::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : count();
}

QVariant CommandPaletteController::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() >= m_rows.size()) return {};
  const Row& row = m_rows.at(index.row());
  const Entry& entry = m_entries.at(row.entry);
  switch (role) {
    case TitleRole:
      return entry.title;
    case DescriptionRole:
      return entry.description;
    case GroupRole:
      return groupLabel(row.group);
    case ShortcutRole:
      return entry.shortcut;
    case KindRole:
      return kindAt(index.row());
    default:
      return {};
  }
}

QHash<int, QByteArray> CommandPaletteController::roleNames() const {
  return {{TitleRole, "title"},
          {DescriptionRole, "description"},
          {GroupRole, "group"},
          {ShortcutRole, "shortcut"},
          {KindRole, "kind"}};
}

QString CommandPaletteController::emptyText() const {
  if (!m_rows.isEmpty()) return {};
  return m_query.startsWith(QLatin1Char('>')) ? tr("No matching actions.")
                                              : tr("No matching commands, projects, or threads.");
}

QString CommandPaletteController::kindAt(int row) const {
  if (row < 0 || row >= m_rows.size()) return {};
  switch (m_entries.at(m_rows.at(row).entry).kind) {
    case Kind::Action:
      return QStringLiteral("action");
    case Kind::Thread:
      return QStringLiteral("thread");
    case Kind::Project:
      return QStringLiteral("project");
    case Kind::Setting:
      return QStringLiteral("setting");
  }
  return {};
}

QString CommandPaletteController::idAt(int row) const {
  return row >= 0 && row < m_rows.size() ? m_entries.at(m_rows.at(row).entry).id : QString();
}

void CommandPaletteController::show() {
  if (!m_active) return;
  const bool wasOpen = m_open;
  m_open = true;
  if (!m_query.isEmpty()) {
    m_query.clear();
    emit queryChanged();
  }
  rebuild();
  setHighlighted(0);
  if (!wasOpen) emit openChanged();
}

void CommandPaletteController::toggle() {
  if (m_open) {
    dismiss();
  } else {
    show();
  }
}

void CommandPaletteController::dismiss() {
  close(true);
}

void CommandPaletteController::close(bool returnFocus) {
  if (!m_open) return;
  m_open = false;
  emit openChanged();
  if (returnFocus) m_bridge->sendToPage(QStringLiteral("composer.focus"));
}

void CommandPaletteController::setQuery(const QString& query) {
  if (query == m_query) return;
  m_query = query;
  emit queryChanged();
  if (!m_open) return;
  refilter(false);
  setHighlighted(0);
}

void CommandPaletteController::setHighlighted(int row) {
  const int clamped = m_rows.isEmpty() ? 0 : std::clamp(row, 0, count() - 1);
  if (clamped == m_highlighted) return;
  m_highlighted = clamped;
  emit highlightedChanged();
}

void CommandPaletteController::move(int delta) {
  if (m_rows.isEmpty()) return;
  setHighlighted(((m_highlighted + delta) % count() + count()) % count());
}

bool CommandPaletteController::run(int row) {
  if (!m_open || row < 0 || row >= m_rows.size()) return false;
  const Entry entry = m_entries.at(m_rows.at(row).entry);
  // Closed first: what the entry opens takes the keyboard.
  close(false);
  return openEntry(entry);
}

bool CommandPaletteController::openEntry(const Entry& entry) {
  auto* shell = NativeShell::of(this);
  auto* navigation = shell->controller<NavigationController>();
  using Route = NavigationController::Route;
  switch (entry.kind) {
    case Kind::Action:
      return shell->controller<KeybindingController>()->commands()->run(entry.id);
    case Kind::Thread:
      if (!m_store->thread(entry.id)) return false;
      if (navigation->threadKey() != entry.id) navigation->open(Route::thread(entry.id));
      return true;
    case Kind::Project: {
      // Its latest thread, or a new one in it.
      const sidebar::ProjectGroup* group = shell->sidebar()->group(entry.id);
      if (!group) return false;
      const QSet<QString> members(group->memberKeys.cbegin(), group->memberKeys.cend());
      const Entry* latest = nullptr;
      for (const Entry& candidate : std::as_const(m_entries)) {
        if (candidate.kind != Kind::Thread) continue;
        const auto thread = m_store->thread(candidate.id);
        if (!thread || !members.contains(thread->environmentId + QLatin1Char(':') + thread->projectId)) continue;
        if (!latest || candidate.recency > latest->recency) latest = &candidate;
      }
      navigation->open(latest ? Route::thread(latest->id) : Route::newThread(entry.id));
      return true;
    }
    case Kind::Setting:
      navigation->open(Route::settings(entry.id));
      return true;
  }
  return false;
}

void CommandPaletteController::setSettingsSections(const QVariantList& sections) {
  m_settingsSections = sections;
  rebuild();
}

void CommandPaletteController::rebuild() {
  if (!m_open) return;
  auto* shell = NativeShell::of(this);
  QList<Entry> entries;

  const CommandRegistry* commands = shell->controller<KeybindingController>()->commands();
  for (int row = 0; row < commands->rowCount(); ++row) {
    const QModelIndex index = commands->index(row);
    const QString command = index.data(CommandRegistry::CommandRole).toString();
    if (command == kToggle || command.startsWith(QLatin1String("thread.jump."))) continue;
    const QString title = index.data(CommandRegistry::TitleRole).toString();
    entries.append({Kind::Action, command, title, {}, index.data(CommandRegistry::ShortcutRole).toString(),
                    {normalize(title), normalize(command)}});
  }

  const QString current = shell->controller<NavigationController>()->threadKey();
  QList<Entry> threads;
  for (const sidebar::Thread& thread : m_store->threads()) {
    if (thread.archivedAt || thread.subagent) continue;
    const QString key = thread.key();
    const auto project = m_store->project(thread.environmentId + QLatin1Char(':') + thread.projectId);
    QStringList description;
    if (project) description << project->title;
    if (thread.branch) description << QLatin1Char('#') + *thread.branch;
    if (key == current) description << tr("Current thread");
    QStringList terms{thread.title};
    terms << pullRequestTerms(m_store->threadRow(key));
    // Last, so a pasted id never outranks a title.
    terms << (project ? project->title : QString()) << thread.branch.value_or(QString()) << thread.id;
    for (QString& term : terms) term = normalize(term);
    const auto active = sidebar::parseIso(thread.latestUserMessageAt ? thread.latestUserMessageAt
                                          : !thread.updatedAt.isEmpty() ? sidebar::Nullable(thread.updatedAt)
                                                                        : sidebar::Nullable(thread.createdAt));
    threads.append({Kind::Thread, key, thread.title, description.join(QStringLiteral(" · ")), {}, terms, {},
                    active.value_or(0)});
  }
  std::stable_sort(threads.begin(), threads.end(),
                   [](const Entry& left, const Entry& right) { return left.recency > right.recency; });
  entries.append(threads);

  for (const sidebar::ProjectGroup& group : shell->sidebar()->groups()) {
    const QString name = group.summary.value(QStringLiteral("displayName")).toString();
    QStringList terms{normalize(name)};
    for (const sidebar::Project& member : group.members) terms << normalize(member.title) << normalize(member.workspaceRoot);
    entries.append({Kind::Project, group.key, name, group.summary.value(QStringLiteral("workspaceRoot")).toString(), {},
                    terms});
  }

  for (const QVariant& value : std::as_const(m_settingsSections)) {
    const QVariantMap section = value.toMap();
    const QString label = section.value(QStringLiteral("label")).toString();
    entries.append({Kind::Setting, section.value(QStringLiteral("to")).toString(), label, tr("Settings"), {},
                    {normalize(label), normalize(section.value(QStringLiteral("keywords")).toString())}});
  }

  for (Entry& entry : entries) entry.haystack = entry.terms.join(QLatin1Char(' ')).simplified();
  m_entries = std::move(entries);
  refilter(true);
}

void CommandPaletteController::refilter(bool refreshed) {
  const bool actionsOnly = m_query.startsWith(QLatin1Char('>'));
  const QString query = normalize(actionsOnly ? m_query.mid(1) : m_query);
  const QStringList tokens = query.split(QLatin1Char(' '), Qt::SkipEmptyParts);

  QList<Row> next;
  const auto add = [this, &next](int group, int entry) {
    next.append({group, entry, QString::number(group) + QLatin1Char('\n') + m_entries.at(entry).id});
  };
  if (query.isEmpty()) {
    int recent = 0;
    for (int index = 0; index < m_entries.size(); ++index) {
      const Kind kind = m_entries.at(index).kind;
      if (kind == Kind::Action) add(Actions, index);
    }
    for (int index = 0; !actionsOnly && index < m_entries.size() && recent < kRecentThreads; ++index) {
      if (m_entries.at(index).kind != Kind::Thread) continue;
      add(RecentThreads, index);
      ++recent;
    }
  } else {
    struct Match {
      int entry;
      int rank;
    };
    const auto groupOf = [](Kind kind) {
      switch (kind) {
        case Kind::Action:
          return Actions;
        case Kind::Project:
          return Projects;
        case Kind::Setting:
          return Settings;
        default:
          return Threads;
      }
    };
    QList<Match> byGroup[Threads + 1];
    for (int index = 0; index < m_entries.size(); ++index) {
      const Entry& entry = m_entries.at(index);
      if (actionsOnly && entry.kind != Kind::Action) continue;
      if (!hasAll(entry.haystack, tokens)) continue;
      byGroup[groupOf(entry.kind)].append({index, rank(entry.terms, query, tokens)});
    }
    for (const int group : {Actions, Projects, Settings, Threads}) {
      QList<Match>& matches = byGroup[group];
      std::stable_sort(matches.begin(), matches.end(), [this](const Match& left, const Match& right) {
        if (left.rank != right.rank) return left.rank > right.rank;
        return m_entries.at(left.entry).recency > m_entries.at(right.entry).recency;
      });
      for (const Match& match : std::as_const(matches)) add(group, match.entry);
    }
  }

  // A background update keeps the highlight on its entry.
  const QString highlightedKey = m_highlighted < count() ? m_rows.at(m_highlighted).key : QString();
  // Only the rows between the unchanged head and tail move.
  const int before = count();
  const int after = static_cast<int>(next.size());
  int head = 0;
  while (head < before && head < after && m_rows.at(head).key == next.at(head).key) ++head;
  int tail = 0;
  while (tail < before - head && tail < after - head &&
         m_rows.at(before - 1 - tail).key == next.at(after - 1 - tail).key) {
    ++tail;
  }
  if (before - tail > head) {
    beginRemoveRows({}, head, before - tail - 1);
    m_rows.remove(head, before - tail - head);
    endRemoveRows();
  }
  if (after - tail > head) {
    beginInsertRows({}, head, after - tail - 1);
    m_rows.insert(head, after - tail - head, Row{});
    for (int row = head; row < after - tail; ++row) m_rows[row] = next.at(row);
    endInsertRows();
  }
  m_rows = std::move(next);
  if (refreshed && !m_rows.isEmpty()) emit dataChanged(index(0), index(count() - 1));
  emit resultsChanged();
  if (refreshed) {
    const auto found = std::find_if(m_rows.cbegin(), m_rows.cend(), [&](const Row& row) { return row.key == highlightedKey; });
    setHighlighted(found != m_rows.cend() ? static_cast<int>(found - m_rows.cbegin()) : m_highlighted);
  }
}
