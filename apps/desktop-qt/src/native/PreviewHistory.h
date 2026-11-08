#pragma once

#include <QList>
#include <QString>
#include <QStringList>
#include <QVariant>

// The pages this device's browser tabs visited, kept per project for a new tab
// to suggest (ThreadPreviews::suggestions): the newest first, each page once,
// under its tidy address (tidy()). A project keeps its last pagesPerProject
// pages, and the device the projectsKept projects used last.
//
// A visit is timed by when the page loaded (the MC's `updatedAt`), so news no
// newer than what is kept (a thread listing the title it last saw of a page
// another thread has loaded since) changes nothing. A page taken off the list
// comes back only with a later visit.
class PreviewHistory {
public:
  struct Page {
    QString url;
    QString title;
    qint64 at = 0;  // ms since the epoch
  };
  static constexpr int pagesPerProject = 50;
  static constexpr int projectsKept = 20;

  // The address a page is kept under: an http or https URL with a host, its
  // credentials dropped, this machine's loopback hosts as localhost and a bare
  // "/" path as none; "" for anything else.
  static QString tidy(const QString& url);
  // How a row shows a tidy address: without its scheme ("localhost:5173/docs").
  static QString shown(const QString& url);

  // Each says whether anything kept changed.
  bool visit(const QString& project, const QString& url, const QString& title, qint64 at);
  bool remove(const QString& project, const QString& url, qint64 at);

  // The project's pages, newest first.
  QList<Page> pages(const QString& project) const;
  // The projects kept, the one used last first.
  QStringList projects() const;

  QVariant toVariant() const;
  static PreviewHistory fromVariant(const QVariant& value);

private:
  struct Entry {
    QString url;
    QString title;
    qint64 at = 0;
    // Taken off the list at `at`: an older visit does not bring it back.
    bool removed = false;
    bool operator==(const Entry&) const = default;
  };
  struct Project {
    QString key;
    qint64 used = 0;
    QList<Entry> entries;  // newest first
    bool operator==(const Project&) const = default;
  };
  Project* find(const QString& project);
  // Puts the entry in its place by time, a tie in front, and trims the project.
  static void place(Project& project, const Entry& entry);
  void placeProject(Project project);

  QList<Project> m_projects;  // the one used last first
};
