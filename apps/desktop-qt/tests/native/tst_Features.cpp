// Runs the desktop shell's native scenarios (the @desktop and @shared ones in
// the files kDefaultGlobs names) against a fake protocol-3 MC: a small
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
  // A cell's own bar is written `\|`.
  static const QString escaped = QStringLiteral("\\|");
  static const QChar placeholder(0xE000);
  QStringList cells = line.trimmed().replace(escaped, placeholder).split(QLatin1Char('|'));
  cells.removeFirst();
  cells.removeLast();
  for (QString& cell : cells) cell = cell.trimmed().replace(placeholder, QLatin1Char('|'));
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
    QStringLiteral("timeline/markdown.feature"),
    QStringLiteral("timeline/scrolling-and-links.feature:A bare web address*"),
    QStringLiteral("timeline/scrolling-and-links.feature:A long thread opens*"),
    QStringLiteral("timeline/scrolling-and-links.feature:Earlier turns load*"),
    QStringLiteral("timeline/scrolling-and-links.feature:A thread that does not fill*"),
    QStringLiteral("connections/local-cache.feature"),
    QStringLiteral("timeline/scrolling-and-links.feature:The user cites part of a reply*"),
    QStringLiteral("navigation/environment-themes.feature"),
    QStringLiteral("navigation/windows.feature:The window title follows*"),
    QStringLiteral("navigation/windows.feature:A second window works on its own"),
    QStringLiteral("navigation/windows.feature:Closing a second window leaves the first alone"),
    QStringLiteral("navigation/windows.feature:Every window shows a backend failure"),
    QStringLiteral("navigation/windows.feature:A setting that fails to save*"),
    QStringLiteral("navigation/windows.feature:Closing the first window leaves the others open"),
    QStringLiteral("navigation/windows.feature:Closing the last window quits"),
    QStringLiteral("navigation/windows.feature:Closing a window keeps its unsent work"),
    QStringLiteral("navigation/windows.feature:Closing a window while it waits on the MC"),
    QStringLiteral("navigation/windows.feature:Windows share the sign-in but not the navigation"),
    QStringLiteral("navigation/windows.feature:A window restores its drafts and panels after a restart"),
    QStringLiteral("navigation/windows.feature:A window keeps its files in its own folder"),
    QStringLiteral("navigation/windows.feature:A restart skips a saved window that names another folder"),
    QStringLiteral("navigation/windows.feature:The settings shortcut opens settings"),
    QStringLiteral("navigation/windows.feature:Zooming the app*"),
    QStringLiteral("navigation/windows.feature:Actual size undoes the zoom"),
    QStringLiteral("navigation/windows.feature:Every window follows the app's zoom"),
    QStringLiteral("navigation/windows.feature:Holding the quit shortcut quits"),
    QStringLiteral("navigation/windows.feature:Pressing the quit shortcut twice quits"),
    QStringLiteral("navigation/windows.feature:A single quick press does not quit"),
    QStringLiteral("navigation/windows.feature:Double press mode asks for a second press"),
    QStringLiteral("navigation/windows.feature:Direct mode quits on one press"),
    QStringLiteral("navigation/windows.feature:Quit from the command palette is immediate"),
    QStringLiteral("navigation/focus.feature:Leaving settings goes back to the thread"),
    QStringLiteral("navigation/focus.feature:The palette keeps focus while it is open"),
    QStringLiteral("navigation/command-palette.feature"),
    QStringLiteral("navigation/welcome-wizard.feature"),
    QStringLiteral("threads/search.feature:Searching from the thread list opens the command palette"),
    QStringLiteral("settings/search-and-navigation.feature:Leaving settings returns*"),
    QStringLiteral("settings/search-and-navigation.feature:Moving between sections is one step back"),
    QStringLiteral("settings/search-and-navigation.feature:Back with nowhere to return to*"),
    QStringLiteral("settings/search-and-navigation.feature:A search result inside a folded section*"),
    QStringLiteral("settings/search-and-navigation.feature:The page names where the user is"),
    QStringLiteral("settings/search-and-navigation.feature:Device-only sections*"),
    QStringLiteral("settings/search-and-navigation.feature:Moving between sections keeps*"),
    QStringLiteral("settings/search-and-navigation.feature:The slash key*"),
    QStringLiteral("settings/search-and-navigation.feature:Results are ranked*"),
    QStringLiteral("settings/search-and-navigation.feature:Opening the same result again*"),
    QStringLiteral("settings/search-and-navigation.feature:Restoring defaults lists*"),
    QStringLiteral("settings/search-and-navigation.feature:Confirming the restore*"),
    QStringLiteral("settings/search-and-navigation.feature:Cancelling the restore*"),
    QStringLiteral("settings/search-and-navigation.feature:A theme that cannot be restored*"),
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
    QStringLiteral("navigation/appearance.feature:Holding the appearance shortcut*"),
    QStringLiteral("navigation/appearance.feature:The theme shortcut opens*"),
    QStringLiteral("navigation/appearance.feature:Interface sliders*"),
    QStringLiteral("navigation/appearance.feature:Diff colors*"),
    QStringLiteral("navigation/appearance.feature:Font smoothing*"),
    QStringLiteral("navigation/appearance.feature:Composer context*"),
    QStringLiteral("navigation/appearance.feature:Word wrap*"),
    QStringLiteral("navigation/appearance.feature:Font preferences*"),
    QStringLiteral("navigation/appearance.feature:The environment can be identified*"),
    QStringLiteral("navigation/appearance.feature:Panel animations*"),
    QStringLiteral("navigation/appearance.feature:Switching threads never*"),
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
    QStringLiteral("composer/queue-and-steer.feature:A removal the MC refuses*"),
    QStringLiteral("composer/queue-and-steer.feature:A queued message can steer*"),
    QStringLiteral("composer/queue-and-steer.feature:A steer the MC refuses*"),
    QStringLiteral("composer/queue-and-steer.feature:Editing the last queued message*"),
    QStringLiteral("composer/queue-and-steer.feature:Saving an edited queued message*"),
    QStringLiteral("composer/queue-and-steer.feature:An edit the MC refuses*"),
    QStringLiteral("composer/queue-and-steer.feature:An edit whose message starts running*"),
    QStringLiteral("composer/queue-and-steer.feature:Leaving the thread ends the edit"),
    QStringLiteral("composer/context-references.feature:A terminal excerpt*"),
    QStringLiteral("composer/context-references.feature:A removed terminal excerpt*"),
    QStringLiteral("composer/context-references.feature:A send the MC rejects gives its terminal excerpt back"),
    QStringLiteral("composer/context-references.feature:Part of an assistant response can be quoted*"),
    QStringLiteral("composer/context-references.feature:A quoted response is sent*"),
    QStringLiteral("composer/context-references.feature:A stashed quote*"),
    QStringLiteral("terminal/composer-context.feature:The user adds selected terminal output*"),
    QStringLiteral("terminal/composer-context.feature:A one-line selection*"),
    QStringLiteral("terminal/composer-context.feature:Selecting only blank lines*"),
    QStringLiteral("terminal/composer-context.feature:The draft lists its terminal excerpts"),
    QStringLiteral("terminal/composer-context.feature:The user removes a terminal excerpt*"),
    QStringLiteral("terminal/composer-context.feature:Adding to chat is not offered*"),
    QStringLiteral("terminal/composer-context.feature:The terminal's menu offers*"),
    QStringLiteral("terminal/composer-context.feature:An excerpt whose text is gone*"),
    QStringLiteral("composer/drafting-and-sending.feature:Each thread keeps its own draft*"),
    QStringLiteral("composer/drafting-and-sending.feature:Sending while disconnected*"),
    QStringLiteral("composer/drafting-and-sending.feature:A send the MC rejects*"),
    QStringLiteral("composer/sending-turns.feature"),
    QStringLiteral("composer/editors-and-keys.feature"),
    QStringLiteral("composer/drafting-and-sending.feature:A background prompt*"),
    QStringLiteral("composer/drafting-and-sending.feature:Enter sends*"), QStringLiteral("composer/drafting-and-sending.feature:Shift+Enter*"), QStringLiteral("composer/drafting-and-sending.feature:The send shortcut*"), QStringLiteral("composer/drafting-and-sending.feature:mod+alt+Enter*"), QStringLiteral("composer/drafting-and-sending.feature:Switching threads before*"), QStringLiteral("composer/qt-scenarios.feature"), QStringLiteral("composer/drafting-and-sending.feature:One prompt starts a thread*"), QStringLiteral("composer/model-and-mode.feature:A new thread can run on a machine*"), QStringLiteral("composer/qt-shell-backlog.feature"), QStringLiteral("composer/question-answers.feature:Files can be attached*"), QStringLiteral("composer/question-answers.feature:A question with only fixed choices*"), QStringLiteral("composer/question-answers.feature:A failed answer*"), QStringLiteral("composer/model-and-mode.feature:Ultrathink*"), QStringLiteral("composer/model-and-mode.feature:The last model used*"), QStringLiteral("composer/model-and-mode.feature:New threads start with the default permissions"), QStringLiteral("composer/model-and-mode.feature:The user chooses which environment*"), QStringLiteral("composer/model-and-mode.feature:The user chooses to work in*"), QStringLiteral("composer/model-and-mode.feature:A branch that does not exist*"), QStringLiteral("composer/model-and-mode.feature:New worktree mode needs*"), QStringLiteral("composer/attachments.feature"), QStringLiteral("composer/drafting-and-sending.feature:A message over the character limit*"), QStringLiteral("composer/model-and-mode.feature:Searching the models*"), QStringLiteral("composer/model-and-mode.feature:A model that cannot be used*"), QStringLiteral("composer/model-and-mode.feature:The user chooses a model with the keyboard"), QStringLiteral("composer/model-and-mode.feature:The user moves between providers*"), QStringLiteral("composer/model-and-mode.feature:The user jumps to a model*"), QStringLiteral("composer/model-and-mode.feature:The model picker shortcut*"),
    QStringLiteral("composer/model-and-mode.feature:The user switches the model*"),
    QStringLiteral("composer/model-and-mode.feature:Models from unavailable providers*"),
    QStringLiteral("composer/model-and-mode.feature:Models are grouped by provider"),
    QStringLiteral("composer/model-and-mode.feature:The chosen model is shown*"),
    QStringLiteral("composer/model-and-mode.feature:The user sets the reasoning effort*"),
    QStringLiteral("composer/model-and-mode.feature:The user sets what the agent may do*"),
    QStringLiteral("composer/model-and-mode.feature:Unavailable providers stay listed*"),
    QStringLiteral("composer/model-and-mode.feature:Favourite models are listed first*"),
    QStringLiteral("composer/model-and-mode.feature:A thread's provider is locked*"),
    QStringLiteral("navigation/toasts.feature"),
    QStringLiteral("preview/devices.feature"),
    QStringLiteral("preview/remote.feature"),
    QStringLiteral("plugins/ui-plugins.feature"),
    QStringLiteral("plugins/plugin-catalog.feature"),
    QStringLiteral("plugins/keymaps.feature"),
    QStringLiteral("navigation/qt-shell-backlog.feature:A device tab streams a device screen"),
    QStringLiteral("navigation/qt-shell-backlog.feature:Opening a folder*"),
    QStringLiteral("desktop/shell-host.feature:A screenshot taken without a display shows the app's window"),
    QStringLiteral("desktop/shell-host.feature:A screenshot of a desktop app that fails to start*"),
    QStringLiteral("navigation/qt-shell-backlog.feature:The previous worktree shortcut works in the native composer"),
    QStringLiteral("navigation/qt-shell-backlog.feature:Thread number shortcuts work in the native desktop shell"),
    // The alerts themselves; the in-app card's own clicks are tst_Scenarios.qml's.
    QStringLiteral("timeline/notifications.feature:A thread that changes state*"),
    QStringLiteral("timeline/notifications.feature:Threads *"),
    QStringLiteral("timeline/notifications.feature:The thread being viewed*"),
    QStringLiteral("timeline/notifications.feature:The user opens a thread from its alert"),
    QStringLiteral("timeline/notifications.feature:The user dismisses an in-app alert"),
    QStringLiteral("timeline/notifications.feature:The alert setting decides*"),
    QStringLiteral("timeline/notifications.feature:Clicking a system notification*"),
    QStringLiteral("timeline/notifications.feature:A newer alert*"),
    QStringLiteral("timeline/notifications.feature:Turning system notifications off*"),
    QStringLiteral("timeline/notifications.feature:A system notification is not shown*"),
    QStringLiteral("timeline/notifications.feature:The user mutes alerts for one thread"),
    QStringLiteral("timeline/notifications.feature:The user unmutes a thread"),
    QStringLiteral("timeline/notifications.feature:Coming back to the window*"),
    QStringLiteral("timeline/qt-shell-backlog.feature"),
    QStringLiteral("settings/connections.feature"),
    QStringLiteral("settings/load-balancing.feature"),
    QStringLiteral("connections/environments.feature:A preference saved by an older build*"),
    QStringLiteral("connections/environments.feature:Turning load balancing off*"),
    QStringLiteral("connections/pairing.feature"),
    // Connections, providers and the MC, as the desktop delivers them (backlog/desktop-connections).
    QStringLiteral("providers/provider-instances.feature:Adding an instance derives*"),
    QStringLiteral("providers/provider-instances.feature:A clashing instance id*"),
    QStringLiteral("providers/provider-instances.feature:Instance ids are validated*"),
    QStringLiteral("providers/provider-instances.feature:Provider settings follow the chosen device"),
    QStringLiteral("providers/provider-instances.feature:Provider settings for a disconnected device*"),
    QStringLiteral("providers/provider-instances.feature:Provider status headlines*"),
    QStringLiteral("providers/usage.feature:Usage can be filtered by environment"),
    QStringLiteral("providers/usage.feature:Environments still scanning*"),
    QStringLiteral("providers/usage-limits.feature:Automatic checks wait*"),
    QStringLiteral("providers/claude.feature"),
    QStringLiteral("providers/codex.feature"),
    QStringLiteral("providers/capabilities.feature"),
    QStringLiteral("providers/permission-modes.feature:The permission mode can be changed from the desktop*"),
    QStringLiteral("providers/usage-limits.feature:The /usage-limits command*"),
    QStringLiteral("providers/models.feature:Favourite, hidden and ordered models*"),
    QStringLiteral("providers/models.feature:A hidden model can be shown again"),
    QStringLiteral("providers/usage.feature:A custom price is saved*"),
    QStringLiteral("providers/usage.feature:An offline environment is marked*"),
    QStringLiteral("providers/usage.feature:Environments with different prices*"),
    QStringLiteral("providers/usage.feature:A reset marked for removal*"),
    QStringLiteral("mc/platform/storage-layout.feature:The desktop app's home directory outranks*"),
    QStringLiteral("mc/platform/storage-layout.feature:The desktop app's control socket lives*"),
    QStringLiteral("mc/platform/storage-layout.feature:The desktop app on Windows keeps*"),
    QStringLiteral("mc/platform/storage-layout.feature:The desktop app a developer builds uses*"),
    QStringLiteral("mc/orchestration/runs.feature:A failed turn keeps the output*"),
    QStringLiteral("mc/orchestration/runs.feature:A provider retry is recorded*"),
    QStringLiteral("mc/orchestration/queue-and-steering.feature:A usage limit keeps the queue*"),
    QStringLiteral("providers/codex.feature:A plan Codex marked finished*"),
    QStringLiteral("connections/environments.feature:The icon cannot be changed*"),
    QStringLiteral("connections/environments.feature:A preference saved by an older build*"),
    QStringLiteral("connections/environments.feature:Turning load balancing off*"),
    QStringLiteral("connections/connection-health.feature:A dropped connection retries*"),
    QStringLiteral("connections/connection-health.feature:An offline device waits*"),
    QStringLiteral("connections/connection-health.feature:A refused credential waits*"),
    QStringLiteral("connections/connection-health.feature:Foregrounding*"),
    QStringLiteral("connections/connection-health.feature:A connection is ready only*"),
    QStringLiteral("connections/connection-health.feature:A failed shell subscription*"),
    QStringLiteral("connections/connection-health.feature:The environment's status names*"),
    QStringLiteral("connections/connection-health.feature:The user copies a connection's trace id*"),
    QStringLiteral("connections/connection-health.feature:Cached data stays readable*"),
    QStringLiteral("connections/connection-health.feature:A thread left for*"),
    QStringLiteral("connections/connection-health.feature:Subscriptions follow a replaced*"),
    QStringLiteral("connections/connection-health.feature:Reconnecting does not repeat*"),
    QStringLiteral("connections/connection-health.feature:Removing an environment clears*"),
    QStringLiteral("connections/connection-health.feature:A protocol mismatch blocks*"),
    QStringLiteral("connections/connection-health.feature:A server on another HAL-C2 version*"),
    QStringLiteral("connections/connection-health.feature:One connection serves every MC*"),
    QStringLiteral("connections/connection-health.feature:A cluster connection resumes*"),
    QStringLiteral("mc/platform/websocket-protocol.feature:A client refuses a server speaking*"),
    QStringLiteral("mc/platform/websocket-protocol.feature:A client skips an event type*"),
    QStringLiteral("threads/drafts.feature"),
    QStringLiteral("source-control/pull-request-list.feature"),
    QStringLiteral("settings/usage.feature"),
    QStringLiteral("providers/usage-limits.feature:The same account on two environments*"),
    QStringLiteral("settings/usage-limit-sources.feature:A hub's accounts are pooled*"),
    QStringLiteral("settings/usage-limit-sources.feature:An account both a hub*"),
    QStringLiteral("settings/usage-limit-sources.feature:A hub that cannot be read is named*"),
    QStringLiteral("settings/usage-limit-sources.feature:A reset credit a hub also reports*"),
    QStringLiteral("settings/usage-limit-sources.feature:The user adds a hub"),
    QStringLiteral("settings/usage-limit-sources.feature:A hub cannot be added without*"),
    QStringLiteral("settings/usage-limit-sources.feature:The user removes a hub"),
    QStringLiteral("settings/providers-panel.feature:This machine is listed first*"),
    QStringLiteral("settings/providers-panel.feature:A disconnected environment cannot*"),
    QStringLiteral("settings/providers-panel.feature:An environment that reconnects*"),
    QStringLiteral("settings/providers-panel.feature:Leaving the Providers settings*"),
    QStringLiteral("settings/providers-panel.feature:The panel says when providers were last checked"),
    QStringLiteral("settings/providers-panel.feature:Turning an instance off and on"),
    QStringLiteral("settings/providers-panel.feature:A change that cannot be saved*"),
    QStringLiteral("settings/providers-panel.feature:A provider's own API key can be cleared*"),
    QStringLiteral("settings/providers-panel.feature:Installing the managed runtime shows*"),
    QStringLiteral("settings/providers-panel.feature:A runtime download can be cancelled*"),
    QStringLiteral("settings/providers-panel.feature:A downloaded runtime is removed*"),
    QStringLiteral("settings/providers-panel.feature:Signing in finishes*"),
    QStringLiteral("settings/providers-panel.feature:A sign-in page an agent waits on*"),
    QStringLiteral("settings/providers-panel.feature:Continuing a sign-in page the agent stopped*"),
    QStringLiteral("settings/providers-panel.feature:A sign-in in progress*"),
    QStringLiteral("settings/providers-panel.feature:Choosing how to sign in"),
    QStringLiteral("settings/providers-panel.feature:A sign-in answered after switching*"),
    QStringLiteral("providers/provider-instances.feature:An instance can be renamed*"),
    QStringLiteral("providers/provider-instances.feature:Clearing the accent colour*"),
    QStringLiteral("settings/providers-panel.feature:An agent prepared after its wizard*"),
    QStringLiteral("settings/providers-panel.feature:Signing in through the agent*"),
    QStringLiteral("settings/providers-panel.feature:A login terminal that has gone*"),
    QStringLiteral("settings/providers-panel.feature:Signing in with credentials"),
    QStringLiteral("settings/providers-panel.feature:Pasting the final sign-in address*"),
    QStringLiteral("settings/providers-panel.feature:A sign-in that fails*"),
    QStringLiteral("settings/providers-panel.feature:Declining to sign out*"),
    QStringLiteral("settings/providers-panel.feature:An update that cannot run*"),
    QStringLiteral("settings/providers-panel.feature:A provider behind its latest*"),
    QStringLiteral("settings/providers-panel.feature:A provider update shows*"),
    QStringLiteral("settings/providers-panel.feature:An update that fails*"),
    QStringLiteral("settings/providers-panel.feature:A provider version outside*"),
    QStringLiteral("settings/providers-panel.feature:The health check interval*"),
    QStringLiteral("settings/providers-panel.feature:Adding a second instance*"),
    QStringLiteral("settings/providers-panel.feature:A taken instance id*"),
    QStringLiteral("settings/providers-panel.feature:The instance id must be valid*"),
    QStringLiteral("settings/providers-panel.feature:Going back in the wizard*"),
    QStringLiteral("settings/providers-panel.feature:An instance that cannot be saved*"),
    QStringLiteral("settings/providers-panel.feature:Renaming an instance*"),
    QStringLiteral("settings/providers-panel.feature:Sensitive environment variables*"),
    QStringLiteral("settings/providers-panel.feature:Removing an environment variable"),
    QStringLiteral("settings/providers-panel.feature:Renaming a stored secret*"),
    QStringLiteral("settings/providers-panel.feature:Deleting an instance*"),
    QStringLiteral("settings/providers-panel.feature:A recommended version is installed*"),
    QStringLiteral("settings/providers-panel.feature:Installing the recommended version"),
    QStringLiteral("settings/providers-panel.feature:Adding a custom model with its own options"),
    QStringLiteral("settings/providers-panel.feature:Copying options from a built-in model"),
    QStringLiteral("settings/providers-panel.feature:A search with no compatible agent*"),
    QStringLiteral("settings/providers-panel.feature:An agent already added is marked*"),
    QStringLiteral("settings/providers-panel.feature:Choosing a registry agent names*"),
    QStringLiteral("settings/providers-panel.feature:The registry step needs an agent*"),
    QStringLiteral("settings/providers-panel.feature:Importing a native session*"),
    QStringLiteral("settings/providers-panel.feature:An imported session cannot be deleted*"),
    QStringLiteral("settings/providers-panel.feature:Deleting a native session*"),
    QStringLiteral("settings/providers-panel.feature:Pointing an agent's model provider*"),
    QStringLiteral("settings/providers-panel.feature:Model provider headers must be*"),
    QStringLiteral("settings/providers-panel.feature:Logging out of an ACP agent"),
    QStringLiteral("settings/providers-panel.feature:A custom option must be complete before saving*"),
    QStringLiteral("settings/providers-panel.feature:A custom model id is checked*"),
    QStringLiteral("settings/providers-panel.feature:A model lists what it can do"),
    QStringLiteral("settings/providers-panel.feature:A long models list*"),
    QStringLiteral("settings/providers-panel.feature:A custom model without options uses the provider's defaults"),
    QStringLiteral("providers/provider-setup.feature:Signing out asks*"),
    QStringLiteral("threads/menu-actions.feature"),
    QStringLiteral("threads/moving-between-machines.feature"),
    QStringLiteral("threads/thread-list.feature"),
    QStringLiteral("terminal/drawer.feature"),
    QStringLiteral("terminal/tabs.feature"),
    QStringLiteral("terminal/sessions.feature"),
    QStringLiteral("terminal/errors.feature"),
    QStringLiteral("terminal/io.feature"),
    QStringLiteral("terminal/links-and-graphics.feature"),
    QStringLiteral("terminal/reconnect.feature"),
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
    QStringLiteral("threads/archive-delete.feature:Deleting the open thread opens the latest*"),
    QStringLiteral("threads/archive-delete.feature:Deleting the open thread, the last*"),
    QStringLiteral("threads/archive-delete.feature:Archiving the open thread opens a new thread*"),
    QStringLiteral("threads/archive-delete.feature:Archiving and unarchiving from the desktop*"),
    QStringLiteral("threads/archive-delete.feature:The archived threads list says*"),
    QStringLiteral("threads/archive-delete.feature:Archived threads are grouped*"),
    QStringLiteral("threads/archive-delete.feature:Archived threads for one project*"),
    QStringLiteral("threads/archive-delete.feature:An archived thread action that fails*"),
    QStringLiteral("threads/archive-delete.feature:Deleting an archived thread*"),
    QStringLiteral("threads/pinning-and-order.feature"),
    QStringLiteral("threads/creating.feature:A new worktree needs a base branch"),
    QStringLiteral("threads/creating.feature:A thread cannot start from an empty task"),
    QStringLiteral("composer/drafting-and-sending.feature:The first message of a new thread creates*"),
    QStringLiteral("threads/sidebar-list.feature:Projects *"),
    QStringLiteral("threads/sidebar-list.feature:Threads started by other agents*"),
    QStringLiteral("threads/sidebar-list.feature:Threads on an offline environment*"),
    QStringLiteral("files/search.feature:The file picker*"),
    QStringLiteral("files/search.feature:Content search groups*"),
    QStringLiteral("files/search.feature:The result count*"),
    QStringLiteral("files/search.feature:Content search explains*"),
    QStringLiteral("files/search.feature:The search is cleared*"),
    QStringLiteral("threads/sidebar-list.feature:Threads are grouped*"),
    QStringLiteral("threads/sidebar-list.feature:Active threads are listed newest first"),
    QStringLiteral("threads/sidebar-list.feature:Settled threads are listed by when they settled"),
    QStringLiteral("threads/sidebar-list.feature:Very long settled*"),
    QStringLiteral("threads/sidebar-list.feature:Opening a *from the list"),
    QStringLiteral("threads/sidebar-list.feature:Scoping the list*"),
    QStringLiteral("threads/sidebar-list.feature:Hiding and showing the thread list"),
    QStringLiteral("threads/sidebar-list.feature:The list catches up after a reconnect"),
    QStringLiteral("threads/sidebar-list.feature:The list starts over*"),
    QStringLiteral("threads/snooze.feature"),
    QStringLiteral("threads/settle.feature"),
    QStringLiteral("threads/unread-and-status.feature:A thread row names its state"),
    QStringLiteral("threads/unread-and-status.feature:The most urgent state wins"),
    QStringLiteral("threads/unread-and-status.feature:A project shows the most urgent state*"),
    QStringLiteral("threads/unread-and-status.feature:A working thread shows how long*"),
    QStringLiteral("threads/unread-and-status.feature:Marking a thread unread from its menu"),
    QStringLiteral("threads/limited-threads.feature"),
    QStringLiteral("threads/moving-between-machines.feature"),
    QStringLiteral("threads/creating.feature:A new thread uses the project default model*"),
    QStringLiteral("threads/creating.feature:Starting a thread in the background opens a fresh draft"),
    QStringLiteral("threads/creating.feature:Each background start into a new worktree*"),
    QStringLiteral("threads/creating.feature:Fanning one request out to several models"),
    QStringLiteral("threads/creating.feature:Several models cannot be chosen outside a Git project"),
    QStringLiteral("threads/creating.feature:Changing a draft's project picks an environment that has it"),
    QStringLiteral("threads/search.feature:Searching spans every connected environment"),
    QStringLiteral("threads/search.feature:An offline environment is left out of the search"),
    QStringLiteral("threads/search.feature:Moving through search results with the keyboard"),
    QStringLiteral("threads/search.feature:Leaving a search"),
    QStringLiteral("threads/menu-and-selection.feature:Selecting several threads*"),
    QStringLiteral("threads/menu-and-selection.feature:Clearing a selection"),
    QStringLiteral("threads/menu-and-selection.feature:Changing the project filter clears the selection"),
    QStringLiteral("threads/menu-and-selection.feature:The selection menu counts*"),
    QStringLiteral("threads/menu-and-selection.feature:A menu action applies to every selected thread*"),
    QStringLiteral("threads/menu-and-selection.feature:The selection cannot be archived*"),
    QStringLiteral("threads/menu-and-selection.feature:A partly failed delete*"),
    QStringLiteral("threads/archive-delete.feature:Deleting several threads at once"),
    QStringLiteral("threads/archive-delete.feature:Deleting the last thread in a worktree*"),
    QStringLiteral("threads/archive-delete.feature:The worktree is removed without asking*"),
    QStringLiteral("threads/archive-delete.feature:A worktree that cannot be removed is reported"),
    QStringLiteral("threads/archive-delete.feature:Archiving the open thread when the next thread cannot be opened"),
    QStringLiteral("threads/unread-and-status.feature:Marking several threads unread"),
    QStringLiteral("threads/unread-and-status.feature:Reading a thread tells the environment it was seen"),
    QStringLiteral("threads/unread-and-status.feature:Pointing at a thread previews it"),
    QStringLiteral("threads/sidebar-list.feature:Jump hints appear while holding the modifier"),
    QStringLiteral("threads/migration-and-handoffs.feature:The user is told threads were migrated"),
    QStringLiteral("threads/pull-request-links.feature"),
    QStringLiteral("threads/worktree-setup.feature"),
    QStringLiteral("threads/fork-and-lineage.feature"),
    QStringLiteral("files/adding-projects.feature"),
    QStringLiteral("navigation/palette-add-project.feature:A project can come from*"),
    QStringLiteral("navigation/palette-add-project.feature:A repository source that is not set up*"),
    QStringLiteral("navigation/palette-add-project.feature:Cloning asks*"),
    QStringLiteral("navigation/palette-add-project.feature:Browsing starts in the home folder"),
    QStringLiteral("navigation/palette-add-project.feature:A clone's destination starts*"),
    QStringLiteral("navigation/palette-add-project.feature:Failures while adding*"),
    QStringLiteral("navigation/palette-add-project.feature:The user chooses which environment*"),
    QStringLiteral("navigation/palette-add-project.feature:An environment that goes away*"),
    QStringLiteral("navigation/palette-add-project.feature:A folder that does not exist yet*"),
    QStringLiteral("navigation/palette-add-project.feature:Relative paths need*"),
    QStringLiteral("navigation/palette-add-project.feature:mod+Enter adds*"),
    QStringLiteral("files/removing-and-listing-projects.feature:Removing *"),
    QStringLiteral("files/removing-and-listing-projects.feature:Confirming removal*"),
    QStringLiteral("files/removing-and-listing-projects.feature:Cancelling removal*"),
    QStringLiteral("files/removing-and-listing-projects.feature:A confirmation for a project that goes away*"),
    QStringLiteral("files/removing-and-listing-projects.feature:A removal the environment refuses*"),
    QStringLiteral("threads/titles.feature"),
    QStringLiteral("source-control/refs-and-branches.feature"),
    QStringLiteral("source-control/worktrees-and-setup-scripts.feature"),
    // The desktop's git actions (GitController); the rest of these files is the MC's and the TUI's.
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
    QStringLiteral("source-control/git-actions.feature:A machine that is offline*"),
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
    QStringLiteral("source-control/commit-and-generated-messages.feature:A git action on another machine*"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:The running action shows*"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:Leaving every file out*"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:Cancelling the commit*"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:Committing on the default branch carries*"),
    QStringLiteral("source-control/errors.feature:A failed git action stays*"),
    QStringLiteral("source-control/status-and-changes.feature"),
    QStringLiteral("source-control/repository-discovery-clone-publish.feature"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:Opening a changed file from the commit review"),
    QStringLiteral("source-control/commit-and-generated-messages.feature:No editor to open a changed file in"),
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
    QStringLiteral("navigation/keybinding-settings.feature:Conditions are built*"),
    QStringLiteral("navigation/keybinding-settings.feature:A change is saved to every connected environment"),
    QStringLiteral("navigation/keybinding-settings.feature:The file *"),
    // The settings navigation's search, on the SettingsNav brick (SettingsNavSteps.cpp).
    QStringLiteral("navigation/focus.feature:Searching settings lists*"),
    QStringLiteral("navigation/focus.feature:A settings result opens from the keyboard"),
    QStringLiteral("navigation/focus.feature:Nothing matches the settings search"),
    QStringLiteral("navigation/focus.feature:Escape clears the settings search"),
    QStringLiteral("navigation/focus.feature:The search follows a query set elsewhere"),
    QStringLiteral("navigation/focus.feature:Typing while a terminal starts*"),
    QStringLiteral("navigation/focus.feature:Number shortcuts pick entries*"),
    QStringLiteral("source-control/checkpoint-diffs.feature"),
    QStringLiteral("source-control/review-diffs.feature"),
    QStringLiteral("timeline/checkpoints.feature"),
    QStringLiteral("files/folder-operations.feature"),
    QStringLiteral("files/project-file.feature"),
    QStringLiteral("files/project-identity.feature"),
    QStringLiteral("files/file-explorer.feature"),
    QStringLiteral("files/file-viewer-and-editing.feature"),
    QStringLiteral("navigation/layout.feature:Opening and closing the right panel"),
    QStringLiteral("navigation/layout.feature:Switching between right panel tabs"),
    QStringLiteral("navigation/layout.feature:Closing a right panel tab"),
    QStringLiteral("navigation/layout.feature:Adding a tab to the right panel*"),
    QStringLiteral("navigation/layout.feature:A tab kind that the thread cannot show*"),
    QStringLiteral("navigation/layout.feature:Right panel contents survive closing the panel"),
    QStringLiteral("navigation/layout.feature:Resizing the right panel"),
    QStringLiteral("navigation/layout.feature:Maximizing the right panel"),
    QStringLiteral("navigation/layout.feature:The right panel's tabs and width survive a restart"),
    QStringLiteral("navigation/layout.feature:Toggling the thread details panel"),
    QStringLiteral("navigation/layout.feature:Hiding the thread details panel"),
    QStringLiteral("navigation/layout.feature:The thread details panel leads to the thread it was forked from"),
    QStringLiteral("source-control/pull-request-threads.feature"),
    QStringLiteral("source-control/pull-request-review.feature"),
    QStringLiteral("source-control/pull-request-actions.feature"),
    QStringLiteral("source-control/stacked-pull-requests.feature"),
    QStringLiteral("preview/surfaces.feature"),
    QStringLiteral("navigation/layout.feature:Showing the terminal from the header"),
    QStringLiteral("navigation/layout.feature:Hiding the terminal"),
    QStringLiteral("navigation/layout.feature:Choosing the project in the header*"),
    QStringLiteral("navigation/layout.feature:The header names the project and thread"),
    QStringLiteral("navigation/layout.feature:The thread title uses the room it has"),
    QStringLiteral("navigation/layout.feature:The header opens the thread's workspace in another editor"),
    QStringLiteral("navigation/layout.feature:Hiding the sidebar"),
    QStringLiteral("navigation/layout.feature:Showing the sidebar again from the header"),
    QStringLiteral("navigation/layout.feature:The sidebar shortcut hides and shows the sidebar"),
    QStringLiteral("navigation/layout.feature:A hidden sidebar stays hidden after a restart"),
    QStringLiteral("navigation/layout.feature:Settings replace the thread list*"),
    QStringLiteral("navigation/layout.feature:The sidebar snaps*"),
    QStringLiteral("navigation/layout.feature:Resizing the sidebar is remembered"),
    QStringLiteral("navigation/layout.feature:The sidebar cannot be narrower*"),
    QStringLiteral("navigation/layout.feature:Resetting the sidebar width"),
    QStringLiteral("navigation/layout.feature:Right panel contents survive a visit to settings"),
    QStringLiteral("navigation/layout.feature:A hidden right panel does no work"),
    QStringLiteral("navigation/layout.feature:The header runs the project's action the user ran last"),
    QStringLiteral("navigation/layout.feature:The header runs any of the project's actions"),
    QStringLiteral("navigation/layout.feature:The header offers no action to run when the project has none"),
    QStringLiteral("navigation/layout.feature:The header opens the thread's workspace in the preferred editor"),
    QStringLiteral("navigation/layout.feature:The header offers no editor when the environment has none"),
    QStringLiteral("navigation/layout.feature:The thread's git actions are in the header"),
    QStringLiteral("navigation/appearance.feature:Panels open and close immediately by default"),
    QStringLiteral("navigation/header.feature"),
    QStringLiteral("navigation/landing.feature"),
    QStringLiteral("settings/storage.feature:Settings for several machines show mixed values"),
    QStringLiteral("settings/storage.feature:A machine too old for storage cleanup*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:Changing one axis of the scope*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:Offline environments are marked*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:An environment-wide change is saved*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:Saving on some environments*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:A setting cannot be changed while*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:The page states*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:A project change is saved*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:A device preference*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:An environment-wide setting cannot*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:Resetting a project override*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:A value that differs*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:A model missing*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:The inheritance chain*"),
    QStringLiteral("settings/scopes-and-inheritance.feature:The environment view lists*"),
    QStringLiteral("settings/scheduled-tasks.feature"),
    QStringLiteral("settings/source-control.feature"),
    QStringLiteral("settings/source-control-writing.feature"),
    QStringLiteral("settings/integrations.feature"),
    QStringLiteral("settings/projects.feature"),
    QStringLiteral("settings/project-defaults.feature"),
    QStringLiteral("settings/licenses.feature"),
    QStringLiteral("settings/diagnostics.feature"),
    QStringLiteral("settings/updates.feature:At launch*"),
    // Every settings file: what is not backlog on the desktop passes.
    QStringLiteral("settings/*.feature"),
    QStringLiteral("settings/notifications.feature"),
    QStringLiteral("settings/background-service.feature:Clients report what the user is looking at"),
    QStringLiteral("settings/project-actions.feature"),
    QStringLiteral("settings/load-balancing.feature"),
    QStringLiteral("settings/snap-shot.feature"),
    QStringLiteral("source-control/snap-shot.feature"),
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
      const bool backlog = scenario.tags.contains(QStringLiteral("@backlog")) ||
                           scenario.tags.contains(QStringLiteral("@backlog-desktop"));
      if (scenario.tags.contains(QStringLiteral("@dropped")) || scenario.tags.contains(QStringLiteral("@blocked"))) continue;
      if (backlog != qEnvironmentVariableIsSet("HAL_C2_BACKLOG")) continue;
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
