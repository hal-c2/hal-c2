#include "CommandRegistry.h"

int CommandRegistry::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : static_cast<int>(m_entries.size());
}

QVariant CommandRegistry::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() >= m_entries.size()) return {};
  const Entry& entry = m_entries.at(index.row());
  switch (role) {
    case CommandRole:
      return entry.command;
    case TitleRole:
      return entry.title;
    case ShortcutRole:
      return entry.shortcut;
    default:
      return {};
  }
}

QHash<int, QByteArray> CommandRegistry::roleNames() const {
  return {{CommandRole, "command"}, {TitleRole, "title"}, {ShortcutRole, "shortcut"}};
}

qsizetype CommandRegistry::indexOf(const QString& command) const {
  for (qsizetype index = 0; index < m_entries.size(); ++index) {
    if (m_entries.at(index).command == command) return index;
  }
  return -1;
}

void CommandRegistry::add(const QString& command, const QString& title, std::function<void()> run) {
  Entry entry{command, title, m_labelFor ? m_labelFor(command) : QString(), std::move(run), {}, false};
  if (const qsizetype index = indexOf(command); index >= 0) {
    m_entries[index] = std::move(entry);
    emit dataChanged(this->index(static_cast<int>(index)), this->index(static_cast<int>(index)));
    return;
  }
  const int row = static_cast<int>(m_entries.size());
  beginInsertRows({}, row, row);
  m_entries.append(std::move(entry));
  endInsertRows();
  emit countChanged();
}

void CommandRegistry::add(const QString& command, const QString& title, const QJSValue& callback, QObject* owner) {
  if (!callback.isCallable()) return;
  add(command, title, [callback] { QJSValue(callback).call(); });
  Entry& entry = m_entries[indexOf(command)];
  entry.owner = owner;
  entry.owned = owner != nullptr;
  if (owner) {
    connect(owner, &QObject::destroyed, this, [this, command] {
      const qsizetype index = indexOf(command);
      // Replaced by someone else since.
      if (index >= 0 && m_entries.at(index).owned && !m_entries.at(index).owner) remove(command);
    });
  }
}

void CommandRegistry::remove(const QString& command) {
  const qsizetype index = indexOf(command);
  if (index < 0) return;
  beginRemoveRows({}, static_cast<int>(index), static_cast<int>(index));
  m_entries.removeAt(index);
  endRemoveRows();
  emit countChanged();
}

bool CommandRegistry::run(const QString& command) {
  const qsizetype index = indexOf(command);
  if (index < 0) return false;
  // The command may remove itself or others while it runs.
  const std::function<void()> run = m_entries.at(index).run;
  run();
  emit ran(command);
  return true;
}

void CommandRegistry::setShortcuts(const std::function<QString(const QString&)>& labelFor) {
  m_labelFor = labelFor;
  for (qsizetype index = 0; index < m_entries.size(); ++index) {
    const QString label = labelFor(m_entries.at(index).command);
    if (label == m_entries.at(index).shortcut) continue;
    m_entries[index].shortcut = label;
    emit dataChanged(this->index(static_cast<int>(index)), this->index(static_cast<int>(index)), {ShortcutRole});
  }
}
