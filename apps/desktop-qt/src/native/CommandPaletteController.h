#pragma once

#include <QAbstractListModel>
#include <QJsonArray>
#include <QList>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QTimer>

#include <functional>
#include <QVariantList>

#include "CommandRegistry.h"
#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// The command palette (the web's CommandPalette), as the `PaletteModel` QML
// singleton and the list the CommandPalette brick shows. It has four modes:
//
//   - command (commandPalette.toggle, mod+k). With no query, the web's
//     hand-picked actions (kRootCommands, each while its owner lists it) and
//     Recent Threads. A query adds every listed command in
//     Keybindings.commands (CommandRegistry), the sidebar's projects, the
//     settings sections the brick hands over (js/settingsPages.js, those whose
//     `requires` state is there) and the shell's threads, cluster and linked
//     alike (by key `environmentId:threadId`, archived and subagent ones left
//     out); from two characters on, threads whose messages match too
//     (`orchestration.searchThreads` on every online environment). A query
//     filters and ranks as the web does (CommandPalette.logic.ts); a leading
//     ">" keeps to actions. A menu command (CommandRegistry::addMenu) opens its
//     choices as a submenu; Backspace on an empty query leaves it.
//   - files (filePicker.toggle): the route thread's files by name
//     (`projects.searchEntries`); choosing one opens it in the right panel.
//   - content (projectSearch.toggle): text across them
//     (`projects.searchContents`, with the case, whole word and regular
//     expression options), matches grouped by file; choosing one opens its
//     file at the line.
//   - browse (Add project's Local folder): the query is a path on an
//     environment (`filesystem.browse`); choosing a folder goes into it, and
//     Enter with none highlighted adds the path as a project there. A clone's
//     destination browses with the repository's folder name pinned to the
//     path (BrowseOptions).
//   - ask (a clone's repository): the query is free text, nothing is listed,
//     and Enter hands it to the asker, which moves the palette on or closes it.
//
// Searches against the MC wait for typing to pause (kSearchDelayMs) and
// only the newest answer counts; files and content only while the route
// thread's environment is online, starting afresh when it moves to another
// project. Each row is {title, description, group,
// shortcut, kind, runnable, current}; a query change moves only the rows that
// differ, never resetting the list.
//
// Dismissing it gives the composer its keyboard back (`composer.focus` to the
// brick); running an entry leaves focus to what the entry opened. A command
// that fails says so ("Unable to run command").
class CommandPaletteController : public QAbstractListModel, public NativeController {
  Q_OBJECT
  Q_PROPERTY(bool open READ isOpen NOTIFY openChanged)
  // command, files, content, browse or ask.
  Q_PROPERTY(QString mode READ mode NOTIFY modeChanged)
  // The submenu shown, empty at the root.
  Q_PROPERTY(QString submenu READ submenu NOTIFY modeChanged)
  Q_PROPERTY(QString placeholder READ placeholder NOTIFY modeChanged)
  Q_PROPERTY(QString query READ query WRITE setQuery NOTIFY queryChanged)
  Q_PROPERTY(int highlighted READ highlighted WRITE setHighlighted NOTIFY highlightedChanged)
  Q_PROPERTY(int count READ count NOTIFY resultsChanged)
  // What the palette says when nothing is listed, or empty.
  Q_PROPERTY(QString emptyText READ emptyText NOTIFY resultsChanged)
  // A line over the content search's results ("3 results in 2 files").
  Q_PROPERTY(QString status READ status NOTIFY resultsChanged)
  Q_PROPERTY(bool caseSensitive READ caseSensitive WRITE setCaseSensitive NOTIFY optionsChanged)
  Q_PROPERTY(bool wholeWord READ wholeWord WRITE setWholeWord NOTIFY optionsChanged)
  Q_PROPERTY(bool useRegex READ useRegex WRITE setUseRegex NOTIFY optionsChanged)

public:
  enum Role {
    TitleRole = Qt::UserRole + 1,
    DescriptionRole,
    GroupRole,
    ShortcutRole,
    KindRole,
    EnabledRole,
    CurrentRole
  };

  static inline const QString kToggle = QStringLiteral("commandPalette.toggle");
  static inline const QString kFiles = QStringLiteral("filePicker.toggle");
  static inline const QString kContent = QStringLiteral("projectSearch.toggle");
  static constexpr int kRecentThreads = 12;
  static constexpr int kSearchDelayMs = 120;
  static constexpr int kFileLimit = 200;
  static constexpr int kContentLimit = 500;
  static constexpr int kMessageLimit = 20;
  // The root list with no query, in order (the web's actionItems).
  static const QStringList kRootCommands;

  CommandPaletteController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  // Registers the toggles and follows what the palette lists.
  void activate() override;
  bool handle(const QString&, const QVariant&) override { return false; }

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

  bool isOpen() const { return m_open; }
  QString mode() const;
  QString submenu() const;
  QString placeholder() const;
  QString query() const { return m_query; }
  int highlighted() const { return m_highlighted; }
  int count() const { return static_cast<int>(m_rows.size()); }
  QString emptyText() const;
  QString status() const;
  bool caseSensitive() const { return m_caseSensitive; }
  bool wholeWord() const { return m_wholeWord; }
  bool useRegex() const { return m_useRegex; }
  void setCaseSensitive(bool on);
  void setWholeWord(bool on);
  void setUseRegex(bool on);
  // The row's entry: kind (action, thread, project, setting, choice, file,
  // match, folder, up) and id (a command, thread key, project key, settings
  // path, choice id, file path, "path:line" or folder path).
  QString kindAt(int row) const;
  QString idAt(int row) const;
  // Whether a search against the MC is on its way.
  bool searching() const { return m_pending > 0 || m_debounce.isActive(); }

  // Opens it in command mode with an empty query and the first entry
  // highlighted.
  Q_INVOKABLE void show();
  // Opens it, or dismisses it when open.
  Q_INVOKABLE void toggle();
  // Opens it in `mode`, or closes it when it is open in that mode.
  Q_INVOKABLE void toggleMode(const QString& mode);
  // Closes it without running anything; the composer gets the keyboard back.
  Q_INVOKABLE void dismiss();
  // Escape: a secondary mode goes back to command mode, a submenu to the
  // root, anything else dismisses.
  Q_INVOKABLE void back();
  // Backspace on an empty query leaves a submenu; false when there is none.
  Q_INVOKABLE bool leaveSubmenu();
  void setQuery(const QString& query);
  void setHighlighted(int row);
  // Moves the highlight by `delta` rows, wrapping around.
  Q_INVOKABLE void move(int delta);
  // Runs the entry at `row` (a submenu or a folder moves the palette on;
  // anything else closes it first); false when there is none.
  Q_INVOKABLE bool run(int row);
  // Enter: the highlighted entry, or in browse mode with none, adds the path.
  Q_INVOKABLE bool runHighlighted();
  // Adds the browsed path as a project (browse mode's mod+Enter).
  Q_INVOKABLE bool addBrowsedFolder();
  // Opens the palette on the menu `command`'s choices.
  void showMenu(const QString& command);
  // How browse mode starts and what choosing does: `query` is where it
  // starts; `pinned`, when set, is a folder name kept at the end of the path
  // (a clone's "<chosen folder>/<repo>"); `emptyText` replaces the palette's
  // own; `keepOpen` leaves the palette open when the path is chosen, for the
  // chooser to close (finish) once it is done.
  struct BrowseOptions {
    QString query = QStringLiteral("~/");
    QString pinned;
    QString emptyText;
    bool keepOpen = false;
  };
  // Browses folders on `environmentId` from the home folder, for a new
  // project; `add` is given the path chosen.
  void browse(const QString& environmentId, std::function<void(const QString& path)> add,
              const BrowseOptions& options);
  void browse(const QString& environmentId, std::function<void(const QString& path)> add) {
    browse(environmentId, std::move(add), BrowseOptions());
  }
  // Asks for a line of text under `title` (ask mode): Enter gives the query,
  // trimmed and not empty, to `submit`, which leaves the palette open.
  void ask(const QString& title, const QString& placeholder, const QString& emptyText,
           std::function<void(const QString& text)> submit);
  // Closes it after an ask or a browse that kept it open.
  void finish() { close(false); }
  // Reads the submenu shown again from its source, as when what it lists
  // arrived after it opened.
  void refreshMenu();
  // The settings sections to offer: [{to, label, keywords, requires?}].
  Q_INVOKABLE void setSettingsSections(const QVariantList& sections);

signals:
  void openChanged();
  void modeChanged();
  void queryChanged();
  void highlightedChanged();
  void resultsChanged();
  void optionsChanged();

private:
  enum class Mode { Command, Files, Content, Browse, Ask };
  enum class Kind { Action, Thread, Project, Setting, Choice, File, Match, Folder, Up };

  struct Entry {
    Kind kind;
    QString id;
    QString title;
    QString description;
    QString shortcut;
    // Normalized search fields, most telling first, and all of them joined.
    QStringList terms;
    QString haystack;
    // Threads: when the user last wrote in it, for ties and the recent list.
    qint64 recency = 0;
    bool enabled = true;
    bool current = false;
    // Content matches: the file's group.
    QString group;
    // A keybinding command among the settings: listed after every setting.
    bool secondary = false;
  };

  struct Row {
    QString group;
    int entry;
    // Its group and entry id, which say whether a row moved.
    QString key;
    // A thread found by its messages shows the matching snippet.
    QString description;
  };

  // A submenu: the menu's title, its choices when it opened, and where they
  // come from.
  struct View {
    QString title;
    QList<CommandRegistry::Choice> choices;
    CommandRegistry::Choices source;
  };

  // Where files and content are searched: the route thread's environment and
  // folder.
  struct Target {
    QString environmentId;
    QString root;
    bool operator==(const Target&) const = default;
  };

  void open(Mode mode);
  void close(bool returnFocus);
  void setMode(Mode mode);
  void pushView(const QString& title, CommandRegistry::Choices source);
  // Reads what the palette lists again, while it is open.
  void rebuild();
  void rebuildCommand();
  void rebuildChoices();
  // Filters to the query and moves only the rows that changed; `refreshed`
  // says the entries themselves may have changed.
  void refilter(bool refreshed);
  void apply(QList<Row> next, bool refreshed);
  bool openEntry(const Entry& entry);
  bool runCommand(const QString& command);
  Target target() const;
  // Starts the mode's search against the MC once typing pauses.
  void scheduleSearch();
  void search();
  void searchFiles(int generation);
  void searchContent(int generation);
  void searchMessages(int generation);
  void searchFolders(int generation);
  QString browsedPath() const;
  void followTarget();

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  bool m_open = false;
  Mode m_mode = Mode::Command;
  QList<View> m_views;
  QString m_query;
  int m_highlighted = 0;
  QVariantList m_settingsSections;
  QList<Entry> m_entries;
  QList<Row> m_rows;
  // The command being run from the palette, whose failure is toasted.
  QString m_running;

  // Searches against the MC: the newest one's generation, and how many
  // answers are still to come.
  QTimer m_debounce;
  int m_generation = 0;
  int m_pending = 0;
  Target m_target;
  bool m_truncated = false;
  QString m_error;
  bool m_invalidRegex = false;
  bool m_caseSensitive = false;
  bool m_wholeWord = false;
  bool m_useRegex = false;
  // Threads whose messages match the query: key to snippet.
  QHash<QString, QString> m_messageMatches;
  QString m_messageQuery;
  // Browse mode: the environment, its answer, and what adding does.
  QString m_browseEnvironment;
  QString m_browseQuery;
  QString m_browseParent;
  QJsonArray m_browseEntries;
  std::function<void(const QString&)> m_add;
  BrowseOptions m_browseOptions;
  // Ask mode: its title, placeholder, empty text and what Enter does.
  QString m_askTitle;
  QString m_askPlaceholder;
  QString m_askEmpty;
  std::function<void(const QString&)> m_submit;
};
