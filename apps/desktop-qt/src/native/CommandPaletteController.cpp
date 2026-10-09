#include "CommandPaletteController.h"

#include <QFileInfo>
#include <QJsonArray>
#include <QJsonObject>
#include <QMap>
#include <QQmlPropertyMap>
#include <QRegularExpression>

#include <algorithm>
#include <limits>
#include <tuple>

#include "DraftController.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "RightPanelController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "SidebarModel.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<CommandPaletteController> registrar(QStringLiteral("palette"), {}, "PaletteModel");

QString actionsLabel() {
  return CommandPaletteController::tr("Actions");
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

// searchSettings' own rank, which orders settings the generic rank ties:
// the title matched exactly, by prefix, containing the query, every token in
// it, the phrase anywhere, then the rest.
int settingsRank(const QStringList& terms, const QString& query, const QStringList& tokens) {
  const QString title = terms.value(0);
  if (title == query) return 5;
  if (title.startsWith(query)) return 4;
  if (title.contains(query)) return 3;
  if (hasAll(title, tokens)) return 2;
  return std::any_of(terms.cbegin(), terms.cend(), [&query](const QString& field) { return field.contains(query); })
             ? 1
             : 0;
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

QString directoryOf(const QString& path) {
  const qsizetype slash = path.lastIndexOf(QLatin1Char('/'));
  return slash < 0 ? QString() : path.left(slash);
}

QString nameOf(const QString& path) {
  return path.mid(path.lastIndexOf(QLatin1Char('/')) + 1);
}

}  // namespace

const QStringList CommandPaletteController::kRootCommands{
    QStringLiteral("chat.new"),
    QStringLiteral("thread.newIn"),
    QStringLiteral("thread.copyReference"),
    QStringLiteral("thread.linkPullRequest"),
    QStringLiteral("thread.showPullRequests"),
    kFiles,
    kContent,
    QStringLiteral("project.add"),
    QStringLiteral("theme.select"),
    QStringLiteral("appearance.select"),
    QStringLiteral("themeEditor.toggle"),
    QStringLiteral("pullRequests.open"),
    QStringLiteral("usage.open"),
    QStringLiteral("settings.open"),
    QStringLiteral("projectSettings.open"),
};

CommandPaletteController::CommandPaletteController(ShellBridge* bridge, McClient* client, ShellStore* store,
                                                   QObject* parent)
    : QAbstractListModel(parent), m_bridge(bridge), m_client(client), m_store(store) {
  m_debounce.setSingleShot(true);
  m_debounce.setInterval(kSearchDelayMs);
  connect(&m_debounce, &QTimer::timeout, this, &CommandPaletteController::search);
  connect(store, &ShellStore::changed, this, [this] {
    followTarget();
    rebuild();
  });
  // What Enter does follows the query, the answer for it and the highlight.
  connect(this, &CommandPaletteController::queryChanged, this, &CommandPaletteController::submitChanged);
  connect(this, &CommandPaletteController::highlightedChanged, this, &CommandPaletteController::submitChanged);
  connect(this, &CommandPaletteController::resultsChanged, this, &CommandPaletteController::submitChanged);
  connect(this, &CommandPaletteController::modeChanged, this, &CommandPaletteController::submitChanged);
}

void CommandPaletteController::activate() {
  if (m_active) return;
  m_active = true;
  auto* shell = NativeShell::of(this);
  auto* commands = shell->controller<KeybindingController>()->commands();
  commands->add(kToggle, keybindings::commandLabel(kToggle), [this] { toggle(); });
  commands->add(kFiles, tr("Go to file"), [this] { toggleMode(QStringLiteral("files")); });
  commands->add(kContent, tr("Search project contents"), [this] { toggleMode(QStringLiteral("content")); });
  commands->setTerms(kFiles, {QStringLiteral("go to file"), QStringLiteral("open file"), QStringLiteral("file picker"),
                              QStringLiteral("find file"), QStringLiteral("quick open")});
  commands->setTerms(kContent, {QStringLiteral("search project"), QStringLiteral("find in files"), QStringLiteral("grep"),
                                QStringLiteral("content search"), QStringLiteral("text search")});
  for (const auto signal : {&QAbstractItemModel::rowsInserted, &QAbstractItemModel::rowsRemoved}) {
    connect(commands, signal, this, &CommandPaletteController::rebuild);
  }
  connect(commands, &QAbstractItemModel::dataChanged, this, &CommandPaletteController::rebuild);
  connect(shell->controller<KeybindingController>(), &KeybindingController::bindingsChanged, this,
          &CommandPaletteController::rebuild);
  connect(commands, &CommandRegistry::menuRequested, this, &CommandPaletteController::showMenu);
  connect(commands, &CommandRegistry::failed, this, [this](const QString& command, const QString& message) {
    if (command != m_running) return;
    NativeShell::of(this)->controller<ToastController>()->error(
        tr("Unable to run command"), message.isEmpty() ? tr("An unexpected error occurred.") : message);
  });
  // The current thread's mark, and where files are searched.
  connect(shell->controller<NavigationController>(), &NavigationController::changed, this, [this] {
    followTarget();
    rebuild();
  });
  // The requires of settings sections.
  connect(m_bridge, &ShellBridge::stateEntryChanged, this, [this](const QString& key) {
    for (const QVariant& value : std::as_const(m_settingsSections)) {
      if (value.toMap().value(QStringLiteral("requires")).toString() == key) {
        rebuild();
        return;
      }
    }
  });
  m_target = target();
}

// --- The model -----------------------------------------------------------------------

int CommandPaletteController::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : count();
}

QVariant CommandPaletteController::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() >= m_rows.size()) return {};
  const Row& row = m_rows.at(index.row());
  const Entry& entry = row.item;
  switch (role) {
    case TitleRole:
      return entry.title;
    case DescriptionRole:
      return row.description.isEmpty() ? entry.description : row.description;
    case GroupRole:
      return row.group;
    case ShortcutRole:
      return entry.shortcut;
    case KindRole:
      return kindAt(index.row());
    case EnabledRole:
      return entry.enabled;
    case CurrentRole:
      return entry.current;
    default:
      return {};
  }
}

QHash<int, QByteArray> CommandPaletteController::roleNames() const {
  return {{TitleRole, "title"},   {DescriptionRole, "description"}, {GroupRole, "group"},
          {ShortcutRole, "shortcut"}, {KindRole, "kind"},           {EnabledRole, "runnable"},
          {CurrentRole, "current"}};
}

QString CommandPaletteController::mode() const {
  switch (m_mode) {
    case Mode::Files:
      return QStringLiteral("files");
    case Mode::Content:
      return QStringLiteral("content");
    case Mode::Browse:
      return QStringLiteral("browse");
    case Mode::Ask:
      return QStringLiteral("ask");
    default:
      return QStringLiteral("command");
  }
}

QString CommandPaletteController::submenu() const {
  if (m_mode == Mode::Ask) return m_askTitle;
  return m_views.isEmpty() ? QString() : m_views.constLast().title;
}

QString CommandPaletteController::placeholder() const {
  switch (m_mode) {
    case Mode::Files:
      return tr("Search files…");
    case Mode::Content: {
      const auto thread = m_store->thread(NativeShell::of(this)->controller<NavigationController>()->threadKey());
      const auto project = thread ? m_store->project(thread->environmentId + QLatin1Char(':') + thread->projectId)
                                  : std::nullopt;
      return project ? tr("Search in %1").arg(project->title) : tr("Search in project");
    }
    case Mode::Browse:
      return tr("Enter project path (e.g. ~/projects/my-app)");
    case Mode::Ask:
      return m_askPlaceholder;
    default:
      return m_views.isEmpty() ? tr("Search commands, projects, and threads...") : tr("Search...");
  }
}

QString CommandPaletteController::emptyText() const {
  if (!m_rows.isEmpty()) return {};
  const bool hasQuery = !m_query.trimmed().isEmpty();
  switch (m_mode) {
    case Mode::Files:
      if (m_target.environmentId.isEmpty() || !m_store->environmentOnline(m_target.environmentId)) {
        return tr("Open a project to search its files.");
      }
      if (searching()) return tr("Searching workspace files…");
      return hasQuery ? tr("No matching files.") : tr("No files found.");
    case Mode::Content:
      if (m_target.environmentId.isEmpty() || !m_store->environmentOnline(m_target.environmentId)) {
        return tr("Open a project to search its files.");
      }
      return hasQuery && !searching() && m_error.isEmpty() ? tr("No results found.")
                                                           : tr("Type to search across your project.");
    case Mode::Browse:
      if (relativeWithoutProject()) return tr("Relative paths require an active project.");
      if (!m_error.isEmpty()) return m_error;
      if (!m_browseOptions.emptyText.isEmpty()) return m_browseOptions.emptyText;
      return hasQuery && !searching() ? tr("Press Enter to create this folder and add it as a project.") : QString();
    case Mode::Ask:
      return m_askEmpty;
    default:
      if (searching()) return tr("Searching thread messages…");
      return m_query.startsWith(QLatin1Char('>')) ? tr("No matching actions.")
                                                  : tr("No matching commands, projects, or threads.");
  }
}

QString CommandPaletteController::status() const {
  // A thread search only reaches the environments that are online: the others are named.
  if (m_mode == Mode::Command && m_views.isEmpty() && !m_query.startsWith(QLatin1Char('>')) && normalize(m_query).size() >= 2) {
    QMap<QString, QString> skipped;
    for (const QString& id : m_store->environments()) {
      if (m_store->environmentOnline(id)) continue;
      const QString label = m_store->environment(id).value(QLatin1String("label")).toString();
      skipped.insert(id, label.isEmpty() ? id : label);
    }
    return skipped.isEmpty() ? QString() : tr("Not searched (offline): %1").arg(QStringList(skipped.values()).join(QStringLiteral(", ")));
  }
  if (m_mode != Mode::Content || m_query.trimmed().isEmpty()) return {};
  if (searching()) return tr("Searching…");
  if (!m_error.isEmpty()) return m_error;
  if (m_invalidRegex) return tr("Invalid regular expression");
  QSet<QString> files;
  for (const Entry& entry : m_entries) files.insert(entry.group);
  return tr("%1%2 results in %3 files")
      .arg(m_entries.size())
      .arg(m_truncated ? QStringLiteral("+") : QString())
      .arg(files.size());
}

QString CommandPaletteController::kindAt(int row) const {
  if (row < 0 || row >= m_rows.size()) return {};
  switch (m_rows.at(row).item.kind) {
    case Kind::Action:
      return QStringLiteral("action");
    case Kind::Thread:
      return QStringLiteral("thread");
    case Kind::Project:
      return QStringLiteral("project");
    case Kind::Setting:
      return QStringLiteral("setting");
    case Kind::Choice:
      return QStringLiteral("choice");
    case Kind::File:
      return QStringLiteral("file");
    case Kind::Match:
      return QStringLiteral("match");
    case Kind::Folder:
      return QStringLiteral("folder");
    case Kind::Up:
      return QStringLiteral("up");
  }
  return {};
}

QString CommandPaletteController::idAt(int row) const {
  return row >= 0 && row < m_rows.size() ? m_rows.at(row).item.id : QString();
}

// --- Opening and closing -------------------------------------------------------------

void CommandPaletteController::show() {
  if (!m_active) return;
  open(Mode::Command);
}

void CommandPaletteController::toggle() {
  if (m_open) {
    dismiss();
  } else {
    show();
  }
}

void CommandPaletteController::toggleMode(const QString& name) {
  if (!m_active) return;
  const Mode wanted = name == QLatin1String("files")     ? Mode::Files
                      : name == QLatin1String("content") ? Mode::Content
                                                         : Mode::Command;
  if (m_open && m_mode == wanted) {
    dismiss();
  } else {
    open(wanted);
  }
}

void CommandPaletteController::showMenu(const QString& command) {
  if (!m_active) return;
  const CommandRegistry* commands = NativeShell::of(this)->controller<KeybindingController>()->commands();
  open(Mode::Command);
  QString title;
  for (int row = 0; row < commands->rowCount(); ++row) {
    const QModelIndex at = commands->index(row);
    if (at.data(CommandRegistry::CommandRole).toString() == command) title = at.data(CommandRegistry::TitleRole).toString();
  }
  pushView(title, [commands, command] { return commands->choices(command); });
}

void CommandPaletteController::browse(const QString& environmentId, std::function<void(const QString&)> add,
                                      const BrowseOptions& options) {
  if (!m_active) return;
  m_browseEnvironment = environmentId;
  m_add = std::move(add);
  m_browseOptions = options;
  open(Mode::Browse);
}

void CommandPaletteController::ask(const QString& title, const QString& placeholder, const QString& emptyText,
                                   std::function<void(const QString&)> submit) {
  if (!m_active) return;
  m_askTitle = title;
  m_askPlaceholder = placeholder;
  m_askEmpty = emptyText;
  m_submit = std::move(submit);
  open(Mode::Ask);
}

void CommandPaletteController::refreshMenu() {
  if (!m_open || m_mode != Mode::Command || m_views.isEmpty() || !m_views.constLast().source) return;
  m_views.last().choices = m_views.constLast().source();
  // The highlight stays on its entry (refilter).
  rebuildChoices();
}

void CommandPaletteController::open(Mode mode) {
  const bool wasOpen = m_open;
  m_open = true;
  m_views.clear();
  m_entries.clear();
  m_error.clear();
  m_invalidRegex = false;
  m_truncated = false;
  m_messageMatches.clear();
  m_messageQuery.clear();
  m_browseQuery.clear();
  m_browseParent.clear();
  m_browseEntries = {};
  ++m_generation;
  m_pending = 0;
  m_debounce.stop();
  setMode(mode);
  const QString query = mode == Mode::Browse ? m_browseOptions.query : QString();
  if (m_query != query) {
    m_query = query;
    emit queryChanged();
  }
  m_target = target();
  rebuild();
  // A browsed path is added with Enter unless a folder is highlighted.
  setHighlighted(mode == Mode::Browse ? -1 : 0);
  if (mode != Mode::Command && mode != Mode::Ask) scheduleSearch();
  if (!wasOpen) emit openChanged();
}

void CommandPaletteController::dismiss() {
  close(true);
}

void CommandPaletteController::back() {
  if (!m_open) return;
  if (m_mode != Mode::Command) {
    open(Mode::Command);
  } else if (!m_views.isEmpty()) {
    m_views.clear();
    emit modeChanged();
    if (!m_query.isEmpty()) {
      m_query.clear();
      emit queryChanged();
    }
    rebuild();
    setHighlighted(0);
  } else {
    dismiss();
  }
}

bool CommandPaletteController::leaveSubmenu() {
  if (!m_open || m_views.isEmpty() || !m_query.isEmpty()) return false;
  m_views.removeLast();
  emit modeChanged();
  rebuild();
  setHighlighted(0);
  return true;
}

void CommandPaletteController::close(bool returnFocus) {
  if (!m_open) return;
  m_open = false;
  m_views.clear();
  ++m_generation;
  m_pending = 0;
  m_debounce.stop();
  setMode(Mode::Command);
  emit openChanged();
  if (returnFocus) m_bridge->sendToBricks(QStringLiteral("composer.focus"));
}

void CommandPaletteController::setMode(Mode mode) {
  m_mode = mode;
  emit modeChanged();
}

void CommandPaletteController::pushView(const QString& title, CommandRegistry::Choices source) {
  m_views.append({title, source ? source() : QList<CommandRegistry::Choice>{}, source});
  emit modeChanged();
  if (!m_query.isEmpty()) {
    m_query.clear();
    emit queryChanged();
  }
  rebuild();
  // The one in effect is where the highlight starts.
  const QList<CommandRegistry::Choice>& shown = m_views.constLast().choices;
  const auto current = std::find_if(shown.cbegin(), shown.cend(), [](const auto& choice) { return choice.current; });
  setHighlighted(current != shown.cend() ? static_cast<int>(current - shown.cbegin()) : 0);
}

// --- Typing and choosing -------------------------------------------------------------

void CommandPaletteController::setQuery(const QString& query) {
  if (query == m_query) return;
  m_query = query;
  emit queryChanged();
  if (!m_open) return;
  if (m_mode == Mode::Command) {
    refilter(false);
    // Messages are searched from two characters on, never for actions.
    if (m_views.isEmpty() && !query.startsWith(QLatin1Char('>')) && normalize(query).size() >= 2) {
      scheduleSearch();
    } else if (m_debounce.isActive() || m_pending > 0 || !m_messageQuery.isEmpty()) {
      ++m_generation;
      m_pending = 0;
      m_debounce.stop();
      searchMessages(m_generation);
      emit resultsChanged();
    }
    setHighlighted(0);
  } else if (m_mode != Mode::Ask) {
    scheduleSearch();
    emit resultsChanged();
    if (m_mode == Mode::Browse) setHighlighted(-1);
  }
}

void CommandPaletteController::setCaseSensitive(bool on) {
  if (m_caseSensitive == on) return;
  m_caseSensitive = on;
  emit optionsChanged();
  if (m_open && m_mode == Mode::Content) scheduleSearch();
}

void CommandPaletteController::setWholeWord(bool on) {
  if (m_wholeWord == on) return;
  m_wholeWord = on;
  emit optionsChanged();
  if (m_open && m_mode == Mode::Content) scheduleSearch();
}

void CommandPaletteController::setUseRegex(bool on) {
  if (m_useRegex == on) return;
  m_useRegex = on;
  emit optionsChanged();
  if (m_open && m_mode == Mode::Content) scheduleSearch();
}

void CommandPaletteController::setHighlighted(int row) {
  // Browse mode leaves nothing highlighted until the user moves.
  const int lowest = m_mode == Mode::Browse ? -1 : 0;
  const int clamped = m_rows.isEmpty() ? lowest : std::clamp(row, lowest, count() - 1);
  if (clamped == m_highlighted) return;
  m_highlighted = clamped;
  emit highlightedChanged();
}

void CommandPaletteController::move(int delta) {
  if (m_rows.isEmpty()) return;
  if (m_highlighted < 0) {
    setHighlighted(delta > 0 ? 0 : count() - 1);
    return;
  }
  setHighlighted(((m_highlighted + delta) % count() + count()) % count());
}

bool CommandPaletteController::runHighlighted() {
  if (m_open && m_mode == Mode::Ask) {
    const QString text = m_query.trimmed();
    if (text.isEmpty() || !m_submit) return false;
    // A copy: what it does may ask again.
    const auto submit = m_submit;
    submit(text);
    return true;
  }
  if (m_mode == Mode::Browse && (m_highlighted < 0 || m_highlighted >= count())) {
    // Enter with nothing highlighted adds the path typed.
    if (relativeWithoutProject() || !m_add || browsedPath().isEmpty()) return false;
    const QString path = browsedPath();
    if (m_browseOptions.keepOpen) {
      const auto add = m_add;
      add(path);
      return true;
    }
    const auto add = std::exchange(m_add, nullptr);
    close(false);
    add(path);
    return true;
  }
  return run(m_highlighted);
}

// A path that is not absolute is under the folder of the project the window
// shows; without one there is nowhere for it to be.
bool CommandPaletteController::relativeWithoutProject() const {
  const QString query = m_query.trimmed();
  return m_mode == Mode::Browse && !query.isEmpty() && !query.startsWith(QLatin1Char('/')) &&
         !query.startsWith(QLatin1Char('~')) && target().root.isEmpty();
}

bool CommandPaletteController::folderHighlighted() const {
  return m_mode == Mode::Browse && m_highlighted >= 0 && m_highlighted < count() && m_rows.at(m_highlighted).item.kind == Kind::Folder;
}

// "Create & Add" only when the folder's own answer says it is not there; before
// the answer, or while a folder is highlighted, the plain verb.
QString CommandPaletteController::submitLabel() const {
  if (!m_open || m_mode != Mode::Browse || !m_add || relativeWithoutProject() || browsedPath().isEmpty()) return {};
  const QString verb = m_browseOptions.submit;
  const QString query = m_query.trimmed();
  bool missing = false;
  if (!folderHighlighted() && m_browseQuery == query) {
    if (query.endsWith(QLatin1Char('/'))) {
      missing = !m_error.isEmpty();
    } else {
      const QString leaf = nameOf(query);
      missing = std::none_of(m_browseEntries.cbegin(), m_browseEntries.cend(),
                             [&](const QJsonValue& value) { return value.toObject().value(QLatin1String("name")).toString() == leaf; });
    }
  }
  return missing ? tr("Create & %1").arg(verb) : verb;
}

QString CommandPaletteController::submitShortcut() const {
  if (submitLabel().isEmpty()) return {};
  // The platform's own name for the key: Command on macOS, as CommandPalette.qml reads it.
  return NativeShell::of(this)->controller<KeybindingController>()->keyLabel(folderHighlighted() ? QStringLiteral("mod+enter") : QStringLiteral("enter"));
}

bool CommandPaletteController::addBrowsedFolder() {
  if (!m_open || m_mode != Mode::Browse || !m_add || relativeWithoutProject()) return false;
  // The folder highlighted, else the path typed.
  QString path = browsedPath();
  if (m_highlighted >= 0 && m_highlighted < count()) {
    const Entry& entry = m_rows.at(m_highlighted).item;
    if (entry.kind == Kind::Folder) path = entry.id;
  }
  if (path.isEmpty()) return false;
  if (m_browseOptions.keepOpen) {
    // A copy: it stays for another try until the chooser closes the palette.
    const auto add = m_add;
    add(path);
    return true;
  }
  const auto add = std::exchange(m_add, nullptr);
  close(false);
  add(path);
  return true;
}

bool CommandPaletteController::run(int row) {
  if (!m_open || row < 0 || row >= m_rows.size()) return false;
  const Entry entry = m_rows.at(row).item;
  if (!entry.enabled) return false;
  auto* commands = NativeShell::of(this)->controller<KeybindingController>()->commands();
  // What moves the palette on keeps it open.
  switch (entry.kind) {
    case Kind::Action:
      if (commands->isMenu(entry.id)) {
        pushView(entry.title, [commands, command = entry.id] { return commands->choices(command); });
        return true;
      }
      break;
    case Kind::Choice: {
      const CommandRegistry::Choice choice = m_views.constLast().choices.value(m_rows.at(row).entry);
      if (choice.submenu) {
        pushView(choice.title, choice.submenu);
        return true;
      }
      if (!choice.keepOpen) close(false);
      if (choice.run) choice.run();
      return true;
    }
    case Kind::Folder: {
      const QString chosen = m_query.left(m_query.lastIndexOf(QLatin1Char('/')) + 1) + entry.title;
      // A pinned name follows the folder in, unless the folder is it.
      const QString& pinned = m_browseOptions.pinned;
      setQuery(pinned.isEmpty() ? chosen + QLatin1Char('/')
               : entry.title == pinned ? chosen
                                       : chosen + QLatin1Char('/') + pinned);
      setHighlighted(-1);
      return true;
    }
    case Kind::Up:
      setQuery(entry.id + m_browseOptions.pinned);
      setHighlighted(-1);
      return true;
    default:
      break;
  }
  // Closed first: what the entry opens takes the keyboard.
  close(false);
  return openEntry(entry);
}

bool CommandPaletteController::runCommand(const QString& command) {
  auto* commands = NativeShell::of(this)->controller<KeybindingController>()->commands();
  m_running = command;
  const bool ran = commands->run(command);
  m_running.clear();
  return ran;
}

bool CommandPaletteController::openEntry(const Entry& entry) {
  auto* shell = NativeShell::of(this);
  auto* navigation = shell->controller<NavigationController>();
  using Route = NavigationController::Route;
  switch (entry.kind) {
    case Kind::Action:
      return runCommand(entry.id);
    case Kind::Thread:
      if (!m_store->thread(entry.id)) return false;
      if (navigation->threadKey() != entry.id) navigation->open(Route::thread(entry.id));
      return true;
    case Kind::Project: {
      // Its latest thread, or a new one in it.
      const sidebar::ProjectGroup* group = shell->sidebar()->group(entry.id);
      if (!group) return false;
      const QSet<QString> members(group->memberKeys.cbegin(), group->memberKeys.cend());
      std::optional<sidebar::Thread> latest;
      qint64 latestAt = std::numeric_limits<qint64>::min();
      for (const sidebar::Thread& thread : m_store->threads()) {
        if (thread.archivedAt || thread.subagent) continue;
        if (!members.contains(thread.environmentId + QLatin1Char(':') + thread.projectId)) continue;
        const qint64 at = sidebar::parseIso(thread.latestUserMessageAt ? thread.latestUserMessageAt
                                            : !thread.updatedAt.isEmpty() ? sidebar::Nullable(thread.updatedAt)
                                                                          : sidebar::Nullable(thread.createdAt))
                              .value_or(0);
        if (!latest || at > latestAt) {
          latest = thread;
          latestAt = at;
        }
      }
      if (latest) {
        navigation->open(Route::thread(latest->key()));
      } else {
        shell->controller<DraftController>()->startIn(*group);
      }
      return true;
    }
    case Kind::Setting: {
      // "<section>#<setting>" opens the section at that setting, and
      // "<section>?<command>" a command's keybindings.
      const qsizetype mark = entry.id.indexOf(QRegularExpression(QStringLiteral("[#?]")));
      if (mark >= 0 && entry.id.at(mark) == QLatin1Char('#')) {
        m_bridge->dispatch(QStringLiteral("settings.openResult"),
                           QVariantMap{{QStringLiteral("to"), entry.id.left(mark)},
                                       {QStringLiteral("targetId"), entry.id.mid(mark + 1)}});
      } else {
        navigation->open(Route::settings(mark < 0 ? entry.id : entry.id.left(mark)));
      }
      return true;
    }
    case Kind::File:
      shell->controller<RightPanelController>()->open(QStringLiteral("files"), {{QStringLiteral("path"), entry.id}});
      return true;
    case Kind::Match: {
      const qsizetype colon = entry.id.lastIndexOf(QLatin1Char(':'));
      shell->controller<RightPanelController>()->open(
          QStringLiteral("files"),
          {{QStringLiteral("path"), entry.id.left(colon)}, {QStringLiteral("line"), entry.id.mid(colon + 1).toInt()}});
      return true;
    }
    default:
      return false;
  }
}

void CommandPaletteController::setSettingsSections(const QVariantList& sections) {
  m_settingsSections = sections;
  rebuild();
}

// --- What it lists -------------------------------------------------------------------

void CommandPaletteController::rebuild() {
  if (!m_open) return;
  if (m_mode != Mode::Command) {
    // Found entries come from the MC (none yet when it just opened); the
    // rows follow them, and the empty text may change.
    refilter(true);
    return;
  }
  if (m_views.isEmpty()) {
    rebuildCommand();
  } else {
    rebuildChoices();
  }
}

void CommandPaletteController::rebuildChoices() {
  QList<Entry> entries;
  for (const CommandRegistry::Choice& choice : std::as_const(m_views.constLast().choices)) {
    QStringList terms{normalize(choice.title), normalize(choice.description)};
    for (const QString& term : choice.terms) terms << normalize(term);
    Entry entry{Kind::Choice, choice.id, choice.title, choice.description, {}, terms};
    entry.enabled = choice.enabled;
    entry.current = choice.current;
    entries.append(entry);
  }
  for (Entry& entry : entries) entry.haystack = entry.terms.join(QLatin1Char(' ')).simplified();
  m_entries = std::move(entries);
  refilter(true);
}

void CommandPaletteController::rebuildCommand() {
  auto* shell = NativeShell::of(this);
  QList<Entry> entries;

  const CommandRegistry* commands = shell->controller<KeybindingController>()->commands();
  for (int row = 0; row < commands->rowCount(); ++row) {
    const QModelIndex index = commands->index(row);
    const QString command = index.data(CommandRegistry::CommandRole).toString();
    if (command == kToggle || command.startsWith(QLatin1String("thread.jump."))) continue;
    if (!index.data(CommandRegistry::ListedRole).toBool()) continue;
    const QString title = index.data(CommandRegistry::TitleRole).toString();
    QStringList terms{normalize(title), normalize(command)};
    for (const QString& term : commands->terms(command)) terms << normalize(term);
    Entry entry{Kind::Action, command, title, index.data(CommandRegistry::DescriptionRole).toString(),
                index.data(CommandRegistry::ShortcutRole).toString(), terms};
    entry.enabled = index.data(CommandRegistry::EnabledRole).toBool();
    entries.append(entry);
  }

  const QString current = shell->controller<NavigationController>()->threadKey();
  QList<Entry> threads;
  for (const sidebar::Thread& thread : m_store->threads()) {
    if (thread.subagent) continue;
    const QString key = thread.key();
    QStringList pullRequests = pullRequestTerms(m_store->threadRow(key));
    for (QString& term : pullRequests) term = normalize(term);
    // An archived thread is only found by a pull request linked to it.
    if (thread.archivedAt && pullRequests.isEmpty()) continue;
    const auto project = m_store->project(thread.environmentId + QLatin1Char(':') + thread.projectId);
    QStringList description;
    if (project) description << project->title;
    if (thread.branch) description << QLatin1Char('#') + *thread.branch;
    if (key == current) description << tr("Current thread");
    QStringList terms;
    if (thread.archivedAt) {
      terms = pullRequests;
    } else {
      terms << normalize(thread.title);
      terms << pullRequests;
      // Last, so a pasted id never outranks a title.
      terms << normalize(project ? project->title : QString()) << normalize(thread.branch.value_or(QString())) << normalize(thread.id);
    }
    const auto active = sidebar::parseIso(thread.latestUserMessageAt ? thread.latestUserMessageAt
                                          : !thread.updatedAt.isEmpty() ? sidebar::Nullable(thread.updatedAt)
                                                                        : sidebar::Nullable(thread.createdAt));
    Entry entry{Kind::Thread, key, thread.title, description.join(QStringLiteral(" · ")), {}, terms};
    entry.recency = active.value_or(0);
    entry.pullRequests = pullRequests.join(QLatin1Char(' ')).simplified();
    entry.archived = thread.archivedAt.has_value();
    threads.append(entry);
  }
  std::stable_sort(threads.begin(), threads.end(),
                   [](const Entry& left, const Entry& right) { return left.recency > right.recency; });
  entries.append(threads);

  for (const sidebar::ProjectGroup& group : shell->sidebar()->groups()) {
    const QString name = group.summary.value(QStringLiteral("displayName")).toString();
    QStringList terms{normalize(name)};
    for (const sidebar::Project& member : group.members) terms << normalize(member.title) << normalize(member.workspaceRoot);
    entries.append(
        {Kind::Project, group.key, name, group.summary.value(QStringLiteral("workspaceRoot")).toString(), {}, terms});
  }

  const QQmlPropertyMap* state = m_bridge->state();
  for (const QVariant& value : std::as_const(m_settingsSections)) {
    const QVariantMap section = value.toMap();
    // A section that needs shell state is listed once it is there
    // (settingsPages.js navRows).
    const QString needs = section.value(QStringLiteral("requires")).toString();
    if (!needs.isEmpty()) {
      const QVariant needed = state->value(needs);
      if (!needed.isValid() || needed.isNull()) continue;
    }
    const QString label = section.value(QStringLiteral("label")).toString();
    // A setting on the section's page is found by its own title, and opens there.
    const QString target = section.value(QStringLiteral("targetId")).toString();
    const QString to = section.value(QStringLiteral("to")).toString();
    entries.append({Kind::Setting, target.isEmpty() ? to : to + QLatin1Char('#') + target, label,
                    target.isEmpty() ? tr("Settings") : section.value(QStringLiteral("detail")).toString(), {},
                    {normalize(label), normalize(section.value(QStringLiteral("keywords")).toString())}});
  }
  // Each keybinding command, after the settings it mirrors (the web's
  // secondary settings results): found by its label, id and keys.
  QHash<QString, qsizetype> shortcuts;
  for (const QVariant& value : shell->controller<KeybindingController>()->bindings()) {
    const QVariantMap binding = value.toMap();
    const QString command = binding.value(QStringLiteral("command")).toString();
    if (!shortcuts.contains(command)) {
      const QString label = binding.value(QStringLiteral("label")).toString();
      shortcuts.insert(command, entries.size());
      Entry entry{Kind::Setting, NavigationController::kKeybindingsSection + QLatin1Char('?') + command, label,
                  tr("Keybindings"), {}, {normalize(label), normalize(command)}};
      entry.secondary = true;
      entries.append(entry);
    }
    entries[shortcuts.value(command)].terms << normalize(binding.value(QStringLiteral("key")).toString());
  }

  for (Entry& entry : entries) entry.haystack = entry.terms.join(QLatin1Char(' ')).simplified();
  m_entries = std::move(entries);
  refilter(true);
}

void CommandPaletteController::refilter(bool refreshed) {
  QList<Row> next;
  const auto add = [this, &next](const QString& group, int entry, const QString& description = {}) {
    next.append({group, entry, group + QLatin1Char('\n') + m_entries.at(entry).id, description, m_entries.at(entry)});
  };

  if (m_mode != Mode::Command) {
    // The MC filtered them already.
    for (int index = 0; index < m_entries.size(); ++index) add(m_entries.at(index).group, index);
    apply(std::move(next), refreshed);
    return;
  }

  const bool actionsOnly = m_views.isEmpty() && m_query.startsWith(QLatin1Char('>'));
  const QString query = normalize(actionsOnly ? m_query.mid(1) : m_query);
  const QStringList tokens = query.split(QLatin1Char(' '), Qt::SkipEmptyParts);

  if (!m_views.isEmpty()) {
    struct Match {
      int entry;
      int rank;
    };
    QList<Match> matches;
    for (int index = 0; index < m_entries.size(); ++index) {
      const Entry& entry = m_entries.at(index);
      if (!query.isEmpty() && !hasAll(entry.haystack, tokens)) continue;
      matches.append({index, query.isEmpty() ? 0 : rank(entry.terms, query, tokens)});
    }
    std::stable_sort(matches.begin(), matches.end(),
                     [](const Match& left, const Match& right) { return left.rank > right.rank; });
    for (const Match& match : std::as_const(matches)) add(QString(), match.entry);
    apply(std::move(next), refreshed);
    return;
  }

  if (query.isEmpty()) {
    // The web's hand-picked actions, in its order, then recent threads.
    for (const QString& command : kRootCommands) {
      for (int index = 0; index < m_entries.size(); ++index) {
        const Entry& entry = m_entries.at(index);
        if (entry.kind == Kind::Action && entry.id == command) add(actionsLabel(), index);
      }
    }
    int recent = 0;
    for (int index = 0; !actionsOnly && index < m_entries.size() && recent < kRecentThreads; ++index) {
      if (m_entries.at(index).kind != Kind::Thread || m_entries.at(index).archived) continue;
      add(tr("Recent Threads"), index);
      ++recent;
    }
    apply(std::move(next), refreshed);
    return;
  }

  struct Match {
    int entry;
    int rank;
    int tiebreak;
  };
  enum { Actions, Projects, Settings, Threads, Groups };
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
  // Threads found by their messages count only for the query they answer.
  const bool messagesCount = !m_messageQuery.isEmpty() && m_messageQuery == query;
  QList<Match> byGroup[Groups];
  QHash<int, QString> snippets;
  for (int index = 0; index < m_entries.size(); ++index) {
    const Entry& entry = m_entries.at(index);
    if (actionsOnly && entry.kind != Kind::Action) continue;
    const int group = groupOf(entry.kind);
    if (hasAll(entry.haystack, tokens)) {
      const int tiebreak = entry.kind == Kind::Setting ? settingsRank(entry.terms, query, tokens) : 0;
      byGroup[group].append({index, rank(entry.terms, query, tokens), tiebreak});
      // Found by its pull request: say how the thread belongs to it.
      if (entry.kind == Kind::Thread && !entry.pullRequests.isEmpty() && hasAll(entry.pullRequests, tokens)) {
        snippets.insert(index, entry.archived ? tr("Archived thread") : tr("Linked thread"));
      }
    } else if (entry.kind == Kind::Thread && messagesCount && m_messageMatches.contains(entry.id)) {
      byGroup[group].append({index, 0, 0});
      snippets.insert(index, m_messageMatches.value(entry.id));
    }
  }
  const QString labels[Groups] = {actionsLabel(), tr("Projects"), tr("Settings"), tr("Threads")};
  for (const int group : {Actions, Projects, Settings, Threads}) {
    QList<Match>& matches = byGroup[group];
    std::stable_sort(matches.begin(), matches.end(), [this](const Match& left, const Match& right) {
      const bool secondary = m_entries.at(left.entry).secondary;
      if (secondary != m_entries.at(right.entry).secondary) return !secondary;
      if (left.rank != right.rank) return left.rank > right.rank;
      if (left.tiebreak != right.tiebreak) return left.tiebreak > right.tiebreak;
      return m_entries.at(left.entry).recency > m_entries.at(right.entry).recency;
    });
    for (const Match& match : std::as_const(matches)) add(labels[group], match.entry, snippets.value(match.entry));
  }
  apply(std::move(next), refreshed);
}

void CommandPaletteController::apply(QList<Row> next, bool refreshed) {
  // A background update keeps the highlight on its entry.
  const QString highlightedKey =
      m_highlighted >= 0 && m_highlighted < count() ? m_rows.at(m_highlighted).key : QString();
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
  // The rows that stay and now show something else, by their index after.
  const auto shows = [](const Row& row) {
    const Entry& entry = row.item;
    return std::tuple(entry.title, row.description.isEmpty() ? entry.description : row.description, row.group,
                      entry.shortcut, entry.kind, entry.enabled, entry.current);
  };
  int firstChanged = after;
  int lastChanged = -1;
  const auto compare = [&](int row, int was) {
    if (shows(m_rows.at(was)) == shows(next.at(row))) return;
    firstChanged = std::min(firstChanged, row);
    lastChanged = row;
  };
  for (int row = 0; row < head; ++row) compare(row, row);
  for (int row = after - tail; row < after; ++row) compare(row, row - after + before);
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
  if (lastChanged >= 0) emit dataChanged(index(firstChanged), index(lastChanged));
  emit resultsChanged();
  if (refreshed && !highlightedKey.isEmpty()) {
    const auto found =
        std::find_if(m_rows.cbegin(), m_rows.cend(), [&](const Row& row) { return row.key == highlightedKey; });
    setHighlighted(found != m_rows.cend() ? static_cast<int>(found - m_rows.cbegin()) : m_highlighted);
  } else {
    setHighlighted(m_highlighted);
  }
}

// --- Searching the MC --------------------------------------------------------------

CommandPaletteController::Target CommandPaletteController::target() const {
  const QString threadKey = NativeShell::of(this)->controller<NavigationController>()->threadKey();
  if (threadKey.isEmpty()) return {};
  const QString environmentId = threadKey.left(threadKey.indexOf(QLatin1Char(':')));
  const QJsonObject row = m_store->threadRow(threadKey);
  QString root = row.value(QLatin1String("worktreePath")).toString();
  if (root.isEmpty()) {
    root = m_store->projectRow(environmentId, row.value(QLatin1String("projectId")).toString())
               .value(QLatin1String("workspaceRoot"))
               .toString();
  }
  if (root.isEmpty()) return {};
  return {environmentId, root};
}

// Another thread's files are another search: what was found goes.
void CommandPaletteController::followTarget() {
  if (!m_active) return;
  const Target next = target();
  if (next == m_target) return;
  m_target = next;
  if (!m_open || (m_mode != Mode::Files && m_mode != Mode::Content)) return;
  // Another project's search starts afresh.
  if (!m_query.isEmpty()) {
    m_query.clear();
    emit queryChanged();
  }
  m_entries.clear();
  m_error.clear();
  m_truncated = false;
  m_invalidRegex = false;
  refilter(true);
  scheduleSearch();
}

void CommandPaletteController::scheduleSearch() {
  // An answer for an older query no longer counts.
  ++m_generation;
  m_pending = 0;
  m_debounce.start();
}

void CommandPaletteController::search() {
  if (!m_open) return;
  const int generation = m_generation;
  switch (m_mode) {
    case Mode::Files:
      searchFiles(generation);
      break;
    case Mode::Content:
      searchContent(generation);
      break;
    case Mode::Browse:
      searchFolders(generation);
      break;
    default:
      searchMessages(generation);
      break;
  }
  emit resultsChanged();
}

void CommandPaletteController::searchFiles(int generation) {
  if (m_target.environmentId.isEmpty() || !m_store->environmentOnline(m_target.environmentId)) {
    m_entries.clear();
    refilter(true);
    return;
  }
  ++m_pending;
  const QJsonObject payload{{QStringLiteral("cwd"), m_target.root},
                            {QStringLiteral("query"), m_query.trimmed()},
                            {QStringLiteral("limit"), kFileLimit},
                            {QStringLiteral("kind"), QStringLiteral("file")}};
  m_client->call(this, m_target.environmentId, QStringLiteral("projects.searchEntries"), payload,
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation || m_mode != Mode::Files) return;
                   m_pending = 0;
                   QList<Entry> entries;
                   if (!error) {
                     for (const QJsonValue& value : result.toObject().value(QLatin1String("entries")).toArray()) {
                       const QString path = value.toObject().value(QLatin1String("path")).toString();
                       entries.append({Kind::File, path, nameOf(path), directoryOf(path), {}, {}});
                     }
                   }
                   m_error = error.value_or(QString());
                   m_entries = std::move(entries);
                   refilter(true);
                   setHighlighted(0);
                 });
}

void CommandPaletteController::searchContent(int generation) {
  const QString query = m_query;
  if (query.trimmed().isEmpty() || m_target.environmentId.isEmpty() ||
      !m_store->environmentOnline(m_target.environmentId)) {
    m_entries.clear();
    m_error.clear();
    m_truncated = false;
    m_invalidRegex = false;
    refilter(true);
    return;
  }
  ++m_pending;
  const QJsonObject payload{{QStringLiteral("cwd"), m_target.root},
                            {QStringLiteral("query"), query},
                            {QStringLiteral("limit"), kContentLimit},
                            {QStringLiteral("caseSensitive"), m_caseSensitive},
                            {QStringLiteral("wholeWord"), m_wholeWord},
                            {QStringLiteral("useRegex"), m_useRegex}};
  m_client->call(this, m_target.environmentId, QStringLiteral("projects.searchContents"), payload,
                 [this, generation](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation || m_mode != Mode::Content) return;
                   m_pending = 0;
                   const QJsonObject answer = result.toObject();
                   // Grouped by file, in the order the MC found them.
                   QList<QString> order;
                   QHash<QString, QList<Entry>> byFile;
                   for (const QJsonValue& value : answer.value(QLatin1String("matches")).toArray()) {
                     const QJsonObject match = value.toObject();
                     const QString path = match.value(QLatin1String("path")).toString();
                     const int line = match.value(QLatin1String("lineNumber")).toInt();
                     if (!byFile.contains(path)) order.append(path);
                     Entry entry{Kind::Match, path + QLatin1Char(':') + QString::number(line),
                                 match.value(QLatin1String("lineContent")).toString().trimmed(), QString::number(line),
                                 {}, {}};
                     entry.group = path;
                     byFile[path].append(entry);
                   }
                   QList<Entry> entries;
                   for (const QString& path : std::as_const(order)) entries.append(byFile.value(path));
                   m_error = error.value_or(QString());
                   m_truncated = answer.value(QLatin1String("truncated")).toBool();
                   m_invalidRegex = answer.contains(QLatin1String("regexFallbackError"));
                   m_entries = std::move(entries);
                   refilter(true);
                   setHighlighted(0);
                 });
}

void CommandPaletteController::searchMessages(int generation) {
  const QString query = normalize(m_query.startsWith(QLatin1Char('>')) ? QString() : m_query);
  if (query.size() < 2 || !m_views.isEmpty()) {
    if (!m_messageQuery.isEmpty()) {
      m_messageQuery.clear();
      m_messageMatches.clear();
      refilter(true);
    }
    return;
  }
  // Each MC answers for its own threads.
  QStringList online;
  for (const QString& environmentId : m_store->environments()) {
    if (m_store->environmentOnline(environmentId)) online.append(environmentId);
  }
  if (online.isEmpty()) return;
  m_messageQuery = query;
  m_messageMatches.clear();
  m_pending = static_cast<int>(online.size());
  const QString raw = m_query.trimmed().left(200);
  for (const QString& environmentId : std::as_const(online)) {
    m_client->call(this, environmentId, QStringLiteral("orchestration.searchThreads"),
                   QJsonObject{{QStringLiteral("query"), raw}, {QStringLiteral("limit"), kMessageLimit}},
                   [this, generation, environmentId](const QJsonValue& result, const std::optional<QString>& error) {
                     if (generation != m_generation || m_mode != Mode::Command) return;
                     m_pending = std::max(0, m_pending - 1);
                     if (!error) {
                       for (const QJsonValue& value : result.toObject().value(QLatin1String("matches")).toArray()) {
                         const QJsonObject match = value.toObject();
                         const QString key =
                             environmentId + QLatin1Char(':') + match.value(QLatin1String("threadId")).toString();
                         if (!m_messageMatches.contains(key)) {
                           m_messageMatches.insert(key, match.value(QLatin1String("snippet")).toString());
                         }
                       }
                     }
                     refilter(true);
                   });
  }
}

void CommandPaletteController::searchFolders(int generation) {
  const QString query = m_query.trimmed();
  if (query.isEmpty() || m_browseEnvironment.isEmpty()) {
    m_entries.clear();
    m_browseParent.clear();
    m_browseEntries = {};
    refilter(true);
    return;
  }
  if (!m_store->environmentOnline(m_browseEnvironment)) {
    m_error = tr("The environment is not connected.");
    m_entries.clear();
    refilter(true);
    return;
  }
  if (relativeWithoutProject()) {
    m_error.clear();
    m_entries.clear();
    m_browseEntries = {};
    refilter(true);
    return;
  }
  // With a pinned name the whole folder is listed and filtered here, as the
  // web does: a leaf that is the pinned name hides nothing.
  const QString& pinned = m_browseOptions.pinned;
  const qsizetype slash = query.lastIndexOf(QLatin1Char('/'));
  const QString asked = pinned.isEmpty() || slash < 0 ? query : query.left(slash + 1);
  const QString leaf = asked == query ? QString() : query.mid(slash + 1);
  const QString filter = leaf == pinned ? QString() : leaf;
  const bool relative = !asked.startsWith(QLatin1Char('/')) && !asked.startsWith(QLatin1Char('~'));
  ++m_pending;
  m_client->call(this, m_browseEnvironment, QStringLiteral("filesystem.browse"),
                 // A relative path is under the shown project's folder (the contract's cwd).
                 relative ? QJsonObject{{QStringLiteral("partialPath"), asked}, {QStringLiteral("cwd"), target().root}}
                          : QJsonObject{{QStringLiteral("partialPath"), asked}},
                 [this, generation, query, asked, filter](const QJsonValue& result, const std::optional<QString>& error) {
                   if (generation != m_generation || m_mode != Mode::Browse) return;
                   m_pending = 0;
                   const QJsonObject answer = result.toObject();
                   m_error = error.value_or(QString());
                   m_browseQuery = query;
                   m_browseParent = answer.value(QLatin1String("parentPath")).toString();
                   m_browseEntries = answer.value(QLatin1String("entries")).toArray();
                   QList<Entry> entries;
                   const QString directories = tr("Directories");
                   // Up from a whole folder, to its parent.
                   if (asked.endsWith(QLatin1Char('/')) && !m_browseParent.isEmpty() &&
                       m_browseParent != QLatin1String("/")) {
                     QString up = QFileInfo(m_browseParent).path();
                     if (!up.endsWith(QLatin1Char('/'))) up += QLatin1Char('/');
                     Entry entry{Kind::Up, up, QStringLiteral(".."), {}, {}, {}};
                     entry.group = directories;
                     entries.append(entry);
                   }
                   for (const QJsonValue& value : std::as_const(m_browseEntries)) {
                     const QJsonObject folder = value.toObject();
                     const QString name = folder.value(QLatin1String("name")).toString();
                     if (asked != query && (!name.startsWith(filter, Qt::CaseInsensitive) ||
                                            (name.startsWith(QLatin1Char('.')) && !filter.startsWith(QLatin1Char('.'))))) {
                       continue;
                     }
                     Entry entry{Kind::Folder, folder.value(QLatin1String("fullPath")).toString(), name, {}, {}, {}};
                     entry.group = directories;
                     entries.append(entry);
                   }
                   m_entries = std::move(entries);
                   refilter(true);
                 });
}

// The web's resolved add path: a whole folder is the browsed parent; a named
// one is the folder of that name when it exists; anything else, as typed.
QString CommandPaletteController::browsedPath() const {
  const QString query = m_query.trimmed();
  if (query.isEmpty()) return {};
  // An answer for another path says nothing about this one.
  if (m_browseQuery != query) return query;
  if (query.endsWith(QLatin1Char('/'))) return m_browseParent.isEmpty() ? query : m_browseParent;
  const QString leaf = nameOf(query);
  for (const QJsonValue& value : m_browseEntries) {
    const QJsonObject folder = value.toObject();
    if (folder.value(QLatin1String("name")).toString() == leaf) return folder.value(QLatin1String("fullPath")).toString();
  }
  return query;
}
