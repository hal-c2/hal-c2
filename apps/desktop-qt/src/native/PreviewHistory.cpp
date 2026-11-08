#include "PreviewHistory.h"

#include <QUrl>
#include <QVariantMap>

#include <algorithm>

#include "ThisMachine.h"

QString PreviewHistory::tidy(const QString& url) {
  QUrl parsed(url.trimmed());
  if (!parsed.isValid() || (parsed.scheme() != QLatin1String("http") && parsed.scheme() != QLatin1String("https")) || parsed.host().isEmpty()) {
    return {};
  }
  parsed.setUserInfo(QString());
  if (thisMachine::loopbackHost(parsed.host())) parsed.setHost(QStringLiteral("localhost"));
  if (parsed.path() == QLatin1String("/")) parsed.setPath(QString());
  return parsed.toString();
}

QString PreviewHistory::shown(const QString& url) {
  const qsizetype scheme = url.indexOf(QLatin1String("://"));
  QString rest = scheme < 0 ? url : url.mid(scheme + 3);
  if (rest.endsWith(QLatin1Char('/'))) rest.chop(1);
  return rest;
}

PreviewHistory::Project* PreviewHistory::find(const QString& project) {
  for (Project& kept : m_projects) {
    if (kept.key == project) return &kept;
  }
  return nullptr;
}

void PreviewHistory::place(Project& project, const Entry& entry) {
  project.entries.removeIf([&](const Entry& kept) { return kept.url == entry.url; });
  const auto at = std::find_if(project.entries.begin(), project.entries.end(), [&](const Entry& kept) { return kept.at <= entry.at; });
  project.entries.insert(at, entry);
  // The newest pagesPerProject pages, and as many pages taken off: one taken
  // off before the oldest page of a full list could only come back to be
  // dropped again.
  int pages = 0;
  int removed = 0;
  qint64 oldest = 0;
  project.entries.removeIf([&](const Entry& kept) {
    if (!kept.removed) {
      if (pages == pagesPerProject) return true;
      if (++pages == pagesPerProject) oldest = kept.at;
      return false;
    }
    return ++removed > pagesPerProject;
  });
  if (pages == pagesPerProject) {
    project.entries.removeIf([&](const Entry& kept) { return kept.removed && kept.at < oldest; });
  }
}

void PreviewHistory::placeProject(Project project) {
  m_projects.removeIf([&](const Project& kept) { return kept.key == project.key; });
  const auto at = std::find_if(m_projects.begin(), m_projects.end(), [&](const Project& kept) { return kept.used <= project.used; });
  m_projects.insert(at, std::move(project));
  while (m_projects.size() > projectsKept) m_projects.removeLast();
}

bool PreviewHistory::visit(const QString& project, const QString& url, const QString& title, qint64 at) {
  const QString key = tidy(url);
  if (project.isEmpty() || key.isEmpty()) return false;
  const QList<Project> before = m_projects;
  Project kept = find(project) ? *find(project) : Project{project, at, {}};
  Entry entry{key, title, at, at, false};
  for (const Entry& known : std::as_const(kept.entries)) {
    if (known.url != key) continue;
    if (at < known.at || (known.removed && at == known.at)) return false;
    // A load that reports no title keeps the one the page had.
    if (title.isEmpty() && !known.removed) entry.title = known.title;
  }
  place(kept, entry);
  kept.used = std::max(kept.used, at);
  placeProject(std::move(kept));
  return m_projects != before;
}

bool PreviewHistory::remove(const QString& project, const QString& url, qint64 at) {
  Project* kept = find(project);
  const QString key = tidy(url);
  if (!kept || key.isEmpty()) return false;
  const auto known = std::find_if(kept->entries.cbegin(), kept->entries.cend(), [&](const Entry& entry) { return entry.url == key && !entry.removed; });
  if (known == kept->entries.cend()) return false;
  const qint64 removed = std::max(at, known->at);
  place(*kept, Entry{key, QString(), removed, removed, true});
  return true;
}

bool PreviewHistory::seen(const QString& project, const QString& url, const QString& title, qint64 at) {
  const QString key = tidy(url);
  if (project.isEmpty() || key.isEmpty()) return false;
  if (Project* kept = find(project)) {
    for (Entry& known : kept->entries) {
      if (known.url != key) continue;
      if (known.removed || title.isEmpty() || title == known.title || at < known.titled) return false;
      known.title = title;
      known.titled = at;
      return true;
    }
  }
  return visit(project, url, title, at);
}

bool PreviewHistory::keepUntimed(const QString& project, const QStringList& urls) {
  bool changed = false;
  for (qsizetype at = urls.size() - 1; at >= 0; --at) changed |= visit(project, urls.at(at), QString(), urls.size() - at);
  return changed;
}

QList<PreviewHistory::Page> PreviewHistory::pages(const QString& project) const {
  QList<Page> list;
  for (const Project& kept : m_projects) {
    if (kept.key != project) continue;
    for (const Entry& entry : kept.entries) {
      if (!entry.removed) list.append(Page{entry.url, entry.title, entry.at});
    }
  }
  return list;
}

QStringList PreviewHistory::projects() const {
  QStringList keys;
  for (const Project& kept : m_projects) keys.append(kept.key);
  return keys;
}

QVariant PreviewHistory::toVariant() const {
  QVariantList projects;
  for (const Project& kept : m_projects) {
    QVariantList entries;
    for (const Entry& entry : kept.entries) {
      QVariantMap page{{QStringLiteral("url"), entry.url}, {QStringLiteral("at"), entry.at}};
      if (!entry.title.isEmpty()) page.insert(QStringLiteral("title"), entry.title);
      if (entry.titled != entry.at) page.insert(QStringLiteral("titledAt"), entry.titled);
      if (entry.removed) page.insert(QStringLiteral("removed"), true);
      entries.append(page);
    }
    projects.append(QVariantMap{{QStringLiteral("project"), kept.key}, {QStringLiteral("used"), kept.used}, {QStringLiteral("pages"), entries}});
  }
  return projects;
}

PreviewHistory PreviewHistory::fromVariant(const QVariant& value) {
  // Read back through visit and remove, so a hand-edited or older file is kept tidy too.
  // Both lists are kept newest first; read oldest first, a tie in the order it was kept.
  PreviewHistory history;
  QVariantList projects = value.toList();
  std::reverse(projects.begin(), projects.end());
  for (const QVariant& item : std::as_const(projects)) {
    const QVariantMap project = item.toMap();
    const QString key = project.value(QStringLiteral("project")).toString();
    QVariantList pages = project.value(QStringLiteral("pages")).toList();
    std::reverse(pages.begin(), pages.end());
    std::stable_sort(pages.begin(), pages.end(), [](const QVariant& a, const QVariant& b) {
      return a.toMap().value(QStringLiteral("at")).toLongLong() < b.toMap().value(QStringLiteral("at")).toLongLong();
    });
    for (const QVariant& page : std::as_const(pages)) {
      const QVariantMap entry = page.toMap();
      const QString url = entry.value(QStringLiteral("url")).toString();
      const qint64 at = entry.value(QStringLiteral("at")).toLongLong();
      if (!entry.value(QStringLiteral("removed")).toBool()) {
        history.visit(key, url, entry.value(QStringLiteral("title")).toString(), at);
        const qint64 titled = entry.value(QStringLiteral("titledAt")).toLongLong();
        if (Project* kept = history.find(key); kept && titled > at) {
          for (Entry& known : kept->entries) {
            if (known.url == tidy(url) && known.at == at && !known.removed) known.titled = titled;
          }
        }
      } else if (const QString tidied = tidy(url); !key.isEmpty() && !tidied.isEmpty()) {
        // Never shown on the way in, so it pushes no page out.
        Project kept = history.find(key) ? *history.find(key) : Project{key, 0, {}};
        place(kept, Entry{tidied, QString(), at, at, true});
        history.placeProject(std::move(kept));
      }
    }
    if (Project* kept = history.find(key)) {
      Project moved = *kept;
      moved.used = std::max(moved.used, project.value(QStringLiteral("used")).toLongLong());
      history.placeProject(std::move(moved));
    }
  }
  return history;
}
