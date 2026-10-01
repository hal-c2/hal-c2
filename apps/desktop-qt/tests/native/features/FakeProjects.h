#pragma once

#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QString>

// What the fake MC's `projects.mutate` saw (ProjectSteps.cpp), and the
// error it answers with: `refusal` everywhere, `refusedOn` on one
// environment. Linked environments' projects are their link rows.
struct FakeProjects {
  QList<QJsonObject> mutations;
  QString refusal;
  QHash<QString, QString> refusedOn;
};
