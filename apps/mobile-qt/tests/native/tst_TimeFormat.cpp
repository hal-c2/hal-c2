// What plugin pages format times with (Format.qml through ThreadStore): the
// short date, the date and time in the user's Time format, and how long ago.

#include <QtTest>

#include "TimelineModel.h"

class TimeFormat : public QObject {
  Q_OBJECT

  const QLocale english{QLocale::English, QLocale::UnitedStates};
  const QDateTime now{QDate(2026, 9, 23), QTime(10, 0)};

private slots:
  void aDateHasItsYearOnlyInAnotherYear() {
    QCOMPARE(shortDate(QDateTime(QDate(2026, 9, 20), QTime(18, 5)), now, english), QStringLiteral("9/20"));
    QCOMPARE(shortDate(QDateTime(QDate(2025, 9, 20), QTime(18, 5)), now, english), QStringLiteral("9/20/2025"));
    QCOMPARE(shortDate(QDateTime(), now, english), QString());
  }

  void aDateAndTimeFollowsTheTimeFormat() {
    const QDateTime evening(QDate(2026, 9, 20), QTime(18, 5));
    QCOMPARE(shortDateTime(evening, now, QStringLiteral("24-hour"), english), QStringLiteral("9/20 18:05"));
    QCOMPARE(shortDateTime(evening, now, QStringLiteral("12-hour"), english), QStringLiteral("9/20 6:05 PM"));
    // The locale's own clock, with the no-break space before PM made plain.
    QCOMPARE(shortDateTime(evening, now, QStringLiteral("locale"), english), QStringLiteral("9/20 6:05 PM"));
    QCOMPARE(shortDateTime(QDateTime(), now, QStringLiteral("24-hour"), english), QString());
  }

  void aRelativeTimeReadsBackAndAhead() {
    QCOMPARE(relativeTime(now.addSecs(-30), now), QStringLiteral("just now"));
    QCOMPARE(relativeTime(now.addSecs(30), now), QStringLiteral("just now"));
    QCOMPARE(relativeTime(now.addSecs(-5 * 60), now), QStringLiteral("5m ago"));
    QCOMPARE(relativeTime(now.addSecs(2 * 3600), now), QStringLiteral("in 2h"));
    QCOMPARE(relativeTime(now.addDays(-3), now), QStringLiteral("3d ago"));
    QCOMPARE(relativeTime(QDateTime(), now), QString());
  }
};

QTEST_GUILESS_MAIN(TimeFormat)
#include "tst_TimeFormat.moc"
