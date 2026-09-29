// Runs the desktop shell's native scenarios (the @desktop and @shared ones in
// the files kDefaultGlobs names) against a fake protocol-3 node: a small
// Gherkin reader, the step definitions the files in features/ register
// (Harness.h), and one QTest row per scenario.
// HAL_C2_FEATURES narrows the run to other globs under features/ (space
// separated). A glob may name scenarios after a colon, for a file whose other
// scenarios the shell does not deliver itself: `navigation/appearance.feature:System*`.

#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QGuiApplication>
#include <QMap>
#include <QRegularExpression>
#include <QTest>

#include <algorithm>
#include <ctime>
#include <optional>

#include "features/Harness.h"
#include "features/World.h"

namespace {

struct Definition {
  QRegularExpression pattern;
  StepFn run;
};

QList<Definition>& definitions() {
  static QList<Definition> list;
  return list;
}

QList<void (*)()>& stepFiles() {
  static QList<void (*)()> list;
  return list;
}

// ---- Gherkin ---------------------------------------------------------------

QStringList tableCells(const QString& line) {
  QStringList cells = line.trimmed().split(QLatin1Char('|'));
  cells.removeFirst();
  cells.removeLast();
  for (QString& cell : cells) cell = cell.trimmed();
  return cells;
}

// Enough Gherkin for this repo: tags, Feature, Rule, Background, Scenario,
// Scenario Outline with Examples, and data tables. Doc strings are not used.
QList<Scenario> parseFeature(const QString& path) {
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) qFatal("cannot read %s", qPrintable(path));
  const QStringList lines = QString::fromUtf8(file.readAll()).split(QLatin1Char('\n'));

  QList<Scenario> scenarios;
  QStringList pendingTags, featureTags, ruleTags;
  QList<Step> featureBackground, ruleBackground;
  QList<Step>* steps = nullptr;
  bool inRule = false;

  struct Current {
    QString name;
    QStringList tags;
    QList<Step> steps;
    bool outline = false;
    QList<std::pair<QStringList, Table>> examples;  // tags, header + rows
  };
  std::optional<Current> current;
  Table* examples = nullptr;
  bool outcome = false;

  const auto flush = [&] {
    if (!current) return;
    const QList<Step> background = featureBackground + ruleBackground;
    if (!current->outline) {
      scenarios.append({path, current->name, current->tags, background + current->steps});
    }
    for (const auto& [exampleTags, table] : current->examples) {
      if (table.isEmpty()) continue;
      const QStringList& header = table.first();
      for (qsizetype row = 1; row < table.size(); ++row) {
        const auto substitute = [&](QString text) {
          for (qsizetype column = 0; column < header.size(); ++column) {
            text.replace(QLatin1Char('<') + header.at(column) + QLatin1Char('>'), table.at(row).value(column));
          }
          return text;
        };
        QList<Step> expanded = background;
        for (Step step : current->steps) {
          step.text = substitute(step.text);
          for (QStringList& cells : step.table) {
            for (QString& cell : cells) cell = substitute(cell);
          }
          expanded.append(step);
        }
        scenarios.append({path, current->name + QStringLiteral(" [") + table.at(row).join(QStringLiteral(", ")) +
                                    QLatin1Char(']'),
                          current->tags + exampleTags, expanded});
      }
    }
    current.reset();
  };

  static const QRegularExpression stepKeyword(QStringLiteral("^(Given|When|Then|And|But|\\*)\\s+(.*)$"));
  for (qsizetype index = 0; index < lines.size(); ++index) {
    const QString line = lines.at(index).trimmed();
    if (line.isEmpty() || line.startsWith(QLatin1Char('#'))) continue;
    if (line.startsWith(QLatin1Char('@'))) {
      pendingTags += line.split(QRegularExpression(QStringLiteral("\\s+")), Qt::SkipEmptyParts);
      continue;
    }
    if (line.startsWith(QLatin1String("Feature:"))) {
      featureTags = std::exchange(pendingTags, {});
      steps = nullptr;
    } else if (line.startsWith(QLatin1String("Rule:"))) {
      flush();
      inRule = true;
      ruleTags = std::exchange(pendingTags, {});
      ruleBackground.clear();
      steps = nullptr;
    } else if (line.startsWith(QLatin1String("Background:"))) {
      flush();
      steps = inRule ? &ruleBackground : &featureBackground;
      examples = nullptr;
    } else if (line.startsWith(QLatin1String("Scenario Outline:")) ||
               line.startsWith(QLatin1String("Scenario Template:")) || line.startsWith(QLatin1String("Scenario:")) ||
               line.startsWith(QLatin1String("Example:"))) {
      flush();
      const qsizetype colon = line.indexOf(QLatin1Char(':'));
      current = Current{line.mid(colon + 1).trimmed(), featureTags + ruleTags + std::exchange(pendingTags, {}), {},
                        line.startsWith(QLatin1String("Scenario Outline:")) ||
                            line.startsWith(QLatin1String("Scenario Template:")),
                        {}};
      steps = &current->steps;
      examples = nullptr;
    } else if (line.startsWith(QLatin1String("Examples:")) || line.startsWith(QLatin1String("Scenarios:"))) {
      current->examples.append({std::exchange(pendingTags, {}), {}});
      examples = &current->examples.last().second;
      steps = nullptr;
    } else if (line.startsWith(QLatin1Char('|'))) {
      if (examples) {
        examples->append(tableCells(line));
      } else if (steps && !steps->isEmpty()) {
        steps->last().table.append(tableCells(line));
      }
    } else if (const auto match = stepKeyword.match(line); match.hasMatch() && steps) {
      const QString keyword = match.captured(1);
      if (keyword != QLatin1String("And") && keyword != QLatin1String("But")) outcome = keyword == QLatin1String("Then");
      steps->append({match.captured(2), {}, static_cast<int>(index + 1), outcome});
    }
    // Anything else is a description.
  }
  flush();
  return scenarios;
}

// ---- Running ----------------------------------------------------------------

void runStep(World& world, const Step& step) {
  const Definition* found = nullptr;
  QRegularExpressionMatch match;
  for (const Definition& definition : definitions()) {
    QRegularExpressionMatch candidate = definition.pattern.match(step.text);
    if (!candidate.hasMatch()) continue;
    if (found) fail(QStringLiteral("ambiguous step: ") + step.text);
    found = &definition;
    match = candidate;
  }
  if (!found) fail(QStringLiteral("undefined step: ") + step.text);
  world.checking = step.outcome;
  Captures captures = match.capturedTexts();
  captures.removeFirst();
  found->run(world, captures, step.table);
}

const QStringList kDefaultGlobs{
    QStringLiteral("desktop/native-*.feature"),
    QStringLiteral("connections/cluster.feature"),
    QStringLiteral("timeline/streaming.feature"),
    QStringLiteral("timeline/tool-calls.feature"),
    QStringLiteral("timeline/runs-and-queue.feature"),
    QStringLiteral("timeline/plans-and-subagents.feature"),
    QStringLiteral("navigation/environment-themes.feature"),
    QStringLiteral("navigation/appearance.feature:System appearance follows*"),
    QStringLiteral("navigation/appearance.feature:Choosing an appearance mode*"),
    QStringLiteral("navigation/appearance.feature:The appearance shortcut cycles*"),
    QStringLiteral("navigation/appearance.feature:Choosing a theme"),
    QStringLiteral("navigation/appearance.feature:Different themes for light and dark"),
    QStringLiteral("navigation/appearance.feature:A theme with only one appearance*"),
    QStringLiteral("navigation/appearance.feature:A theme choice that cannot be saved*"),
    QStringLiteral("navigation/appearance.feature:An appearance setting can be put back*"),
    QStringLiteral("navigation/appearance.feature:A font preference can be reset*"),
    QStringLiteral("navigation/appearance.feature:Clearing *"),
    QStringLiteral("navigation/theme-editor.feature"),
    QStringLiteral("settings/general.feature"),
    QStringLiteral("settings/saving-settings.feature"),
    QStringLiteral("timeline/approvals-and-questions.feature"),
    QStringLiteral("composer/question-answers.feature:A question can be dismissed*"),
    QStringLiteral("composer/question-answers.feature:A proposed plan is implemented*"),
    QStringLiteral("composer/queue-and-steer.feature:The follow-up setting decides*"),
    QStringLiteral("composer/queue-and-steer.feature:Stopping the running turn*"),
    QStringLiteral("composer/queue-and-steer.feature:A shortcut bound to stop*"),
    QStringLiteral("composer/queue-and-steer.feature:Queued messages are listed*"),
    QStringLiteral("composer/queue-and-steer.feature:Removing a queued message cancels its run*"),
    QStringLiteral("composer/queue-and-steer.feature:A removal the node refuses*"),
    QStringLiteral("composer/queue-and-steer.feature:A queued message can steer*"),
    QStringLiteral("composer/queue-and-steer.feature:A steer the node refuses*"),
    QStringLiteral("composer/drafting-and-sending.feature:Each thread keeps its own draft*"),
    QStringLiteral("composer/drafting-and-sending.feature:Sending while disconnected*"),
    QStringLiteral("composer/drafting-and-sending.feature:A send the node rejects*"),
    QStringLiteral("composer/sending-turns.feature"),
    QStringLiteral("navigation/toasts.feature"),
    QStringLiteral("settings/connections.feature"),
    QStringLiteral("connections/links.feature"),
    QStringLiteral("connections/pairing.feature"),
    QStringLiteral("threads/drafts.feature"),
    QStringLiteral("threads/menu-actions.feature"),
    QStringLiteral("threads/thread-list.feature"),
    QStringLiteral("terminal/drawer.feature"),
    QStringLiteral("threads/creating.feature:A new thread start*"),
    QStringLiteral("threads/creating.feature:Starting a thread from another thread's branch"),
    QStringLiteral("threads/menu-and-selection.feature:Opening a thread's menu"),
    QStringLiteral("threads/menu-and-selection.feature:The thread menu offers*"),
    QStringLiteral("threads/menu-and-selection.feature:Actions the environment does not support*"),
    QStringLiteral("threads/menu-and-selection.feature:Copying details of a thread confirms*"),
    QStringLiteral("threads/menu-and-selection.feature:Copying a path that is missing*"),
    QStringLiteral("threads/menu-and-selection.feature:A failed copy*"),
    QStringLiteral("threads/menu-and-selection.feature:Copying a thread reference*"),
    QStringLiteral("threads/menu-and-selection.feature:Filtering the list*"),
    QStringLiteral("threads/menu-and-selection.feature:Opening a thread's project settings"),
    QStringLiteral("threads/archive-delete.feature:Archiving waits for the agent*"),
    QStringLiteral("threads/archive-delete.feature:Archiving asks first*"),
    QStringLiteral("threads/archive-delete.feature:Deleting from the desktop and phone asks*"),
    QStringLiteral("threads/archive-delete.feature:Deleting the open thread opens the next*"),
    QStringLiteral("threads/pinning-and-order.feature:Pinned threads are listed above*"),
    QStringLiteral("threads/pinning-and-order.feature:Pinning a thread"),
    QStringLiteral("threads/pinning-and-order.feature:Unpinning a thread"),
    QStringLiteral("threads/pinning-and-order.feature:Unpinning asks first*"),
    QStringLiteral("threads/pinning-and-order.feature:Undoing a thread change*"),
    QStringLiteral("threads/pinning-and-order.feature:Undo reopens an archived thread*"),
    QStringLiteral("threads/pinning-and-order.feature:The undo offer expires"),
    QStringLiteral("threads/creating.feature:A new worktree needs a base branch"),
    QStringLiteral("threads/creating.feature:A thread cannot start from an empty task"),
    QStringLiteral("composer/drafting-and-sending.feature:The first message of a new thread creates*"),
    QStringLiteral("threads/sidebar-list.feature:Projects *"),
    QStringLiteral("threads/sidebar-list.feature:Threads started by other agents*"),
    QStringLiteral("threads/sidebar-list.feature:Threads on an offline environment*"),
    QStringLiteral("files/adding-projects.feature:Adding a folder from the desktop*"),
    QStringLiteral("files/adding-projects.feature:Adding an existing project from the desktop*"),
    QStringLiteral("files/adding-projects.feature:A folder the environment refuses*"),
    QStringLiteral("files/adding-projects.feature:Dropping a folder *"),
    QStringLiteral("files/removing-and-listing-projects.feature:Removing *"),
    QStringLiteral("files/removing-and-listing-projects.feature:Confirming removal*"),
    QStringLiteral("files/removing-and-listing-projects.feature:Cancelling removal*"),
    QStringLiteral("files/removing-and-listing-projects.feature:A removal the environment refuses*"),
    QStringLiteral("threads/titles.feature"),
    QStringLiteral("source-control/refs-and-branches.feature"),
    QStringLiteral("source-control/worktrees-and-setup-scripts.feature"),
    // The desktop's git actions (GitController); the rest of these files is the node's and the TUI's.
    QStringLiteral("source-control/git-actions.feature:The recommended action*"),
    QStringLiteral("source-control/git-actions.feature:A detached checkout*"),
    QStringLiteral("source-control/git-actions.feature:A repository without a remote*"),
    QStringLiteral("source-control/git-actions.feature:A menu entry that cannot run*"),
    QStringLiteral("source-control/git-actions.feature:Opening the pull request of the branch"),
    QStringLiteral("source-control/git-actions.feature:Opening the git menu refreshes status"),
    QStringLiteral("source-control/git-actions.feature:The actions use the host's own name*"),
    QStringLiteral("source-control/git-actions.feature:A new pull request can be viewed*"),
    QStringLiteral("source-control/git-actions.feature:An action with nothing to do*"),
    QStringLiteral("source-control/git-actions.feature:Initializing Git"),
    QStringLiteral("source-control/git-actions.feature:A refused initialization*"),
    QStringLiteral("source-control/git-actions.feature:A link that is down*"),
    QStringLiteral("source-control/git-actions.feature:Publishing pushes*"),
    QStringLiteral("source-control/git-actions.feature:A refused publish*"),
    QStringLiteral("source-control/git-actions.feature:A repository name needs*"),
    QStringLiteral("source-control/git-actions.feature:Cancelling the dialog publishes nothing"),
    QStringLiteral("source-control/push-pull-and-default-branch.feature:Pushing a branch that tracks an upstream"),
    QStringLiteral("source-control/push-pull-and-default-branch.feature:A finished action's result goes away*"),
    QStringLiteral("source-control/push-pull-and-default-branch.feature:Pulling fast-forwards the branch"),
    QStringLiteral("source-control/push-pull-and-default-branch.feature:A refused pull is reported"),
    QStringLiteral("source-control/push-pull-and-default-branch.feature:Actions that would land on the default branch ask first ?Push?"),
    QStringLiteral("source-control/push-pull-and-default-branch.feature:Actions that would land on the default branch ask first ?Create PR?"),
    QStringLiteral("source-control/push-pull-and-default-branch.feature:Actions that would land on the default branch ask first ?Commit & push?"),
    QStringLiteral("source-control/push-pull-and-default-branch.feature:Continuing on the default branch"),
    QStringLiteral("source-control/push-pull-and-default-branch.feature:Aborting on the default branch"),
    QStringLiteral("source-control/push-pull-and-default-branch.feature:Moving the work onto a new branch instead"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:Committing with a message the user wrote"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:A blank message is written by the writer model"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:Committing only the files the user picked"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:Committing on a new branch"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:The progress toast names*"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:A failed action is reported"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:A commit offers to push it"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:A git action on a linked environment*"),
    QStringLiteral("files/project-scripts-and-actions.feature"),
    QStringLiteral("navigation/keybindings.feature"),
    QStringLiteral("navigation/keybinding-customisation.feature"),
    // The rest of this file is what the page shows (tst_KeybindingsSettings.qml).
    QStringLiteral("navigation/keybinding-settings.feature:Every command is listed*"),
    QStringLiteral("navigation/keybinding-settings.feature:Searching filters bindings*"),
    QStringLiteral("navigation/keybinding-settings.feature:Commands have readable names*"),
    QStringLiteral("navigation/keybinding-settings.feature:Recording a new shortcut*"),
    QStringLiteral("navigation/keybinding-settings.feature:A shortcut needs a modifier"),
    QStringLiteral("navigation/keybinding-settings.feature:Recorded modifiers follow the platform*"),
    QStringLiteral("navigation/keybinding-settings.feature:A malformed condition*"),
    QStringLiteral("navigation/keybinding-settings.feature:An unknown condition variable*"),
    QStringLiteral("navigation/keybinding-settings.feature:Conflicting bindings*"),
    QStringLiteral("navigation/keybinding-settings.feature:Resetting a custom binding*"),
    QStringLiteral("navigation/keybinding-settings.feature:Default bindings cannot be removed*"),
    QStringLiteral("navigation/keybinding-settings.feature:Removing a custom binding"),
    QStringLiteral("navigation/keybinding-settings.feature:Adding a binding for a command"),
    QStringLiteral("navigation/keybinding-settings.feature:Save failures are reported*"),
    QStringLiteral("source-control/checkpoint-diffs.feature"),
    QStringLiteral("timeline/checkpoints.feature"),
    QStringLiteral("files/file-explorer.feature"),
    QStringLiteral("files/file-viewer-and-editing.feature"),
    QStringLiteral("navigation/layout.feature:Opening and closing the right panel"),
    QStringLiteral("navigation/layout.feature:Switching between right panel tabs"),
    QStringLiteral("navigation/layout.feature:Closing a right panel tab"),
    QStringLiteral("navigation/layout.feature:Adding a tab to the right panel*"),
    QStringLiteral("navigation/layout.feature:A tab kind that the thread cannot show*"),
    QStringLiteral("navigation/layout.feature:Choosing the project in the header*"),
    QStringLiteral("navigation/layout.feature:The header names the project and thread"),
    QStringLiteral("navigation/layout.feature:The header opens the thread's workspace in another editor"),
    QStringLiteral("navigation/header.feature"),
};

QRegularExpression wildcard(const QString& glob) {
  return QRegularExpression::fromWildcard(glob, Qt::CaseSensitive, QRegularExpression::NonPathWildcardConversion);
}

QList<Scenario> collectScenarios() {
  const QDir root(QStringLiteral(HAL_C2_FEATURES_DIR));
  QStringList globs = kDefaultGlobs;
  if (const QString requested = qEnvironmentVariable("HAL_C2_FEATURES"); !requested.isEmpty()) {
    globs = requested.split(QLatin1Char(' '), Qt::SkipEmptyParts);
  }
  // Each file, with the scenario names wanted from it (none: all of them).
  QMap<QString, QList<QRegularExpression>> files;
  QDirIterator it(root.path(), {QStringLiteral("*.feature")}, QDir::Files, QDirIterator::Subdirectories);
  while (it.hasNext()) {
    const QString path = it.next();
    const QString relative = root.relativeFilePath(path);
    for (const QString& glob : globs) {
      const qsizetype colon = glob.indexOf(QLatin1Char(':'));
      if (!wildcard(glob.left(colon)).match(relative).hasMatch()) continue;
      QList<QRegularExpression>& names = files[path];
      if (colon < 0) {
        names.clear();
        break;
      }
      names.append(wildcard(glob.mid(colon + 1)));
    }
  }
  QList<Scenario> scenarios;
  for (auto file = files.cbegin(); file != files.cend(); ++file) {
    for (const Scenario& scenario : parseFeature(file.key())) {
      if (!file.value().isEmpty() && std::none_of(file.value().cbegin(), file.value().cend(), [&](const QRegularExpression& name) {
            return name.match(scenario.name).hasMatch();
          })) {
        continue;
      }
      // `@shared` is `@desktop @mobile @tui` (features/README.md).
      if (!scenario.tags.contains(QStringLiteral("@desktop")) && !scenario.tags.contains(QStringLiteral("@shared"))) continue;
      // Not delivered anywhere, dropped, or not on the desktop yet.
      if (scenario.tags.contains(QStringLiteral("@backlog")) || scenario.tags.contains(QStringLiteral("@dropped")) ||
          scenario.tags.contains(QStringLiteral("@backlog-desktop"))) {
        continue;
      }
      scenarios.append(scenario);
    }
  }
  return scenarios;
}

}  // namespace

void step(const QString& pattern, StepFn run) {
  definitions().append({QRegularExpression(QLatin1Char('^') + pattern + QLatin1Char('$')), std::move(run)});
}

Steps::Steps(void (*define)()) {
  stepFiles().append(define);
}

class tst_Features : public QObject {
  Q_OBJECT

private slots:
  void initTestCase() {
    for (const auto define : std::as_const(stepFiles())) define();
    m_scenarios = collectScenarios();
    QVERIFY2(!m_scenarios.isEmpty(), "no scenarios matched");
  }

  void scenarios_data() {
    QTest::addColumn<int>("index");
    const QDir root(QStringLiteral(HAL_C2_FEATURES_DIR));
    for (qsizetype index = 0; index < m_scenarios.size(); ++index) {
      const Scenario& scenario = m_scenarios.at(index);
      QTest::newRow(qPrintable(root.relativeFilePath(scenario.file) + QStringLiteral(": ") + scenario.name))
          << static_cast<int>(index);
    }
  }

  void scenarios() {
    QFETCH(int, index);
    const Scenario& scenario = m_scenarios.at(index);
    World world;
    for (const Step& step : scenario.steps) {
      try {
        runStep(world, step);
      } catch (const Failure& failure) {
        const QString message = QStringLiteral("%1:%2 %3\n  %4")
                                    .arg(QDir(QStringLiteral(HAL_C2_FEATURES_DIR)).relativeFilePath(scenario.file))
                                    .arg(step.line)
                                    .arg(step.text, QString::fromStdString(failure.what()));
        QFAIL(qPrintable(message));
      }
    }
  }

private:
  QList<Scenario> m_scenarios;
};

int main(int argc, char** argv) {
  // Snooze presets and wake labels are wall-clock times: pin them to UTC.
  qputenv("TZ", "UTC");
  tzset();
  QGuiApplication app(argc, argv);
  tst_Features test;
  return QTest::qExec(&test, argc, argv);
}

#include "tst_Features.moc"
