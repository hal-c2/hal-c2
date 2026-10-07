#include "ScriptedRun.h"

#include <QCommandLineParser>
#include <QCoreApplication>
#include <QJsonDocument>
#include <QTimer>
#include <QtLogging>

#include "ShellBridge.h"
#include "ShellRuntime.h"

namespace {

const QString kScreenshot = QStringLiteral("screenshot");
const QString kAction = QStringLiteral("action");
const QString kKey = QStringLiteral("key");

struct Step {
  bool isKey;
  QString spec;
};

// The --action and --key steps in the order they were given.
QList<Step> steps(const QCommandLineParser& parser) {
  QList<Step> found;
  QStringList actions = parser.values(kAction);
  QStringList keys = parser.values(kKey);
  for (const QString& name : parser.optionNames()) {
    if (name == kAction) {
      found.append({false, actions.takeFirst()});
    } else if (name == kKey) {
      found.append({true, keys.takeFirst()});
    }
  }
  return found;
}

}  // namespace

namespace ScriptedRun {

void addOptions(QCommandLineParser& parser) {
  parser.addOptions({
      {kScreenshot, QStringLiteral("Write a PNG of the window once the MC's first snapshot is in, then quit."),
       QStringLiteral("file")},
      {kAction,
       QStringLiteral("Dispatch a shell action once the MC's first snapshot is in, e.g. rightPanel.toggle. "
                      "Repeatable; runs in order."),
       QStringLiteral("name[=json]")},
      {kKey,
       QStringLiteral("Press a key chord once the MC's first snapshot is in, e.g. Ctrl+1 (portable QKeySequence "
                      "names). Repeatable; runs in command-line order together with --action."),
       QStringLiteral("chord")},
  });
}

bool screenshotRequested(const QCommandLineParser& parser) {
  return parser.isSet(kScreenshot);
}

bool requested(const QCommandLineParser& parser) {
  return screenshotRequested(parser) || parser.isSet(kAction) || parser.isSet(kKey);
}

void play(const QCommandLineParser& parser, ShellRuntime* runtime, ShellBridge* bridge) {
  int delay = 1500;
  for (const Step& step : steps(parser)) {
    if (step.isKey) {
      QTimer::singleShot(delay, runtime, [runtime, step] {
        qInfo().noquote() << "[shell] scripted key" << step.spec;
        runtime->pressKey(step.spec);
      });
      delay += 1500;
      continue;
    }
    const QString spec = step.spec;
    QTimer::singleShot(delay, bridge, [bridge, spec] {
      const int eq = spec.indexOf(QLatin1Char('='));
      const QString name = eq < 0 ? spec : spec.left(eq);
      QVariant payload;
      if (eq >= 0) {
        payload = QJsonDocument::fromJson(spec.mid(eq + 1).toUtf8()).toVariant();
      }
      qInfo().noquote() << "[shell] scripted action" << name;
      bridge->dispatch(name, payload);
    });
    delay += 1500;
  }
  if (screenshotRequested(parser)) {
    const QString target = parser.value(kScreenshot);
    QTimer::singleShot(delay + 1500, runtime, [runtime, target] {
      const bool ok = runtime->captureWindow(target);
      QCoreApplication::exit(ok ? 0 : 2);
    });
  }
}

void captureFailure(const QCommandLineParser& parser, ShellRuntime* runtime) {
  const QString target = parser.value(kScreenshot);
  QTimer::singleShot(1500, runtime, [runtime, target] {
    runtime->captureWindow(target);
    QCoreApplication::exit(2);
  });
}

}  // namespace ScriptedRun
