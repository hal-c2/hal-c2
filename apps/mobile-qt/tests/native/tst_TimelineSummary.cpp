// What a group of tool calls did, in a sentence (TimelineSummary.h): a
// file-read approval counts as a read however it was recorded.

#include <QTest>

#include "TimelineSummary.h"

namespace {

QString summarized(const QJsonObject& fields) {
  QJsonObject item{{QStringLiteral("type"), QStringLiteral("approval_request")},
                   {QStringLiteral("status"), QStringLiteral("completed")}};
  for (auto it = fields.constBegin(); it != fields.constEnd(); ++it) item.insert(it.key(), *it);
  return timeline::summarize({item}).text;
}

}  // namespace

class TimelineSummaryTest : public QObject {
  Q_OBJECT

private slots:
  void aFileReadApprovalCountsAsARead() {
    QCOMPARE(summarized({{QStringLiteral("requestKind"), QStringLiteral("file-read")}}), QStringLiteral("Read 1 file"));
  }

  // An approval recorded by an older version names a native request type
  // instead of a kind; the summary reads it as the kind of request it was,
  // the same mapping the composer's approval title uses.
  void aLegacyFileReadApprovalCountsAsARead() {
    QCOMPARE(summarized({{QStringLiteral("requestType"), QStringLiteral("file_read_approval")}}), QStringLiteral("Read 1 file"));
  }

  void anotherApprovalDoesNotCountAsARead() {
    QCOMPARE(summarized({{QStringLiteral("requestType"), QStringLiteral("exec_command_approval")}}), QStringLiteral("Used 1 tool"));
  }
};

QTEST_GUILESS_MAIN(TimelineSummaryTest)
#include "tst_TimelineSummary.moc"
