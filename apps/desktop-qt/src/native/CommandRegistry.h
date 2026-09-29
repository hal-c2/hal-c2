#pragma once

#include <QAbstractListModel>
#include <QJSValue>
#include <QList>
#include <QPointer>
#include <QString>

#include <functional>

// The commands the shell runs itself, by keybinding command id
// (packages/contracts keybindings.ts) or, for one without a key, an id of its
// owner's (NavigationController::kOpenSettings): what a key press, the command
// palette or a menu runs natively instead of handing to the page. The command
// palette lists every one as an action. Each row is
// {command, title, shortcut}; KeybindingController fills in the shortcut label
// from the user's keybindings.
//
// C++ owners add a function; QML adds a callback owned by an object, and the
// command goes when that object does:
//
//   Keybindings.commands.add("appearance.cycle", qsTr("Cycle appearance"), () => cycle(), page)
class CommandRegistry : public QAbstractListModel {
  Q_OBJECT
  Q_PROPERTY(int count READ rowCount NOTIFY countChanged)

public:
  enum Role { CommandRole = Qt::UserRole + 1, TitleRole, ShortcutRole };

  using QAbstractListModel::QAbstractListModel;

  int rowCount(const QModelIndex& parent = QModelIndex()) const override;
  QVariant data(const QModelIndex& index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

  // Adds `command`, or replaces what it runs.
  void add(const QString& command, const QString& title, std::function<void()> run);
  Q_INVOKABLE void add(const QString& command, const QString& title, const QJSValue& callback, QObject* owner);
  Q_INVOKABLE void remove(const QString& command);
  Q_INVOKABLE bool contains(const QString& command) const { return indexOf(command) >= 0; }
  // Runs `command`; false when no one registered it.
  Q_INVOKABLE bool run(const QString& command);

  // The label of each command's shortcut; only rows whose label changed notify.
  void setShortcuts(const std::function<QString(const QString& command)>& labelFor);

signals:
  void countChanged();
  // After `command` ran.
  void ran(const QString& command);

private:
  struct Entry {
    QString command;
    QString title;
    QString shortcut;
    std::function<void()> run;
    QPointer<QObject> owner;
    bool owned = false;
  };

  qsizetype indexOf(const QString& command) const;

  QList<Entry> m_entries;
  std::function<QString(const QString&)> m_labelFor;
};
