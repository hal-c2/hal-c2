#include <algorithm>

#include "SpaceController.h"

namespace {

int byName(const QString& a, const QString& b) {
  const int folded = QString::compare(a, b, Qt::CaseInsensitive);
  return folded != 0 ? folded : QString::compare(a, b);
}

// Depth first: at each level a folder's folders come before its files, each by name.
bool treeOrder(const QStringList& a, const QStringList& b) {
  for (qsizetype i = 0; i < a.size() && i < b.size(); ++i) {
    const bool aFolder = i < a.size() - 1;
    const bool bFolder = i < b.size() - 1;
    if (aFolder != bFolder) return aFolder;
    if (const int order = byName(a.at(i), b.at(i)); order != 0) return order < 0;
  }
  return a.size() < b.size();
}

}  // namespace

SpaceProjects::SpaceProjects(QObject* parent)
    : SpaceRows({"id", "kind", "projectId", "path", "name", "depth", "expanded", "pageId"}, parent) {}

void SpaceProjects::setProjects(QList<Project> projects) {
  // By name, as the user looks for one: the MC's rows come in no order.
  std::sort(projects.begin(), projects.end(), [](const Project& a, const Project& b) {
    const int order = QString::compare(a.title, b.title, Qt::CaseInsensitive);
    return order != 0 ? order < 0 : a.id < b.id;
  });
  const bool same = std::equal(projects.cbegin(), projects.cend(), m_projects.cbegin(), m_projects.cend(),
                               [](const Project& a, const Project& b) { return a.id == b.id && a.title == b.title; });
  if (same) return;
  m_projects = std::move(projects);
  build();
}

void SpaceProjects::setFiles(const QString& projectId, const QHash<QString, QString>& pages) {
  if (m_files.contains(projectId) && m_files.value(projectId) == pages) return;
  m_files.insert(projectId, pages);
  build();
}

void SpaceProjects::setExpanded(const QString& projectId, bool expanded) {
  if (projectId.isEmpty() || m_expanded.contains(projectId) == expanded) return;
  if (expanded) {
    m_expanded.insert(projectId);
  } else {
    m_expanded.remove(projectId);
  }
  build();
  emit expandedChanged();
}

void SpaceProjects::setFolderExpanded(const QString& projectId, const QString& path, bool expanded) {
  if (projectId.isEmpty() || path.isEmpty() || m_folders.value(projectId).contains(path) == expanded) return;
  if (expanded) {
    m_folders[projectId].insert(path);
  } else if (auto it = m_folders.find(projectId); it != m_folders.end()) {
    it->remove(path);
    if (it->isEmpty()) m_folders.erase(it);
  }
  build();
  emit expandedChanged();
}

void SpaceProjects::reveal(const QString& projectId, const QString& path) {
  if (projectId.isEmpty()) return;
  bool changed = false;
  if (!m_expanded.contains(projectId)) {
    m_expanded.insert(projectId);
    changed = true;
  }
  const QStringList parts = QString(path.startsWith(QLatin1String("./")) ? path.mid(2) : path).split(QLatin1Char('/'), Qt::SkipEmptyParts);
  for (qsizetype i = 1; i < parts.size(); ++i) {
    const QString folder = parts.mid(0, i).join(QLatin1Char('/'));
    QSet<QString>& folders = m_folders[projectId];
    if (folders.contains(folder)) continue;
    folders.insert(folder);
    changed = true;
  }
  if (m_folders.value(projectId).isEmpty()) m_folders.remove(projectId);
  if (!changed) return;
  build();
  emit expandedChanged();
}

QStringList SpaceProjects::expandedProjects() const {
  QStringList ids(m_expanded.cbegin(), m_expanded.cend());
  ids.sort();
  return ids;
}

QVariantMap SpaceProjects::expandedFolders() const {
  QVariantMap folders;
  for (auto it = m_folders.cbegin(); it != m_folders.cend(); ++it) {
    QStringList paths(it->cbegin(), it->cend());
    paths.sort();
    folders.insert(it.key(), paths);
  }
  return folders;
}

void SpaceProjects::restoreExpanded(const QStringList& projectIds, const QVariantMap& folders) {
  const QSet<QString> expanded(projectIds.cbegin(), projectIds.cend());
  QHash<QString, QSet<QString>> paths;
  for (auto it = folders.cbegin(); it != folders.cend(); ++it) {
    const QStringList list = it.value().toStringList();
    QSet<QString> set(list.cbegin(), list.cend());
    set.remove(QString());
    if (!it.key().isEmpty() && !set.isEmpty()) paths.insert(it.key(), set);
  }
  if (expanded == m_expanded && paths == m_folders) return;
  m_expanded = expanded;
  m_folders = std::move(paths);
  build();
}

void SpaceProjects::build() {
  QList<QVariantMap> rows;
  for (const Project& project : m_projects) {
    const QHash<QString, QString> pages = m_files.value(project.id);
    if (pages.isEmpty()) continue;
    const bool expanded = m_expanded.contains(project.id);
    rows.append({{QStringLiteral("id"), QStringLiteral("project:") + project.id},
                 {QStringLiteral("kind"), QStringLiteral("project")},
                 {QStringLiteral("projectId"), project.id},
                 {QStringLiteral("path"), QString()},
                 {QStringLiteral("name"), project.title.isEmpty() ? project.id : project.title},
                 {QStringLiteral("depth"), 0},
                 {QStringLiteral("expanded"), expanded},
                 {QStringLiteral("pageId"), QString()}});
    if (!expanded) continue;
    QList<QStringList> paths;
    for (auto it = pages.cbegin(); it != pages.cend(); ++it) paths.append(it.key().split(QLatin1Char('/'), Qt::SkipEmptyParts));
    std::sort(paths.begin(), paths.end(), treeOrder);
    const QSet<QString> openFolders = m_folders.value(project.id);
    // The folders the last file was in, each placed once.
    QStringList open;
    for (const QStringList& path : std::as_const(paths)) {
      if (path.isEmpty()) continue;
      const QStringList folders = path.mid(0, path.size() - 1);
      qsizetype common = 0;
      while (common < open.size() && common < folders.size() && open.at(common) == folders.at(common)) ++common;
      open = folders;
      // How many of its folders show: down to the first collapsed one, which shows itself.
      qsizetype shown = 0;
      bool inside = true;
      while (shown < folders.size() && inside) {
        inside = openFolders.contains(folders.mid(0, shown + 1).join(QLatin1Char('/')));
        ++shown;
      }
      for (qsizetype i = common; i < shown; ++i) {
        const QString at = folders.mid(0, i + 1).join(QLatin1Char('/'));
        rows.append({{QStringLiteral("id"), QStringLiteral("folder:%1:%2").arg(project.id, at)},
                     {QStringLiteral("kind"), QStringLiteral("folder")},
                     {QStringLiteral("projectId"), project.id},
                     {QStringLiteral("path"), at},
                     {QStringLiteral("name"), folders.at(i)},
                     {QStringLiteral("depth"), int(i) + 1},
                     {QStringLiteral("expanded"), openFolders.contains(at)},
                     {QStringLiteral("pageId"), QString()}});
      }
      if (!inside) continue;
      const QString relative = path.join(QLatin1Char('/'));
      rows.append({{QStringLiteral("id"), QStringLiteral("file:%1:%2").arg(project.id, relative)},
                   {QStringLiteral("kind"), QStringLiteral("file")},
                   {QStringLiteral("projectId"), project.id},
                   {QStringLiteral("path"), relative},
                   {QStringLiteral("name"), path.last()},
                   {QStringLiteral("depth"), int(folders.size()) + 1},
                   {QStringLiteral("expanded"), false},
                   {QStringLiteral("pageId"), pages.value(relative)}});
    }
  }
  setRows(rows);
}
