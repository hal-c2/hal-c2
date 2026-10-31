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
};

QTEST_GUILESS_MAIN(SpaceRegression)
#include "tst_SpaceRegression.moc"
