#pragma once

#include <QAbstractListModel>
#include <QList>
#include <QString>
#include <QStringList>
#include <QVariantList>

#include "NativeController.h"

class NodeClient;
class ShellBridge;
class ShellStore;

// The command palette (the web's CommandPalette), as the `PaletteModel` QML
// singleton and the list the CommandPalette brick shows. It lists:
//   - Actions: every command in Keybindings.commands (CommandRegistry) but its
//     own toggle and the thread jumps. An owner that wants an action here
//     registers it there, which also gives it a keybinding.
//   - Recent Threads (no query) or Threads (a query): the shell's threads,
//     cluster and linked environments alike, by key `environmentId:threadId`,
//     archived and subagent ones left out, most recent activity first.
//   - Projects and Settings (a query only): the sidebar's logical projects,
//     and the settings sections the brick hands over (js/settingsPages.js).
// A query filters and ranks as the web does (CommandPalette.logic.ts); a
// leading ">" keeps to actions. Each row is {title, description, group,
// shortcut, kind (action, thread, project, setting)}; a query change moves only
// the rows that differ, never resetting the list.
//
// `commandPalette.toggle` (mod+k) opens and closes it. Dismissing it gives the
// composer its keyboard back (`composer.focus` to the brick); running an entry
// leaves focus to what the entry opened.
class CommandPaletteController : public QAbstractListModel, public NativeController {
  Q_OBJECT
  Q_PROPERTY(bool open READ isOpen NOTIFY openChanged)
  Q_PROPERTY(QString query READ query WRITE setQuery NOTIFY queryChanged)
  Q_PROPERTY(int highlighted READ highlighted WRITE setHighlighted NOTIFY highlightedChanged)
  Q_PROPERTY(int count READ count NOTIFY resultsChanged)
  // What the palette says when nothing matches, or empty.
  Q_PROPERTY(QString emptyText READ emptyText NOTIFY resultsChanged)

public:
  enum Role { TitleRole = Qt::UserRole + 1, DescriptionRole, GroupRole, ShortcutRole, KindRole };

  static inline const QString kToggle = QStringLiteral("commandPalette.toggle");
  static constexpr int kRecentThreads = 12;

  CommandPaletteController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  // Registers the toggle and follows what the palette lists.
  void activate() override;
  bool handle(const QString&, const QVariant&) override { return false; }

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

  bool isOpen() const { return m_open; }
  QString query() const { return m_query; }
  int highlighted() const { return m_highlighted; }
  int count() const { return static_cast<int>(m_rows.size()); }
  QString emptyText() const;
  // The row's entry: kind and id (a command, thread key, project key or
  // settings path).
  QString kindAt(int row) const;
  QString idAt(int row) const;

  // Opens it with an empty query and the first entry highlighted.
  Q_INVOKABLE void show();
  // Opens it, or dismisses it when open.
  Q_INVOKABLE void toggle();
  // Closes it without running anything; the composer gets the keyboard back.
  Q_INVOKABLE void dismiss();
  void setQuery(const QString& query);
  void setHighlighted(int row);
  // Moves the highlight by `delta` rows, wrapping around.
  Q_INVOKABLE void move(int delta);
  // Closes the palette and runs the entry at `row`; false when there is none.
  Q_INVOKABLE bool run(int row);
  Q_INVOKABLE bool runHighlighted() { return run(m_highlighted); }
  // The settings sections to offer: [{to, label, keywords}].
  Q_INVOKABLE void setSettingsSections(const QVariantList& sections);

signals:
  void openChanged();
  void queryChanged();
  void highlightedChanged();
  void resultsChanged();

private:
  enum class Kind { Action, Thread, Project, Setting };

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
  };

  struct Row {
    int group;
    int entry;
    // What the row shows, whichever entry list it points into: its group and
    // entry id.
    QString key;
  };

  void close(bool returnFocus);
  // Reads what the palette lists again, while it is open.
  void rebuild();
  // Filters to the query and moves only the rows that changed; `refreshed`
  // says the entries themselves may have changed.
  void refilter(bool refreshed);
  bool openEntry(const Entry& entry);

  ShellBridge* m_bridge;
  ShellStore* m_store;
  bool m_active = false;
  bool m_open = false;
  QString m_query;
  int m_highlighted = 0;
  QVariantList m_settingsSections;
  QList<Entry> m_entries;
  QList<Row> m_rows;
};
