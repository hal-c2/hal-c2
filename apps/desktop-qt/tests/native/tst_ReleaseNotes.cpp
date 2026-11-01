#include <QTest>

#include "DesktopUpdateLogic.h"

using desktopUpdate::normalizeReleaseNotes;
using desktopUpdate::kNightly;

namespace {

QString nightly(int day) {
  return QStringLiteral("1.4.0-nightly.202609%1.1").arg(day, 2, 10, QLatin1Char('0'));
}

desktopUpdate::ReleaseNote only(const QString& note) {
  const desktopUpdate::Notes notes = normalizeReleaseNotes({{nightly(1), note}}, kNightly);
  return notes.releaseNotes.value(0);
}

}  // namespace

// What a GitHub release's body becomes in the update button's release notes
// (upstream releaseNotes.ts).
class ReleaseNotesTest : public QObject {
  Q_OBJECT

private slots:
  void changesArePlainTextWithLinksAsTheirWords() {
    const auto note = only(QStringLiteral("* **Faster** threads by @maria in [#12](https://github.com/hal-c2/hal-c2/pull/12)\n"
                                          "- Fix the sidebar\n"
                                          "1. Numbered change\n"));
    QCOMPARE(note.items, (QStringList{QStringLiteral("Numbered change"), QStringLiteral("Fix the sidebar"),
                                      QStringLiteral("Faster threads by @maria in #12")}));
    QCOMPARE(note.totalItems, 3);
  }

  void githubBoilerplateIsLeftOut() {
    const auto note = only(QStringLiteral("## What's Changed\n"
                                          "* Fix the sidebar\n"
                                          "Compare: https://github.com/hal-c2/hal-c2/compare/a...b\n"
                                          "## New Contributors\n"
                                          "* @maria made their first contribution\n"
                                          "**Full Changelog**: https://github.com/hal-c2/hal-c2/compare/v1...v2\n"));
    QCOMPARE(note.items, QStringList{QStringLiteral("Fix the sidebar")});
  }

  void aLongChangeIsCutAt220Characters() {
    const auto note = only(QStringLiteral("- ") + QString(240, u'a'));
    QCOMPARE(note.items.value(0), QString(217, u'a') + QStringLiteral("..."));
  }

  void theLastEightChangesAreKeptNewestFirst() {
    QStringList lines;
    for (int i = 1; i <= 10; ++i) lines.append(QStringLiteral("- Change %1").arg(i));
    const auto note = only(lines.join(u'\n'));
    QCOMPARE(note.totalItems, 10);
    QCOMPARE(note.items.size(), 8);
    QCOMPARE(note.items.first(), QStringLiteral("Change 10"));
    QCOMPARE(note.items.last(), QStringLiteral("Change 3"));
  }

  void releasesWithNothingToListAndOtherTracksAreLeftOut() {
    const desktopUpdate::Notes notes = normalizeReleaseNotes({{nightly(3), QStringLiteral("- Third")},
                                                              {QStringLiteral("1.4.0-preview.1"), QStringLiteral("- Preview")},
                                                              {nightly(2), QStringLiteral("## What's Changed\n")}},
                                                             kNightly);
    QCOMPARE(notes.releaseNotes.size(), 1);
    QCOMPARE(notes.releaseNotes.first().version, nightly(3));
    QCOMPARE(notes.omittedReleaseCount, 0);
  }

  void atMostSixReleasesAreShownAndTheRestCounted() {
    QList<desktopUpdate::NoteSource> sources;
    for (int day = 10; day > 0; --day) sources.append({nightly(day), QStringLiteral("- Change on %1").arg(day)});
    const desktopUpdate::Notes notes = normalizeReleaseNotes(sources, kNightly);
    QCOMPARE(notes.releaseNotes.size(), 6);
    QCOMPARE(notes.releaseNotes.first().version, nightly(10));
    QCOMPARE(notes.omittedReleaseCount, 4);
  }
};

QTEST_GUILESS_MAIN(ReleaseNotesTest)
#include "tst_ReleaseNotes.moc"
