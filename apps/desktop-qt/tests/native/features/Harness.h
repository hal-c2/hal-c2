#pragma once

// What a steps file needs from tst_Features: Gherkin's shapes, failing a step,
// and registering step definitions. Each domain's steps live in their own file
// in this directory and register themselves:
//
//   namespace {
//   const Steps steps([] {
//     step(QStringLiteral("the user does %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
//       ...
//     });
//   });
//   }  // namespace

#include <QJsonDocument>
#include <QList>
#include <QString>
#include <QStringList>
#include <QVariant>

#include <functional>
#include <stdexcept>

class World;

using Table = QList<QStringList>;

struct Step {
  QString text;
  Table table;
  int line = 0;
};

struct Scenario {
  QString file;
  QString name;
  QStringList tags;
  QList<Step> steps;
};

struct Failure : std::runtime_error {
  using std::runtime_error::runtime_error;
};

[[noreturn]] inline void fail(const QString& message) {
  throw Failure(message.toStdString());
}

inline void expect(bool condition, const QString& message) {
  if (!condition) fail(message);
}

inline QString show(const QVariant& value) {
  return QString::fromUtf8(QJsonDocument::fromVariant(value).toJson(QJsonDocument::Compact));
}

// `a.b.c` into nested maps.
inline QVariant at(const QVariant& value, const QString& path) {
  QVariant current = value;
  for (const QString& part : path.split(QLatin1Char('.'))) current = current.toMap().value(part);
  return current;
}

// A quoted capture: `"([^"]*)"`.
inline const QString kQuoted = QStringLiteral("\"([^\"]*)\"");

using Captures = QStringList;
using StepFn = std::function<void(World&, const Captures&, const Table&)>;

// A step matching the whole of `pattern` (a regular expression). Two
// definitions matching one step fail it as ambiguous.
void step(const QString& pattern, StepFn run);

// Registers a steps file's definitions; tst_Features runs `define` once, before
// the scenarios.
struct Steps {
  explicit Steps(void (*define)());
};
