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

  // A block gone while its read waited, as one scrolled past is, was still
  // read, and the blocks left on screen waited behind it.
  void aBlockGoneBeforeItsTurnIsNotRead() {
    // Both readers busy, so what comes next waits.
    const QString busy = QStringLiteral("const x = 1;\n").repeated(15000);
    const int idle = CodeHighlighter::readsStarted();
    QTextDocument shown[2];
    CodeHighlighter kept[2];
    for (int i = 0; i < 2; ++i) {
      shown[i].setPlainText(busy + QString::number(i));
      kept[i].setLanguage(QStringLiteral("ts"));
      kept[i].setTextDocument(&shown[i]);
    }
    while (CodeHighlighter::readsStarted() < idle + 2) QThread::yieldCurrentThread();
    const int before = CodeHighlighter::readsStarted();
    {
      QTextDocument document(QStringLiteral("let gone = 1;\n"));
      CodeHighlighter gone;
      gone.setLanguage(QStringLiteral("ts"));
      gone.setTextDocument(&document);
      QVERIFY(gone.reading());
    }
    QTextDocument document(QStringLiteral("let next = 2;\n"));
    CodeHighlighter next;
    next.setLanguage(QStringLiteral("ts"));
    next.setTextDocument(&document);
    QTRY_VERIFY_WITH_TIMEOUT(next.coloured() && kept[0].coloured() && kept[1].coloured(), 30000);
    QCOMPARE(CodeHighlighter::readsStarted() - before, 1);
  }

  // One gone while it was being read leaves what it read for when it is back.
  void aBlockGoneWhileReadIsKept() {
    const QString code = QStringLiteral("const x = 1;\n").repeated(15000);
    const int before = CodeHighlighter::readsStarted();
    {
      QTextDocument document(code);
      CodeHighlighter gone;
      gone.setLanguage(QStringLiteral("ts"));
      gone.setTextDocument(&document);
      // Gone once its read has started, before that read can be heard of.
      while (CodeHighlighter::readsStarted() == before) QThread::yieldCurrentThread();
    }
    QTRY_VERIFY_WITH_TIMEOUT([&] {
      QTextDocument document(code);
      CodeHighlighter back;
      back.setLanguage(QStringLiteral("ts"));
      back.setTextDocument(&document);
      return back.coloured();
    }(), 30000);
  }
};

QTEST_MAIN(CodeHighlighterRegression)
#include "tst_CodeHighlighterRegression.moc"
