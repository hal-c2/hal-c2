#include "Runner.h"

#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QMap>
#include <QTest>

#include <algorithm>
#include <optional>
#include <utility>

namespace {

QList<runner::Definition>& definitions() {
  static QList<runner::Definition> list;
  return list;
}

QList<void (*)()>& stepFiles() {
  static QList<void (*)()> list;
  return list;
}

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

QRegularExpression wildcard(const QString& glob) {
  return QRegularExpression::fromWildcard(glob, Qt::CaseSensitive, QRegularExpression::NonPathWildcardConversion);
}

}  // namespace

namespace runner {

// Enough Gherkin for this repo: tags, Feature, Rule, Background, Scenario,
// Scenario Outline with Examples, data tables, and doc strings (`"""`), which a
// step is given as a table of one cell: the lines between the marks, less the
// opening mark's indent.
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
    if (line == QLatin1String("\"\"\"")) {
      const qsizetype indent = lines.at(index).indexOf(QLatin1Char('"'));
      QStringList doc;
      while (++index < lines.size() && lines.at(index).trimmed() != QLatin1String("\"\"\"")) {
        const QString& raw = lines.at(index);
        qsizetype cut = 0;
        while (cut < indent && cut < raw.size() && raw.at(cut).isSpace()) ++cut;
        doc.append(raw.mid(cut));
      }
      if (steps && !steps->isEmpty()) steps->last().table.append({doc.join(QLatin1Char('\n'))});
      continue;
    }
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

void defineSteps() {
  for (const auto define : std::as_const(stepFiles())) define();
}

Match match(const Step& step) {
  const Definition* found = nullptr;
  QRegularExpressionMatch matched;
  for (const Definition& definition : definitions()) {
    QRegularExpressionMatch candidate = definition.pattern.match(step.text);
    if (!candidate.hasMatch()) continue;
    if (found) fail(QStringLiteral("ambiguous step: ") + step.text);
    found = &definition;
    matched = candidate;
  }
  if (!found) fail(QStringLiteral("undefined step: ") + step.text);
  // One per group, a group that took no part as an empty string
  // (capturedTexts() leaves trailing ones out).
  Captures captures;
  for (int group = 1; group <= found->pattern.captureCount(); ++group) captures.append(matched.captured(group));
  return {found, captures};
}

QList<Scenario> collectScenarios(const QString& featuresDir, const QStringList& defaultGlobs, const QString& surface,
                                 Coverage* coverage) {
  const QDir root(featuresDir);
  QStringList globs = defaultGlobs;
  if (const QString requested = qEnvironmentVariable("HAL_C2_FEATURES"); !requested.isEmpty()) {
    globs = requested.split(QLatin1Char(' '), Qt::SkipEmptyParts);
  }
  // Each file, with what each glob that names it wants from it: all of its
  // scenarios, or those whose names match.
  struct Want {
    qsizetype glob;
    bool all;
    QRegularExpression name;
  };
  QMap<QString, QList<Want>> files;
  QDirIterator it(root.path(), {QStringLiteral("*.feature")}, QDir::Files, QDirIterator::Subdirectories);
  while (it.hasNext()) {
    const QString path = it.next();
    const QString relative = root.relativeFilePath(path);
    for (qsizetype g = 0; g < globs.size(); ++g) {
      const QString& glob = globs.at(g);
      const qsizetype colon = glob.indexOf(QLatin1Char(':'));
      if (!wildcard(glob.left(colon)).match(relative).hasMatch()) continue;
      files[path].append({g, colon < 0, colon < 0 ? QRegularExpression() : wildcard(glob.mid(colon + 1))});
    }
  }
  QList<bool> matched(globs.size(), false);
  qsizetype named = 0;
  QList<Scenario> scenarios;
  for (auto file = files.cbegin(); file != files.cend(); ++file) {
    for (const Scenario& scenario : parseFeature(file.key())) {
      bool wanted = false;
      for (const Want& want : file.value()) {
        if (!want.all && !want.name.match(scenario.name).hasMatch()) continue;
        matched[want.glob] = true;
        wanted = true;
      }
      if (!wanted) continue;
      ++named;
      // `@shared` is `@desktop @mobile @tui` (features/README.md).
      if (!scenario.tags.contains(QLatin1Char('@') + surface) && !scenario.tags.contains(QStringLiteral("@shared"))) continue;
      // Not delivered anywhere, dropped, or not on this surface yet.
      const bool backlog = scenario.tags.contains(QStringLiteral("@backlog")) ||
                           scenario.tags.contains(QStringLiteral("@backlog-") + surface);
      if (scenario.tags.contains(QStringLiteral("@dropped")) || scenario.tags.contains(QStringLiteral("@blocked"))) continue;
      if (backlog != qEnvironmentVariableIsSet("HAL_C2_BACKLOG")) continue;
      scenarios.append(scenario);
    }
  }
  if (coverage != nullptr) {
    coverage->scenariosNamed = named;
    coverage->unmatchedGlobs.clear();
    for (qsizetype g = 0; g < globs.size(); ++g) {
      if (!matched.at(g)) coverage->unmatchedGlobs.append(globs.at(g));
    }
  }
  return scenarios;
}

void addRows(const QList<Scenario>& scenarios, const QString& featuresDir) {
  QTest::addColumn<int>("index");
  const QDir root(featuresDir);
  for (qsizetype index = 0; index < scenarios.size(); ++index) {
    const Scenario& scenario = scenarios.at(index);
    QTest::newRow(qPrintable(root.relativeFilePath(scenario.file) + QStringLiteral(": ") + scenario.name))
        << static_cast<int>(index);
  }
}

QString describe(const Scenario& scenario, const Step& step, const Failure& failure, const QString& featuresDir) {
  return QStringLiteral("%1:%2 %3\n  %4")
      .arg(QDir(featuresDir).relativeFilePath(scenario.file))
      .arg(step.line)
      .arg(step.text, QString::fromStdString(failure.what()));
}

}  // namespace runner

void step(const QString& pattern, StepFn run) {
  definitions().append({QRegularExpression(QLatin1Char('^') + pattern + QLatin1Char('$')), std::move(run)});
}

Steps::Steps(void (*define)()) {
  stepFiles().append(define);
}
