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
    case DescriptionRole:
      return entry.description;
    case EnabledRole:
      return entry.enabled;
    case ListedRole:
      return entry.listed;
    default:
      return {};
  }
}

QHash<int, QByteArray> CommandRegistry::roleNames() const {
  return {{CommandRole, "command"},         {TitleRole, "title"},     {ShortcutRole, "shortcut"},
          {DescriptionRole, "description"}, {EnabledRole, "enabled"}, {ListedRole, "listed"}};
}

qsizetype CommandRegistry::indexOf(const QString& command) const {
  for (qsizetype index = 0; index < m_entries.size(); ++index) {
    if (m_entries.at(index).command == command) return index;
  }
  return -1;
}

// A replaced command keeps how its owner presents it.
void CommandRegistry::insert(Entry entry) {
  entry.shortcut = m_labelFor ? m_labelFor(entry.command) : QString();
  if (const qsizetype index = indexOf(entry.command); index >= 0) {
    Entry& kept = m_entries[index];
    kept.title = entry.title;
    kept.run = std::move(entry.run);
    kept.choices = std::move(entry.choices);
    kept.owner = entry.owner;
    kept.owned = entry.owned;
    emit dataChanged(this->index(static_cast<int>(index)), this->index(static_cast<int>(index)));
    return;
  }
  const int row = static_cast<int>(m_entries.size());
  beginInsertRows({}, row, row);
  m_entries.append(std::move(entry));
  endInsertRows();
  emit countChanged();
}

void CommandRegistry::add(const QString& command, const QString& title, std::function<void()> run) {
  insert({command, title, {}, [run = std::move(run)] {
            run();
            return std::optional<QString>();
          }});
}

void CommandRegistry::add(const QString& command, const QString& title, const QJSValue& callback, QObject* owner) {
  if (!callback.isCallable()) return;
  Entry entry{command, title, {}, [callback] {
                const QJSValue result = QJSValue(callback).call();
                if (!result.isError()) return std::optional<QString>();
                return std::optional<QString>(result.property(QStringLiteral("message")).toString());
              }};
  entry.owner = owner;
  entry.owned = owner != nullptr;
  insert(std::move(entry));
  if (owner) {
    connect(owner, &QObject::destroyed, this, [this, command] {
      const qsizetype index = indexOf(command);
      // Replaced by someone else since.
      if (index >= 0 && m_entries.at(index).owned && !m_entries.at(index).owner) remove(command);
    });
  }
}

void CommandRegistry::addMenu(const QString& command, const QString& title, Choices choices) {
  Entry entry{command, title, {}, [this, command] {
                emit menuRequested(command);
                return std::optional<QString>();
              }};
  entry.choices = std::move(choices);
  insert(std::move(entry));
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
  if (!m_entries.at(index).enabled) return true;
  // The command may remove itself or others while it runs.
  const auto run = m_entries.at(index).run;
  const std::optional<QString> failure = run();
  emit ran(command);
  if (failure) emit failed(command, *failure);
  return true;
}

template <class T>
void CommandRegistry::change(const QString& command, T Entry::* field, const T& value, int role) {
  const qsizetype index = indexOf(command);
  if (index < 0 || m_entries.at(index).*field == value) return;
  m_entries[index].*field = value;
  emit dataChanged(this->index(static_cast<int>(index)), this->index(static_cast<int>(index)), {role});
}

void CommandRegistry::setTitle(const QString& command, const QString& title) {
  change(command, &Entry::title, title, TitleRole);
}

void CommandRegistry::setDescription(const QString& command, const QString& description) {
  change(command, &Entry::description, description, DescriptionRole);
}

void CommandRegistry::setEnabled(const QString& command, bool enabled) {
  change(command, &Entry::enabled, enabled, EnabledRole);
}

void CommandRegistry::setListed(const QString& command, bool listed) {
  change(command, &Entry::listed, listed, ListedRole);
}

void CommandRegistry::setTerms(const QString& command, const QStringList& terms) {
  // Searched, not shown: no row changes.
  if (const qsizetype index = indexOf(command); index >= 0) m_entries[index].terms = terms;
}

QStringList CommandRegistry::terms(const QString& command) const {
  const qsizetype index = indexOf(command);
  return index >= 0 ? m_entries.at(index).terms : QStringList();
}

bool CommandRegistry::isMenu(const QString& command) const {
  const qsizetype index = indexOf(command);
  return index >= 0 && m_entries.at(index).choices;
}

QList<CommandRegistry::Choice> CommandRegistry::choices(const QString& command) const {
  const qsizetype index = indexOf(command);
  return index >= 0 && m_entries.at(index).choices ? m_entries.at(index).choices() : QList<Choice>();
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
