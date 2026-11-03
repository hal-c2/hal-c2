// What tests/prop/tst_CodeHighlighterProp.cpp found in CodeHighlighter.

#include <QtTest>

#include <QSignalSpy>
#include <QTextBlock>
#include <QTextDocument>
#include <QTextLayout>

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

  // The same two changes, emptied and then filled, as a reply being written
  // grows: the empty one told the block was plain, and the filled one that it
  // was coloured again.
  void neverPlainWhileItsTextGrows() {
    QTextDocument document;
    document.documentLayout();
    CodeHighlighter highlighter;
    highlighter.setLanguage(QStringLiteral("ts"));
    highlighter.setStreaming(true);
    highlighter.setTextDocument(&document);
    document.setPlainText(QStringLiteral("const a = 1;\n"));
    QTRY_VERIFY(highlighter.coloured());
    QSignalSpy told(&highlighter, &CodeHighlighter::colouredChanged);
    document.setPlainText(QStringLiteral("const a = 1;\nconst b = 2;\n"));
    QTRY_VERIFY(!highlighter.reading());
    QCoreApplication::processEvents();
    QVERIFY(highlighter.coloured());
    QCOMPARE(told.count(), 0);
  }

  // Emptied for good, it is plain.
  void plainOnceEmptied() {
    QTextDocument document(QStringLiteral("const a = 1;\n"));
    document.documentLayout();
    CodeHighlighter highlighter;
    highlighter.setLanguage(QStringLiteral("ts"));
    highlighter.setTextDocument(&document);
    QTRY_VERIFY(highlighter.coloured());
    document.clear();
    QTRY_VERIFY(!highlighter.coloured());
  }

  // What was read is forgotten once the text has been empty: written again
  // while the reply is being written, its unfinished line waits.
  void forgetsWhatWasReadOnceEmptied() {
    QTextDocument document(QStringLiteral("\"str"));
    document.documentLayout();
    CodeHighlighter highlighter;
    highlighter.setLanguage(QStringLiteral("ts"));
    highlighter.setTextDocument(&document);
    QTRY_VERIFY(highlighter.coloured());
    highlighter.setStreaming(true);
    document.setPlainText(QString());
    QTRY_VERIFY(!highlighter.coloured());
    document.setPlainText(QStringLiteral("\"str"));
    QCoreApplication::processEvents();
    QVERIFY(!highlighter.coloured());
    QCOMPARE(document.firstBlock().layout()->formats().size(), 0);
  }
};

QTEST_MAIN(CodeHighlighterRegression)
#include "tst_CodeHighlighterRegression.moc"
