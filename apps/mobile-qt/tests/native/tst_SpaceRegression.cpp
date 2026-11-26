// What review found in SpacePages, the Space view's copy of the index and a Space.

#include <QtTest>

#include "SpaceController.h"

namespace {

QJsonObject snapshot(const QString& handle, const QJsonArray& rows) {
  return {{QStringLiteral("t"), QStringLiteral("snapshot")}, {QStringLiteral("offset"), 1}, {QStringLiteral("part"), 0},
          {QStringLiteral("rows"), rows}, {QStringLiteral("done"), true}, {QStringLiteral("handle"), handle}};
}

QJsonObject live(const QString& handle) {
  return {{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), 1}, {QStringLiteral("handle"), handle}};
}

QJsonArray row(const QString& kind, const QString& id, QJsonObject entity) {
  entity.insert(QStringLiteral("id"), id);
  return {kind, id, entity};
}

}  // namespace

class SpaceRegression : public QObject {
  Q_OBJECT

private slots:
  // A page made from a thread before the Space view was ever opened awaits its
  // Space and its page. Selecting the Space when the index arrived forgot the
  // page, so the Space opened on its first page instead of the new one.
  void aPageAwaitedBeforeTheIndexArrivesIsTheOneShown() {
    SpacePages pages;
    pages.awaitSpace(QStringLiteral("s2"));
    pages.awaitPage(QStringLiteral("p2"));
    pages.receiveIndex(snapshot(QStringLiteral("index"),
                                {row(QStringLiteral("space"), QStringLiteral("s1"), {{QStringLiteral("name"), QStringLiteral("Personal")}, {QStringLiteral("createdAt"), QStringLiteral("2026-01-01T00:00:00Z")}}),
                                 row(QStringLiteral("space"), QStringLiteral("s2"), {{QStringLiteral("name"), QStringLiteral("Research")}, {QStringLiteral("createdAt"), QStringLiteral("2026-01-02T00:00:00Z")}})}));
    pages.receiveIndex(live(QStringLiteral("index")));
    QCOMPARE(pages.spaceId(), QStringLiteral("s2"));
    pages.receiveSpace(snapshot(QStringLiteral("space"),
                                {row(QStringLiteral("page"), QStringLiteral("p1"), {{QStringLiteral("title"), QStringLiteral("Roadmap")}, {QStringLiteral("createdAt"), QStringLiteral("2026-01-01T00:00:00Z")}}),
                                 row(QStringLiteral("page"), QStringLiteral("p2"), {{QStringLiteral("title"), QStringLiteral("Release plan")}, {QStringLiteral("createdAt"), QStringLiteral("2026-01-02T00:00:00Z")}})}));
    pages.receiveSpace(live(QStringLiteral("space")));
    QCOMPARE(pages.pageId(), QStringLiteral("p2"));
  }

  // A restore that swaps one block for another keeps the count of blocks, so
  // comment rows reading the block list by its count kept their old label.
  void aSwapOfBlocksRedrawsTheCommentsOnThem() {
    const auto block = [](const QString& id) {
      return row(QStringLiteral("block"), id, {{QStringLiteral("pageId"), QStringLiteral("p1")}, {QStringLiteral("text"), id}});
    };
    const auto comment = [](const QString& id, const QString& blockId) {
      return row(QStringLiteral("comment"), id, {{QStringLiteral("pageId"), QStringLiteral("p1")}, {QStringLiteral("blockId"), blockId}});
    };
    const auto event = [](int seq, const QString& kind, const QString& id, const QJsonObject& patch) {
      return QJsonObject{{QStringLiteral("t"), QStringLiteral("events")}, {QStringLiteral("offset"), seq},
                         {QStringLiteral("events"), QJsonArray{QJsonArray{seq, kind, id, patch, QStringLiteral("2026-01-01T00:00:00Z")}}}};
    };
    SpacePages pages;
    pages.receiveIndex(snapshot(QStringLiteral("index"), {row(QStringLiteral("space"), QStringLiteral("s1"), {{QStringLiteral("name"), QStringLiteral("Research")}})}));
    pages.receiveIndex(live(QStringLiteral("index")));
    pages.receiveSpace(snapshot(QStringLiteral("space"),
                                {row(QStringLiteral("page"), QStringLiteral("p1"), {{QStringLiteral("title"), QStringLiteral("Roadmap")}}),
                                 block(QStringLiteral("x")), comment(QStringLiteral("on-x"), QStringLiteral("x")), comment(QStringLiteral("on-y"), QStringLiteral("y"))}));
    pages.receiveSpace(live(QStringLiteral("space")));
    const auto gone = [&pages](const QString& id) {
      return pages.comments()->get(pages.comments()->indexOf(id)).value(QStringLiteral("blockGone")).toBool();
    };
    QVERIFY(!gone(QStringLiteral("on-x")));
    QVERIFY(gone(QStringLiteral("on-y")));

    QSignalSpy redrawn(pages.comments(), &QAbstractItemModel::dataChanged);
    pages.receiveSpace(event(2, QStringLiteral("block"), QStringLiteral("x"), {{QStringLiteral("d"), true}}));
    pages.receiveSpace(event(3, QStringLiteral("block"), QStringLiteral("y"), {{QStringLiteral("s"), block(QStringLiteral("y")).at(2)}}));
    QVERIFY(gone(QStringLiteral("on-x")));
    QVERIFY(!gone(QStringLiteral("on-y")));
    QCOMPARE(pages.blocks()->rowCount(), 1);
    QCOMPARE(redrawn.count(), 2);
  }
};

QTEST_GUILESS_MAIN(SpaceRegression)
#include "tst_SpaceRegression.moc"
