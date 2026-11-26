// The fake MC's fences (features/CodeFence.h), which the desktop's and the
// phone's page import and export use, against what the MC reads and writes:
// space_markdown_test.exs holds code-fences.json to HalC2.Space.Markdown.

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QTest>

#include "CodeFence.h"

class tst_CodeFence : public QObject {
  Q_OBJECT

  QJsonObject fences;

  static QJsonObject block(const QString& kind, const QString& said) {
    return QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("text"), said}, {QStringLiteral("checked"), false},
                       {QStringLiteral("linkedPageId"), QJsonValue::Null}};
  }

 private slots:
  void initTestCase() {
    QFile file(QStringLiteral(HAL_C2_CODE_FENCES));
    QVERIFY2(file.open(QIODevice::ReadOnly), qPrintable(file.fileName()));
    fences = QJsonDocument::fromJson(file.readAll()).object();
    QVERIFY(!fences.value(QLatin1String("read")).toArray().isEmpty());
  }

  // Each case is one fence, maybe with blank lines after it.
  void readsAsTheMcDoes() {
    for (const QJsonValue& value : fences.value(QLatin1String("read")).toArray()) {
      const QString markdown = value[QLatin1String("markdown")].toString();
      const QStringList lines = markdown.split(QLatin1Char('\n'));
      QVERIFY2(!codeFence::opens(lines.first()).isEmpty(), qPrintable(markdown));
      const auto [read, next] = codeFence::read(lines, 0, block);
      QCOMPARE(QJsonArray{read}, value[QLatin1String("blocks")].toArray());
      QCOMPARE(next, lines.size());
    }
  }

  void aBacktickAfterBackticksOpensNoFence() {
    for (const QJsonValue& line : fences.value(QLatin1String("notFences")).toArray())
      QVERIFY2(codeFence::opens(line.toString()).isEmpty(), qPrintable(line.toString()));
  }

  void writesAsTheMcDoes() {
    for (const QJsonValue& value : fences.value(QLatin1String("write")).toArray())
      QCOMPARE(codeFence::write(value[QLatin1String("block")].toObject()), value[QLatin1String("markdown")].toString());
  }
};

QTEST_GUILESS_MAIN(tst_CodeFence)
#include "tst_CodeFence.moc"
