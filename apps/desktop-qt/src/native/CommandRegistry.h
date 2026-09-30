#pragma once

#include <QAbstractListModel>
#include <QJSValue>
#include <QList>
#include <QPointer>
#include <QString>
#include <QStringList>

#include <functional>
#include <optional>

// The commands the shell runs itself, by keybinding command id
// (packages/contracts keybindings.ts) or, for one without a key, an id of its
// owner's (NavigationController::kOpenSettings): what a key press, the command
// palette or a menu runs. The command palette lists every one as an action. Each row is
// {command, title, shortcut, description, enabled, listed}; KeybindingController
// fills in the shortcut label from the user's keybindings.
//
// C++ owners add a function; QML adds a callback owned by an object, and the
// command goes when that object does:
//
//   Keybindings.commands.add("appearance.cycle", qsTr("Cycle appearance"), () => cycle(), owner)
//
// An owner keeps what the palette shows current: its title and description
// (setTitle, setDescription: "Copy PR link" and the link), whether it can run
// now (setEnabled; a disabled command does nothing) and whether the palette
// lists it at all (setListed; its key still runs it). A menu (addMenu) is a
// command whose run shows its choices in the palette, as "Change theme" does.
class CommandRegistry : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(int count READ rowCount NOTIFY countChanged)

public:
  enum Role { CommandRole = Qt::UserRole + 1, TitleRole, ShortcutRole, DescriptionRole, EnabledRole, ListedRole };

  // One of a menu's choices. `current` marks the one in effect ("Current");
  // `submenu`, when set, opens further choices instead of running; `keepOpen`
  // leaves the palette open after `run` (a choice that moves the palette on).
  struct Choice {
    QString id;
    QString title;
    QString description;
    bool current = false;
    bool enabled = true;
    QStringList terms;
    std::function<void()> run;
    std::function<QList<Choice>()> submenu;
    bool keepOpen = false;
  };
  using Choices = std::function<QList<Choice>()>;

  using QAbstractListModel::QAbstractListModel;

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

  // Adds `command`, or replaces what it runs.
  void add(const QString& command, const QString& title, std::function<void()> run);
  // A QML callback that throws fails the command (`failed`).
  Q_INVOKABLE void add(const QString& command, const QString& title, const QJSValue& callback, QObject* owner);
  // Adds `command` as a menu of `choices`, read each time it is shown.
  void addMenu(const QString& command, const QString& title, Choices choices);
  Q_INVOKABLE void remove(const QString& command);
  Q_INVOKABLE bool contains(const QString& command) const { return indexOf(command) >= 0; }
  // Runs `command` (a menu asks to be shown: `menuRequested`); false when no
  // one registered it. A disabled one is registered but does nothing.
  Q_INVOKABLE bool run(const QString& command);

  void setTitle(const QString& command, const QString& title);
  void setDescription(const QString& command, const QString& description);
  void setEnabled(const QString& command, bool enabled);
  void setListed(const QString& command, bool listed);
  // Search words beside the title (the web's searchTerms).
  void setTerms(const QString& command, const QStringList& terms);
  QStringList terms(const QString& command) const;
  bool isMenu(const QString& command) const;
  // A menu's choices now; empty for any other command.
  QList<Choice> choices(const QString& command) const;

  // The label of each command's shortcut; only rows whose label changed notify.
  void setShortcuts(const std::function<QString(const QString& command)>& labelFor);

signals:
  void countChanged();
  // After `command` ran.
  void ran(const QString& command);
  // A menu command ran: whoever shows menus (the palette) shows its choices.
  void menuRequested(const QString& command);
  // `command` ran and failed, saying why.
  void failed(const QString& command, const QString& message);

private:
  struct Entry {
    QString command;
    QString title;
    QString shortcut;
    // Returns why it failed, or nothing.
    std::function<std::optional<QString>()> run;
    QPointer<QObject> owner;
    bool owned = false;
    QString description;
    bool enabled = true;
    bool listed = true;
    QStringList terms;
    Choices choices;
  };

  qsizetype indexOf(const QString& command) const;
  void insert(Entry entry);
  // Changes one row's field, notifying only when it changed.
  template <class T>
  void change(const QString& command, T Entry::* field, const T& value, int role);

  QList<Entry> m_entries;
  std::function<QString(const QString&)> m_labelFor;
};
