// What tests/prop/tst_TimelineModelProp.cpp found in TimelineModel.

#include <QtTest>

#include "TimelineModel.h"

namespace {

const QString kAt = QStringLiteral("2026-09-23T10:00:00Z");

QJsonArray row(const QString& kind, const QJsonObject& entity) {
  return {kind, entity.value(QLatin1String("id")), entity};
}

QJsonObject run(const QString& status) {
  return {{QStringLiteral("id"), QStringLiteral("run-1")}, {QStringLiteral("ordinal"), 1}, {QStringLiteral("status"), status}};
}

QJsonObject item(const QString& id, const QString& type, int ordinal, const QJsonObject& fields = {}) {
  QJsonObject item{{QStringLiteral("id"), id},
                   {QStringLiteral("type"), type},
                   {QStringLiteral("runId"), QStringLiteral("run-1")},
                   {QStringLiteral("ordinal"), ordinal},
                   {QStringLiteral("status"), QStringLiteral("completed")}};
  for (auto it = fields.constBegin(); it != fields.constEnd(); ++it) item.insert(it.key(), *it);
  return item;
}

// Subscribes `model` and answers with a whole copy of `rows` as of `offset` in log `handle`.
void snapshot(TimelineModel& model, const QJsonArray& rows, int offset, const QString& handle = QStringLiteral("log-1")) {
  model.subscribing();
  model.receive({{QStringLiteral("t"), QStringLiteral("snapshot")},
                 {QStringLiteral("part"), 0},
                 {QStringLiteral("rows"), rows},
                 {QStringLiteral("done"), true},
                 {QStringLiteral("offset"), offset},
                 {QStringLiteral("handle"), handle},
                 {QStringLiteral("floor"), QJsonValue::Null}});
  model.receive({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), offset}, {QStringLiteral("handle"), handle}});
}

QJsonObject events(int seq, const QString& kind, const QString& id, const QJsonObject& patch) {
  return {{QStringLiteral("t"), QStringLiteral("events")},
          {QStringLiteral("offset"), seq},
          {QStringLiteral("events"), QJsonArray{QJsonArray{seq, kind, id, patch, kAt}}}};
}

int rowOf(const TimelineModel& model, const QString& id) {
  for (int at = 0; at < model.rowCount(); ++at) {
    if (model.data(model.index(at), TimelineModel::IdRole).toString() == id) return at;
  }
  return -1;
}

}  // namespace

class TimelineRepaintRegression : public QObject {
  Q_OBJECT

private slots:
  // A new copy of the same thread (the MC's log changed, so the client could
  // not catch up) redrew every row although none read differently.
  void anUnchangedCopyRedrawsNoRow() {
    TimelineModel model(QStringLiteral("thread"));
    const QJsonArray rows{row(QStringLiteral("run"), run(QStringLiteral("running"))),
                          row(QStringLiteral("turn-item"), item(QStringLiteral("ask"), QStringLiteral("user_message"), 2,
                                                                {{QStringLiteral("text"), QStringLiteral("ask")}}))};
    snapshot(model, rows, 2);
    QSignalSpy redrawn(&model, &QAbstractItemModel::dataChanged);
    snapshot(model, rows, 2, QStringLiteral("log-2"));
    QCOMPARE(redrawn.count(), 0);
  }

  // Text streamed into a call a collapsed work group does not show redrew the
  // group's entries.
  void textAHiddenCallStreamsRedrawsNoGroup() {
    TimelineModel model(QStringLiteral("thread"));
    snapshot(model,
             {row(QStringLiteral("run"), run(QStringLiteral("running"))),
              row(QStringLiteral("turn-item"), item(QStringLiteral("reas-2"), QStringLiteral("reasoning"), 2, {{QStringLiteral("text"), QStringLiteral("t")}})),
              row(QStringLiteral("turn-item"),
                  item(QStringLiteral("cmd-3"), QStringLiteral("command_execution"), 3, {{QStringLiteral("status"), QStringLiteral("running")}}))},
             3);
    QSignalSpy redrawn(&model, &QAbstractItemModel::dataChanged);
    model.receive(events(4, QStringLiteral("turn-item"), QStringLiteral("reas-2"),
                         {{QStringLiteral("a"), QJsonObject{{QStringLiteral("text"), QStringLiteral("more")}}}}));
    QCOMPARE(redrawn.count(), 0);
  }

  // An events frame sent again (a reconnect replaying what the client had)
  // appended its streamed text a second time.
  void anEventSentAgainIsAppliedOnce() {
    TimelineModel model(QStringLiteral("thread"));
    snapshot(model,
             {row(QStringLiteral("run"), run(QStringLiteral("running"))),
              row(QStringLiteral("turn-item"),
                  item(QStringLiteral("reply"), QStringLiteral("assistant_message"), 2,
                       {{QStringLiteral("text"), QStringLiteral("a")}, {QStringLiteral("streaming"), true}}))},
             2);
    const QJsonObject delta =
        events(3, QStringLiteral("turn-item"), QStringLiteral("reply"), {{QStringLiteral("a"), QJsonObject{{QStringLiteral("text"), QStringLiteral("b")}}}});
    model.receive(delta);
    model.receive(delta);
    QCOMPARE(model.data(model.index(rowOf(model, QStringLiteral("reply"))), TimelineModel::TextRole).toString(), QStringLiteral("ab"));
  }

  // Every subagent row redrew its model whenever a run or command changed;
  // only a change to the subagent's model does that.
  void aSubagentRowRedrawsItsModelOnlyWhenItChanges() {
    TimelineModel model(QStringLiteral("thread"));
    snapshot(model,
             {row(QStringLiteral("run"), run(QStringLiteral("running"))),
              row(QStringLiteral("subagent"), {{QStringLiteral("id"), QStringLiteral("agent-1")}, {QStringLiteral("model"), QStringLiteral("opus")}}),
              row(QStringLiteral("turn-item"), item(QStringLiteral("suba-2"), QStringLiteral("subagent"), 2,
                                                    {{QStringLiteral("subagentId"), QStringLiteral("agent-1")}}))},
             2);
    const int subagent = rowOf(model, QStringLiteral("suba-2"));
    QVERIFY(subagent >= 0);
    QSignalSpy redrawn(&model, &QAbstractItemModel::dataChanged);
    const auto modelRedrawn = [&] {
      for (const QList<QVariant>& args : std::as_const(redrawn)) {
        if (args.at(0).toModelIndex().row() <= subagent && args.at(1).toModelIndex().row() >= subagent &&
            args.at(2).value<QList<int>>().contains(TimelineModel::ModelRole)) {
          return true;
        }
      }
      return false;
    };
    model.receive(events(3, QStringLiteral("run"), QStringLiteral("run-1"), {{QStringLiteral("s"), QJsonObject{{QStringLiteral("status"), QStringLiteral("failed")}}}}));
    QVERIFY(!modelRedrawn());
    model.receive(events(4, QStringLiteral("subagent"), QStringLiteral("agent-1"), {{QStringLiteral("s"), QJsonObject{{QStringLiteral("model"), QStringLiteral("sonnet")}}}}));
    QVERIFY(modelRedrawn());
    QCOMPARE(model.data(model.index(subagent), TimelineModel::ModelRole).toString(), QStringLiteral("sonnet"));
  }

  // A subagent's model changed and changed back in one frame redrew its row.
  void aSubagentModelChangedBackRedrawsNothing() {
    TimelineModel model(QStringLiteral("thread"));
    snapshot(model,
             {row(QStringLiteral("run"), run(QStringLiteral("running"))),
              row(QStringLiteral("subagent"), {{QStringLiteral("id"), QStringLiteral("agent-1")}, {QStringLiteral("model"), QStringLiteral("opus")}}),
              row(QStringLiteral("turn-item"), item(QStringLiteral("suba-2"), QStringLiteral("subagent"), 2,
                                                    {{QStringLiteral("subagentId"), QStringLiteral("agent-1")}}))},
             2);
    QSignalSpy redrawn(&model, &QAbstractItemModel::dataChanged);
    const auto setModel = [](int seq, const QString& name) {
      return QJsonArray{seq, QStringLiteral("subagent"), QStringLiteral("agent-1"),
                        QJsonObject{{QStringLiteral("s"), QJsonObject{{QStringLiteral("model"), name}}}}, kAt};
    };
    model.receive({{QStringLiteral("t"), QStringLiteral("events")},
                   {QStringLiteral("offset"), 4},
                   {QStringLiteral("events"), QJsonArray{setModel(3, QStringLiteral("sonnet")), setModel(4, QStringLiteral("opus"))}}});
    QCOMPARE(redrawn.count(), 0);
  }

  // A catch-up in two parts, the first adding a reasoning item to a work group
  // and the second deleting it again, was applied part by part: the group
  // redrew twice although it reads as it did.
  void aCatchUpThatAddsAndRemovesAnItemRedrawsNothing() {
    TimelineModel model(QStringLiteral("thread"));
    const QJsonObject reasoning = item(QStringLiteral("reas-2"), QStringLiteral("reasoning"), 2, {{QStringLiteral("text"), QStringLiteral("t")}});
    snapshot(model, {row(QStringLiteral("run"), run(QStringLiteral("running"))), row(QStringLiteral("turn-item"), reasoning)}, 2);
    QSignalSpy redrawn(&model, &QAbstractItemModel::dataChanged);
    // The connection dropped; the client resumes from offset 2.
    model.subscribing();
    const QJsonObject added = item(QStringLiteral("reas-3"), QStringLiteral("reasoning"), 3, {{QStringLiteral("text"), QStringLiteral("u")}});
    model.receive({{QStringLiteral("t"), QStringLiteral("events")},
                   {QStringLiteral("offset"), 2},
                   {QStringLiteral("events"), QJsonArray{QJsonArray{3, QStringLiteral("turn-item"), QStringLiteral("reas-3"),
                                                                    QJsonObject{{QStringLiteral("d"), true}, {QStringLiteral("s"), added}}, kAt}}}});
    model.receive({{QStringLiteral("t"), QStringLiteral("events")},
                   {QStringLiteral("offset"), 4},
                   {QStringLiteral("events"), QJsonArray{QJsonArray{4, QStringLiteral("turn-item"), QStringLiteral("reas-3"),
                                                                    QJsonObject{{QStringLiteral("d"), true}}, kAt}}}});
    model.receive({{QStringLiteral("t"), QStringLiteral("live")}, {QStringLiteral("offset"), 4}, {QStringLiteral("handle"), QStringLiteral("log-1")}});
    QCOMPARE(redrawn.count(), 0);
    QCOMPARE(model.cursor().offset, 4);
  }
};

QTEST_GUILESS_MAIN(TimelineRepaintRegression)
#include "tst_TimelineRepaintRegression.moc"
