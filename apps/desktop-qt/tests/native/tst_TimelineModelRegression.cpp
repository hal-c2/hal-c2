// What tests/fuzz/tst_TimelineModelFuzz.cpp found in TimelineModel.

#include <QtTest>

#include "TimelineModel.h"

namespace {

QJsonObject frame(const QByteArray& json) {
  return QJsonDocument::fromJson(json).object();
}

QStringList rowIds(const TimelineModel& model) {
  QStringList ids;
  for (int at = 0; at < model.rowCount(); ++at) ids.append(model.data(model.index(at), TimelineModel::IdRole).toString());
  return ids;
}

QStringList entryIds(const TimelineModel& model, int row) {
  QStringList ids;
  for (const QVariant& entry : model.data(model.index(row), TimelineModel::EntriesRole).toList()) {
    ids.append(entry.toMap().value(QStringLiteral("id")).toString());
  }
  return ids;
}

}  // namespace

class TimelineModelRegression : public QObject {
  Q_OBJECT

private slots:
  // Rows took their ids from a turn item's `id` field, not its key in the
  // stream: two items without one made two rows with the same id, and
  // laying out the next rows read past the end of the list.
  void itemsWithoutAnIdFieldKeepRowsOfTheirOwn() {
    TimelineModel model(QStringLiteral("thread"));
    model.subscribing();
    model.receive(frame(R"({"t":"snapshot","part":0,"done":true,"offset":1,"handle":"log-1","floor":null,"rows":[
        ["run","r1",{"id":"r1","ordinal":1,"status":"running"}],
        ["turn-item","i1",{"type":"user_message","runId":"r1","ordinal":1,"text":"one"}]]})"));
    model.receive(frame(R"({"t":"events","offset":2,"events":[
        [2,"turn-item","i2",{"s":{"type":"user_message","runId":"r1","ordinal":2,"text":"two"}},"2026-09-23T10:00:00Z"]]})"));
    QCOMPARE(rowIds(model), (QStringList{QStringLiteral("i1"), QStringLiteral("i2")}));
    QCOMPARE(model.data(model.index(1), TimelineModel::TextRole).toString(), QStringLiteral("two"));
  }

  // Two calls whose `id` fields agree are two calls of one group, each
  // named by its key.
  void callsSharingAnIdFieldAreEachTheirOwnEntry() {
    TimelineModel model(QStringLiteral("thread"));
    model.subscribing();
    model.receive(frame(R"({"t":"snapshot","part":0,"done":true,"offset":1,"handle":"log-1","floor":null,"rows":[
        ["run","r1",{"id":"r1","ordinal":1,"status":"running"}],
        ["turn-item","c1",{"id":"same","type":"command_execution","runId":"r1","ordinal":1,"status":"completed"}],
        ["turn-item","c2",{"id":"same","type":"command_execution","runId":"r1","ordinal":2,"status":"completed"}],
        ["turn-item","m1",{"id":"same","type":"assistant_message","runId":"r1","ordinal":3,"text":"done"}]]})"));
    QCOMPARE(rowIds(model), (QStringList{QStringLiteral("work:c1"), QStringLiteral("m1")}));
    model.toggle(QStringLiteral("work:c1"));
    QCOMPARE(entryIds(model, 0), (QStringList{QStringLiteral("c1"), QStringLiteral("c2")}));
  }

  // An item keyed like the rows the timeline makes up (a turn's fold, a
  // group of calls) still gets a row of its own.
  void anItemKeyedLikeAFoldOrGroupKeepsARowOfItsOwn() {
    TimelineModel model(QStringLiteral("thread"));
    model.subscribing();
    model.receive(frame(R"({"t":"snapshot","part":0,"done":true,"offset":1,"handle":"log-1","floor":null,"rows":[
        ["run","r1",{"id":"r1","ordinal":1,"status":"completed"}],
        ["turn-item","fold:r1",{"type":"assistant_message","runId":"r1","ordinal":1,"text":"first"}],
        ["turn-item","c1",{"type":"command_execution","runId":"r1","ordinal":2,"status":"running"}],
        ["turn-item","work:c1",{"type":"assistant_message","runId":"r1","ordinal":3,"text":"last"}]]})"));
    // The fold, the running call and the last reply.
    QStringList ids = rowIds(model);
    QCOMPARE(ids.size(), 3);
    QCOMPARE(QSet<QString>(ids.cbegin(), ids.cend()).size(), ids.size());
    QCOMPARE(ids.mid(0, 2), (QStringList{QStringLiteral("fold:r1"), QStringLiteral("work:c1")}));
    QCOMPARE(model.data(model.index(2), TimelineModel::TextRole).toString(), QStringLiteral("last"));
    // Opened, the fold shows the first reply under it.
    model.toggle(QStringLiteral("fold:r1"));
    ids = rowIds(model);
    QCOMPARE(ids.size(), 4);
    QCOMPARE(QSet<QString>(ids.cbegin(), ids.cend()).size(), ids.size());
    QCOMPARE(model.data(model.index(1), TimelineModel::TextRole).toString(), QStringLiteral("first"));
  }

  // A number the MC sends outside the range of the integer it is read as (an
  // offset of 1e300) was cast anyway, which is undefined. It reads as a
  // missing offset: the copy is at no offset, so the first events apply and a
  // frame sent again is still told from the first.
  void anOffsetOutOfRangeReadsAsNone() {
    for (const char* offset : {"1e300", "-1e300", "9.3e18", "1.5"}) {
      TimelineModel model(QStringLiteral("thread"));
      model.subscribing();
      model.receive(frame(QByteArray(R"({"t":"snapshot","part":0,"done":true,"offset":)") + offset + R"(,"handle":"log-1","floor":)" + offset +
                          R"(,"rows":[
          ["run","r1",{"id":"r1","ordinal":1e300,"status":"running"}],
          ["turn-item","i1",{"type":"assistant_message","runId":"r1","ordinal":1,"text":"a"}]]})"));
      const QByteArray events = QByteArray(R"({"t":"events","offset":2,"events":[[2,"turn-item","i1",{"a":{"text":"b"}},"2026-09-23T10:00:00Z"]]})");
      model.receive(frame(events));
      model.receive(frame(events));
      QCOMPARE(model.data(model.index(0), TimelineModel::TextRole).toString(), QStringLiteral("ab"));
    }
  }
};

QTEST_MAIN(TimelineModelRegression)
#include "tst_TimelineModelRegression.moc"
