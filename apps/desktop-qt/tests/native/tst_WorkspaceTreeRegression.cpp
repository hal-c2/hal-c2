// What tests/prop/tst_WorkspaceTreeProp.cpp found in FileTreeModel.

#include <QtTest>

#include "FileTreeModel.h"

namespace {

using Entry = FileTreeModel::Entry;

QStringList kinds(const FileTreeModel& tree) {
  QStringList kinds;
  for (int row = 0; row < tree.rowCount(); ++row) {
    const QModelIndex at = tree.index(row);
    kinds.append(at.data(FileTreeModel::PathRole).toString() + QLatin1Char(' ') + at.data(FileTreeModel::KindRole).toString());
  }
  return kinds;
}

}  // namespace

class WorkspaceTreeRegression : public QObject {
  Q_OBJECT

private slots:
  // Reloading showed no rows at all until the top folder was listed, where a
  // folder loading anywhere else (and the top one after collapseAll) shows a
  // "loading" row.
  void reloadShowsTheTopFolderLoading() {
    FileTreeModel tree;
    tree.setFetch([](const QString&) {});
    tree.reload();
    QCOMPARE(kinds(tree), QStringList{QStringLiteral(" loading")});
  }

  // A folder the search matched but did not list, expanded during the search,
  // asked for its children and then kept its "loading" row: the listing landed
  // only in the user's tree.
  void aFolderOpenedDuringASearchShowsItsListing() {
    FileTreeModel tree;
    QStringList fetched;
    tree.setFetch([&](const QString& folder) { fetched.append(folder); });
    tree.reload();
    tree.setListing(QString(), {{QStringLiteral("a"), true, false}});
    tree.setSearch(QList<Entry>{{QStringLiteral("a"), true, false}});
    fetched.clear();
    tree.expand(QStringLiteral("a"));
    QCOMPARE(fetched, QStringList{QStringLiteral("a")});
    tree.setListing(QStringLiteral("a"), {{QStringLiteral("a/x"), false, false}});
    QCOMPARE(kinds(tree), (QStringList{QStringLiteral("a directory"), QStringLiteral("a/x file")}));
  }

  // The same folder already listed in the user's tree was asked for again
  // rather than shown.
  void aFolderOpenedDuringASearchReusesTheUsersListing() {
    FileTreeModel tree;
    QStringList fetched;
    tree.setFetch([&](const QString& folder) { fetched.append(folder); });
    tree.reload();
    tree.setListing(QString(), {{QStringLiteral("a"), true, false}});
    tree.expand(QStringLiteral("a"));
    tree.setListing(QStringLiteral("a"), {{QStringLiteral("a/x"), false, false}});
    tree.setSearch(QList<Entry>{{QStringLiteral("a"), true, false}});
    fetched.clear();
    tree.expand(QStringLiteral("a"));
    QVERIFY(fetched.isEmpty());
    QCOMPARE(kinds(tree), (QStringList{QStringLiteral("a directory"), QStringLiteral("a/x file")}));
  }

  // Retrying a folder during a search marked the search's copy loading and
  // left the user's tree failed, so the listing never showed in either.
  void retryDuringASearchListsTheFolderAgain() {
    FileTreeModel tree;
    tree.setFetch([](const QString&) {});
    tree.reload();
    tree.setListing(QString(), {{QStringLiteral("a"), true, false}});
    tree.expand(QStringLiteral("a"));
    tree.setFailed(QStringLiteral("a"), QStringLiteral("no such folder"));
    tree.setSearch(QList<Entry>{{QStringLiteral("a"), true, false}});
    tree.expand(QStringLiteral("a"));
    QCOMPARE(kinds(tree), (QStringList{QStringLiteral("a directory"), QStringLiteral("a error")}));
    tree.retry(QStringLiteral("a"));
    QCOMPARE(kinds(tree), (QStringList{QStringLiteral("a directory"), QStringLiteral("a loading")}));
    tree.setListing(QStringLiteral("a"), {{QStringLiteral("a/x"), false, false}});
    QCOMPARE(kinds(tree), (QStringList{QStringLiteral("a directory"), QStringLiteral("a/x file")}));
    tree.setSearch(std::nullopt);
    QCOMPARE(kinds(tree), (QStringList{QStringLiteral("a directory"), QStringLiteral("a/x file")}));
  }

  // tests/fuzz/tst_FileTreeModelFuzz.cpp: a folder whose listing named the
  // folder itself recursed until the stack ran out, on expandAll and on
  // expanding it by hand.
  void aFolderListingItselfIsDropped() {
    for (const bool all : {true, false}) {
      FileTreeModel tree;
      tree.setFetch([](const QString&) {});
      tree.reload();
      tree.setListing(QString(), {{QStringLiteral("a"), true, false}});
      tree.setListing(QStringLiteral("a"), {{QStringLiteral("a"), true, false}, {QStringLiteral("a/x"), false, false}});
      if (all) {
        tree.expandAll();
      } else {
        tree.expand(QStringLiteral("a"));
      }
      QCOMPARE(kinds(tree), (QStringList{QStringLiteral("a directory"), QStringLiteral("a/x file")}));
      QCOMPARE(tree.entriesIn(QStringLiteral("a")).size(), 1);
    }
  }

  // The same through two folders: a lists a/b, and a/b lists a.
  void aListingThatClosesACycleIsDropped() {
    FileTreeModel tree;
    tree.setFetch([](const QString&) {});
    tree.reload();
    tree.setListing(QString(), {{QStringLiteral("a"), true, false}});
    tree.setListing(QStringLiteral("a"), {{QStringLiteral("a/b"), true, false}});
    tree.setListing(QStringLiteral("a/b"), {{QStringLiteral("a"), true, false}, {QString(), true, false}});
    tree.expandAll();
    QCOMPARE(kinds(tree), (QStringList{QStringLiteral("a directory"), QStringLiteral("a/b directory")}));
  }

  // Only a folder's own entries show under it: not ".", "..", an empty name,
  // one further down or elsewhere, or a path from the filesystem's root.
  void aListingKeepsOnlyTheFoldersOwnEntries() {
    FileTreeModel tree;
    tree.setFetch([](const QString&) {});
    tree.reload();
    tree.setListing(QString(), {{QStringLiteral("a"), true, false},
                                {QStringLiteral("."), true, false},
                                {QStringLiteral(".."), true, false},
                                {QStringLiteral("/"), true, false},
                                {QStringLiteral("/etc"), true, false},
                                {QStringLiteral("c/z"), false, false}});
    tree.setListing(QStringLiteral("a"), {{QStringLiteral("a/"), true, false},
                                          {QStringLiteral("a/."), true, false},
                                          {QStringLiteral("a/b/y"), false, false},
                                          {QStringLiteral("ab/x"), false, false},
                                          {QStringLiteral("a/.hidden"), false, false}});
    tree.expand(QStringLiteral("a"));
    QCOMPARE(kinds(tree), (QStringList{QStringLiteral("a directory"), QStringLiteral("a/.hidden file")}));
  }

  // A search matching the top folder itself ("") listed it under itself.
  void aSearchMatchingTheTopIsDropped() {
    FileTreeModel tree;
    tree.setFetch([](const QString&) {});
    tree.reload();
    tree.setSearch(QList<Entry>{{QString(), true, false}, {QStringLiteral("a/x"), false, false}});
    QCOMPARE(kinds(tree), (QStringList{QStringLiteral("a directory"), QStringLiteral("a/x file")}));
  }
};

QTEST_GUILESS_MAIN(WorkspaceTreeRegression)
#include "tst_WorkspaceTreeRegression.moc"
