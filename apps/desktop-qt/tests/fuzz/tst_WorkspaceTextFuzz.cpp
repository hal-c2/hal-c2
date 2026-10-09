// A file's rendered view in the Files tab (WorkspaceFiles.cpp): a CSV or TSV as
// a table, a Markdown file's task boxes, and the toggle that ticks one. The
// helpers that draw them sit in WorkspaceFiles.cpp's anonymous namespace, so the
// file is read as the user reads it: a fake MC holds the file the input wrote,
// the tab opens it and the rendered view and toggle are what is checked. The
// file's text is any bytes, as the MC reads them; a CSV table has at most
// csvRowLimit rows (plus its header) of at most csvColumnLimit cells, and so
// at most what the input holds plus that grid of padding, and a toggle changes
// at most one character, a task's box, and only in a Markdown file.

#include "Fuzz.h"
#include "FakeFiles.h"
#include "FakeMc.h"
#include "McClient.h"
#include "WorkspaceFiles.h"

#include <QEventLoop>
#include <QtTest>

#include <cstdint>
#include <optional>
#include <string>
#include <tuple>
#include <vector>

using namespace halc2;

namespace {

// What the parsers look for: CSV separators and quotes, Markdown task lists and fences.
const std::vector<std::string> kWords{",", "\"", "\"\"", "\n", "\r\n", "\r", "\t", "|", "\\", " | ", "a", "1",
                                      "- [ ] ", "- [x] ", "* [X] ", "1. [ ] ", "[", "]", "[ ]", "[x]", "[X]",
                                      "  ", "```", "~~~", "\n\n", "task", "\xe2\x98\x90", "\xff"};

// The files the tab can open, by the kind the input picks: Markdown, CSV, TSV,
// HTML, plain text, a folder with a dot, and no extension.
const QStringList kPaths{QStringLiteral("notes.md"), QStringLiteral("data.csv"), QStringLiteral("data.tsv"),
                         QStringLiteral("page.html"), QStringLiteral("plain.txt"), QStringLiteral("dir.x/file.MD"),
                         QStringLiteral("noext")};

// The MC and the client the Files tab reads through, kept for every input: the
// fake MC answers with the file the input has put in it. Never freed; the
// process ends when fuzzing does.
struct Session {
  FakeMc mc;
  McClient client;

  Session() {
    client.setRetryDelays({20});
    client.open(mc.origin(), QStringLiteral("token"));
    if (!QTest::qWaitFor([this] { return client.isReady(); })) qFatal("fuzz: the fake MC is not ready");
  }
};

Session& mcSession() {
  static Session* const kept = new Session;
  return *kept;
}

// Returns once the MC has answered every call made before this one: it answers
// its socket's calls in order.
void settle(McClient& client) {
  bool done = false;
  QEventLoop loop;
  QObject context;
  client.call(&context, {}, QStringLiteral("test.barrier"), {}, [&done, &loop](const QJsonValue&, const std::optional<QString>&) {
    done = true;
    loop.quit();
  });
  if (!done) loop.exec();
}

void RenderedFileHoldsUp(const std::string& text, std::uint8_t kind, int index, bool wide) {
  Session& session = mcSession();
  const QString path = kPaths.at(kind % kPaths.size());
  const QString contents = wide ? fuzz::utf16(text) : fuzz::utf8(text);
  fuzz::print(contents);
  fakeFiles(session.mc).files.insert(path, contents);

  WorkspaceFiles files(&session.client);
  files.setTarget(QStringLiteral("env-a"), QStringLiteral("/w"));
  files.openFile(path);
  settle(session.client);
  ASSERT_EQ(files.fileStatus(), QStringLiteral("ready")) << path.toStdString();

  const QString rendered = files.renderedText();
  if (files.renderKind() == QLatin1String("csv")) {
    int tableLines = 0;
    for (const QString& line : rendered.split(QLatin1Char('\n'))) {
      if (!line.startsWith(QLatin1Char('|'))) continue;
      ++tableLines;
      EXPECT_TRUE(line.endsWith(QLatin1Char('|'))) << line.toStdString();
    }
    // The header and the separator, then at most csvRowLimit rows.
    EXPECT_LE(tableLines, WorkspaceFiles::csvRowLimit + 2) << "rendered " << tableLines << " table lines";
    // Padding costs a few characters a cell; a cell the input holds is at most
    // its own length, escaped (twice), and every other character is padding.
    const qsizetype grid = qsizetype(WorkspaceFiles::csvRowLimit + 2) * WorkspaceFiles::csvColumnLimit * 8;
    EXPECT_LE(rendered.size(), contents.size() * 2 + grid + 200) << "rendered " << rendered.size() << " characters of " << contents.size();
  }

  const QString before = files.text();
  files.toggleTask(index);
  const QString after = files.text();
  settle(session.client);
  ASSERT_EQ(after.size(), before.size());
  std::vector<qsizetype> changed;
  for (qsizetype at = 0; at < before.size(); ++at) {
    if (before.at(at) != after.at(at)) changed.push_back(at);
  }
  if (files.renderKind() != QLatin1String("markdown")) {
    EXPECT_TRUE(changed.empty()) << "toggled a " << files.renderKind().toStdString() << " file";
  }
  EXPECT_LE(changed.size(), 1u);
  if (changed.size() == 1) {
    const qsizetype at = changed.front();
    const QString boxes = QStringLiteral(" xX");
    EXPECT_TRUE(at >= 1 && at + 1 < before.size() && before.at(at - 1) == QLatin1Char('[') && before.at(at + 1) == QLatin1Char(']'))
        << "the toggle moved off a task's box at " << at;
    EXPECT_TRUE(boxes.contains(before.at(at)) && boxes.contains(after.at(at)));
  }
  files.renderedText();
}
FUZZ_TEST(WorkspaceFiles, RenderedFileHoldsUp)
    .WithDomains(fuzz::Text(kWords), fuzztest::InRange<std::uint8_t>(0, std::uint8_t(kPaths.size() - 1)),
                 fuzztest::Arbitrary<int>(), fuzztest::Arbitrary<bool>())
    .WithSeeds([] {
      // A wide row of cells and many short rows: the table's padding.
      std::string wide(1000, ',');
      wide += '\n';
      for (int row = 0; row < 50; ++row) wide += "a\n";
      // The header alone: every row is padded to its width.
      std::string header(20000, ',');
      header += "\n" + std::string(5000, 'a') + "\n";
      std::string tabs(20000, '\t');
      tabs += "\n" + std::string(5000, 'a') + "\n";
      return std::vector<std::tuple<std::string, std::uint8_t, int, bool>>{
          {"name,qty\n\"a, b\",1\nc,\"2\"\"x\"\"\"\n", 1, 0, false},
          {"a\tb\n\"x\ny\"\tz\n", 2, 0, true},
          {"x | y\\\n", 1, 3, false},
          {"", 1, 0, false},
          {"- [ ] one\n- [x] two\n```\n- [ ] inside\n```\n1. [X] three\n", 0, 1, false},
          {"> - [ ] quoted\n\t* [ ] nested\r\n1) [x] done\n", 5, 0, false},
          {"- [ ] \xe2\x98\x90\n[ ] no list\n", 0, -1, false},
          {wide, 1, 0, false},
          {header, 1, 0, false},
          {tabs, 2, 0, false},
      };
    });

}  // namespace
