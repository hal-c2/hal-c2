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
};

QTEST_GUILESS_MAIN(WorkspaceTreeRegression)
#include "tst_WorkspaceTreeRegression.moc"
