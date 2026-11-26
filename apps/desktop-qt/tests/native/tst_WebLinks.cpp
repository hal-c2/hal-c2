// Shell.openWebLink: what links from text someone else wrote (a pull request,
// its comments, a review) may open. Only web addresses reach the browser.

#include <QList>
#include <QTest>
#include <QUrl>

#include "ShellBridge.h"

class WebLinksTest : public QObject {
  Q_OBJECT

private slots:
  void opensOnlyWebAddresses_data() {
    QTest::addColumn<QString>("link");
    QTest::addColumn<bool>("opens");
    QTest::newRow("https") << QStringLiteral("https://github.com/acme/shop/pull/42") << true;
    QTest::newRow("http") << QStringLiteral("http://example.com/a?b=c#d") << true;
    QTest::newRow("upper-case scheme") << QStringLiteral("HTTPS://example.com") << true;
    QTest::newRow("app link") << QStringLiteral("hal-c2://new?prompt=hello") << false;
    QTest::newRow("file") << QStringLiteral("file:///etc/hosts") << false;
    QTest::newRow("mail") << QStringLiteral("mailto:someone@example.com") << false;
    QTest::newRow("script") << QStringLiteral("javascript:alert(1)") << false;
    QTest::newRow("data") << QStringLiteral("data:text/html,hi") << false;
    QTest::newRow("another app") << QStringLiteral("slack://open") << false;
    QTest::newRow("no host") << QStringLiteral("https:relative/path") << false;
    QTest::newRow("relative path") << QStringLiteral("src/cart.ts#L12") << false;
    QTest::newRow("empty") << QString() << false;
  }
  void opensOnlyWebAddresses() {
    QFETCH(QString, link);
    QFETCH(bool, opens);
    ShellBridge bridge;
    QList<QUrl> opened;
    bridge.setUrlOpener([&opened](const QUrl& url) {
      opened.append(url);
      return true;
    });
    QStringList actions;
    connect(&bridge, &ShellBridge::actionRequested, this, [&actions](const QString& action) { actions.append(action); });

    QCOMPARE(bridge.openWebLink(QUrl(link)), opens);
    QCOMPARE(opened, opens ? QList<QUrl>{QUrl(link)} : QList<QUrl>{});
    // The app's own links never route inside the app from here either.
    QCOMPARE(actions, QStringList{});
  }

  // A browser that cannot open the address is reported, not hidden.
  void reportsABrowserThatFails() {
    ShellBridge bridge;
    bridge.setUrlOpener([](const QUrl&) { return false; });
    QVERIFY(!bridge.openWebLink(QUrl(QStringLiteral("https://example.com"))));
  }
};

QTEST_GUILESS_MAIN(WebLinksTest)
#include "tst_WebLinks.moc"
