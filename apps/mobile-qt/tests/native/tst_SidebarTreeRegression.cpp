// What tests/prop/tst_SidebarTreeProp.cpp found in the legacy sidebar's tree.

#include <QtTest>

#include "SidebarModel.h"

class SidebarTreeRegression : public QObject {
  Q_OBJECT
private slots:
  // A dragged folder that is also the target's first left fewer folders than
  // the place it was put at: the insert ran past the end and aborted. It
  // appends now, as the web's splice did.
  void draggedFolderIsTheTargets() {
    const QStringList order{QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c")};
    const QStringList next = sidebar::reorderProjects(order, {QStringLiteral("a"), QStringLiteral("c")}, {QStringLiteral("c")});
    QCOMPARE(next, (QStringList{QStringLiteral("b"), QStringLiteral("a"), QStringLiteral("c")}));
  }
};

QTEST_GUILESS_MAIN(SidebarTreeRegression)
#include "tst_SidebarTreeRegression.moc"
