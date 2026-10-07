#pragma once

// What every client's scenario runner shares (this directory's tst_Features
// and apps/mobile-qt/tests'): the Gherkin reader, the step definitions the
// steps files register (Harness.h), and which scenarios of features/ a run is
// for. A runner keeps its own list of feature files, its own World, and the
// QTest class that makes one row per scenario.

#include <QList>
#include <QRegularExpression>
#include <QString>
#include <QStringList>

#include <optional>

#include "Harness.h"

namespace runner {

struct Definition {
  QRegularExpression pattern;
  StepFn run;
};

// Enough Gherkin for this repo: tags, Feature, Rule, Background, Scenario,
// Scenario Outline with Examples, and data tables. Doc strings are not used.
QList<Scenario> parseFeature(const QString& path);

// Runs every steps file's `define` (Steps); once, before the scenarios.
void defineSteps();

// The one definition `step` matches and what it captured. No definition, or
// two, fails the step.
struct Match {
  const Definition* definition;
  Captures captures;
};
Match match(const Step& step);

// The scenarios under `featuresDir` a run on `surface` ("desktop", "mobile")
// is for: those of the files `defaultGlobs` names, or of HAL_C2_FEATURES'
// (space separated; a glob may name scenarios after a colon), that carry
// `@<surface>` or `@shared`, less `@dropped` and `@blocked`. `@backlog` and
// `@backlog-<surface>` ones are left out, or with HAL_C2_BACKLOG set are the
// only ones kept.
QList<Scenario> collectScenarios(const QString& featuresDir, const QStringList& defaultGlobs, const QString& surface);

// One QTest row per scenario, "<file under featuresDir>: <name>", with its
// index in `scenarios` as the column `index`.
void addRows(const QList<Scenario>& scenarios, const QString& featuresDir);

// A failed step as QFAIL reports it: "<file>:<line> <step>\n  <why>".
QString describe(const Scenario& scenario, const Step& step, const Failure& failure, const QString& featuresDir);

// A template so this header needs no World: each runner has its own.
template <class W>
void runStep(W& world, const Step& step) {
  const Match found = match(step);
  world.checking = step.outcome;
  found.definition->run(world, found.captures, step.table);
}

// Runs the scenario's steps in `world`, up to the first that fails: what
// describe() says of it, or nothing when all passed.
template <class W>
std::optional<QString> run(W& world, const Scenario& scenario, const QString& featuresDir) {
  for (const Step& step : scenario.steps) {
    try {
      runStep(world, step);
    } catch (const Failure& failure) {
      return describe(scenario, step, failure, featuresDir);
    }
  }
  return std::nullopt;
}

}  // namespace runner
