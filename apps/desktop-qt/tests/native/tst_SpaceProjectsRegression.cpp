// What tests/prop/tst_SpaceProjectsProp.cpp found in SpaceProjects.

#include <QtTest>

#include "SpaceController.h"

class SpaceProjectsRegression : public QObject {
  Q_OBJECT

private slots:
  // A restore that forgot folders the listing lacks said nothing, so the device kept
  // them until the next toggle.
  void aRestoreThatForgetsFoldersSaysSo() {
    SpaceProjects projects;
    projects.setProjects({{QStringLiteral("alpha"), QStringLiteral("Alpha")}});
    projects.setFiles(QStringLiteral("alpha"), {{QStringLiteral("docs/a.md"), QStringLiteral("page-a")}});
    QSignalSpy changed(&projects, &SpaceProjects::expandedChanged);
    projects.restoreExpanded({QStringLiteral("alpha")},
                             {{QStringLiteral("alpha"), QStringList{QStringLiteral("docs"), QStringLiteral("gone")}}});
    QCOMPARE(changed.count(), 1);
    const QVariantMap kept{{QStringLiteral("alpha"), QStringList{QStringLiteral("docs")}}};
    QCOMPARE(projects.expandedFolders(), kept);
  }

  // Restoring what the listing has forgets nothing and says nothing back.
  void aRestoreThatForgetsNothingIsQuiet() {
    SpaceProjects projects;
    projects.setProjects({{QStringLiteral("alpha"), QStringLiteral("Alpha")}});
    projects.setFiles(QStringLiteral("alpha"), {{QStringLiteral("docs/a.md"), QStringLiteral("page-a")}});
    QSignalSpy changed(&projects, &SpaceProjects::expandedChanged);
    projects.restoreExpanded({QStringLiteral("alpha")}, {{QStringLiteral("alpha"), QStringList{QStringLiteral("docs")}}});
    QCOMPARE(changed.count(), 0);
  }
};

QTEST_GUILESS_MAIN(SpaceProjectsRegression)
#include "tst_SpaceProjectsRegression.moc"
