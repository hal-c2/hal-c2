// What tests/prop/tst_CodeHighlighterProp.cpp found in CodeHighlighter.

#include <QtTest>

#include <QTextDocument>

#include "CodeHighlighter.h"

class CodeHighlighterRegression : public QObject {
  Q_OBJECT
private slots:
  void init() { CodeHighlighter::clearCache(); }

  // The base class clears the document's colours as it is destroyed, which
  // the document reports as a change: heard by a highlighter half gone, it
  // aborted.
  void destroyedOnAColouredDocument() {
    QTextDocument document(QStringLiteral("const x = 1;\n"));
    document.documentLayout();
    {
      CodeHighlighter highlighter;
      highlighter.setLanguage(QStringLiteral("ts"));
      highlighter.setTextDocument(&document);
      QTRY_VERIFY(highlighter.coloured());
    }
    QCOMPARE(document.toPlainText(), QStringLiteral("const x = 1;\n"));
  }

  // A whole new text comes as two changes, emptied and then filled; the
  // empty one left `coloured` false though the new text was coloured.
  void stillColouredWhenItsTextIsSetAgainWithMore() {
    QTextDocument document;
    document.documentLayout();
    CodeHighlighter highlighter;
    highlighter.setLanguage(QStringLiteral("ts"));
    highlighter.setTextDocument(&document);
    document.setPlainText(QStringLiteral("import QtQuick\n"));
    QTRY_VERIFY(highlighter.coloured());
    highlighter.setStreaming(true);
    document.setPlainText(QStringLiteral("import QtQuick\n\"str"));
    QTRY_VERIFY(!highlighter.reading());
    QVERIFY(highlighter.coloured());
  }
};

QTEST_MAIN(CodeHighlighterRegression)
#include "tst_CodeHighlighterRegression.moc"
