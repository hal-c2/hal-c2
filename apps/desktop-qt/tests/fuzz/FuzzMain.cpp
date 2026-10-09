// The main of every fuzz test: fuzztest's own (fuzztest_gtest_main.cc), with
// what Qt code needs first. A home of its own, so nothing a test touches is
// the developer's, and one QGuiApplication (offscreen) that outlives the
// tests, which fuzztest's main cannot give.

#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QStandardPaths>
#include <QTemporaryDir>

#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

#include "absl/debugging/failure_signal_handler.h"
#include "absl/debugging/symbolize.h"
#include "fuzztest/init_fuzztest.h"
#include "gtest/gtest.h"

namespace {

// Static, so it is removed however the process ends normally: fuzzing ends
// with std::exit.
std::unique_ptr<QTemporaryDir> home;

void isolate() {
  home = std::make_unique<QTemporaryDir>(QDir::tempPath() + "/hal-c2-fuzz-XXXXXX");
  if (!home->isValid()) qFatal("fuzz: no temporary home");
  const QString root = home->path();
  QDir().mkpath(root + "/runtime");
  QFile::setPermissions(root + "/runtime", QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
  qputenv("HOME", root.toUtf8());
  qputenv("HAL_C2_HOME", (root + "/hal-c2").toUtf8());
  qputenv("XDG_CONFIG_HOME", (root + "/config").toUtf8());
  qputenv("XDG_DATA_HOME", (root + "/data").toUtf8());
  qputenv("XDG_STATE_HOME", (root + "/state").toUtf8());
  qputenv("XDG_CACHE_HOME", (root + "/cache").toUtf8());
  qputenv("XDG_RUNTIME_DIR", (root + "/runtime").toUtf8());
  qputenv("TZ", "UTC");
  if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")) qputenv("QT_QPA_PLATFORM", "offscreen");
  qunsetenv("QT_QPA_PLATFORMTHEME");
  QStandardPaths::setTestModeEnabled(true);
}

}  // namespace

int main(int argc, char** argv) {
  isolate();
  absl::InitializeSymbolizer(argv[0]);
  absl::FailureSignalHandlerOptions options;
  options.call_previous_handler = true;
  absl::InstallFailureSignalHandler(options);

  // Qt reads none of the engine's flags.
  static int qtArgc = 1;
  static char* qtArgv[] = {argv[0], nullptr};
  QGuiApplication app(qtArgc, qtArgv);

  // Run with no arguments (as ctest does), a test replays the corpus database
  // HAL_C2_FUZZ_CORPUS names, coverage and regressions, before its seeds and
  // FUZZTEST_FUZZ_FOR of random inputs (README.md).
  std::vector<std::string> flags;
  if (const QByteArray corpus = qgetenv("HAL_C2_FUZZ_CORPUS"); argc == 1 && !corpus.isEmpty()) {
    flags = {"--corpus_database=" + corpus.toStdString(), "--replay_corpus_for=inf"};
  }
  std::vector<char*> args(argv, argv + argc);
  for (std::string& flag : flags) args.push_back(flag.data());
  args.push_back(nullptr);
  argc = int(args.size()) - 1;
  argv = args.data();

  testing::InitGoogleTest(&argc, argv);
  fuzztest::ParseAbslFlags(argc, argv);
  fuzztest::InitFuzzTest(&argc, &argv);
  return RUN_ALL_TESTS();
}
