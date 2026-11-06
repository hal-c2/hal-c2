#pragma once

#include <QJsonObject>
#include <QList>

#include "SubscriptionWidget.h"

// The phone's home screen as far as the Subscription usage widget goes
// (src/SubscriptionWidget.h): how many the user placed, and every snapshot
// the app gave them, which is what UsageWidget.java draws. It outlives the
// app, as the home screen does: one a scenario.
class FakeWidgetSystem : public WidgetSystem {
public:
  int count = 0;
  QList<QJsonObject> shown;

  int placed() override { return count; }
  void show(const QJsonObject& snapshot) override { shown.append(snapshot); }
  // What the widget draws now.
  QJsonObject drawn() const { return shown.isEmpty() ? QJsonObject() : shown.last(); }
};
