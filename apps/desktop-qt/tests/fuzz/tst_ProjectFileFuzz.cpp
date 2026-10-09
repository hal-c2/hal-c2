// A checkout's hal-c2.json (ProjectFile.h) read from any text, and from a
// structured file with comments and trailing commas spliced in between its
// tokens. Not crashing is the first law. What parses must hold the format's
// limits, and the same file with its comments and commas is the same file.

#include "Fuzz.h"
#include "ProjectFile.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <tuple>
#include <vector>

using namespace halc2;

namespace {

// What ProjectFile.cpp looks for: the comment and comma syntax, the keys, and
// the values the format names.
const std::vector<std::string> kWords{"//", "/*", "*/", ",", "{", "}", "[", "]", "\"", "scripts", "iconPath",
                                      "previewUrl", "name", "command", "icon", "async", "runOnWorktreeCreate",
                                      "autoOpenPreview", "defaultThreadEnvMode", "worktreeSubmodules", "$schema",
                                      "local", "worktree", "top-level", "none", "recursive", "play", "test", "\n",
                                      "\\", ":", "true", "false", "null", " "};

// The limits the format sets (ProjectFile.cpp kMaxScripts, kMaxPath).
constexpr qsizetype kMaxScripts = 50;
constexpr qsizetype kMaxPath = 512;

bool same(const std::optional<projectfile::File>& a, const std::optional<projectfile::File>& b) {
  if (a.has_value() != b.has_value()) return false;
  if (!a) return true;
  if (a->defaultThreadEnvMode != b->defaultThreadEnvMode || a->scripts.size() != b->scripts.size()) return false;
  for (qsizetype i = 0; i < a->scripts.size(); ++i) {
    const projectfile::Script& x = a->scripts.at(i);
    const projectfile::Script& y = b->scripts.at(i);
    if (x.name != y.name || x.command != y.command || x.icon != y.icon || x.runOnWorktreeCreate != y.runOnWorktreeCreate ||
        x.async != y.async || x.previewUrl != y.previewUrl || x.autoOpenPreview != y.autoOpenPreview) {
      return false;
    }
  }
  return true;
}

void ParseHoldsItsLimits(const std::string& text) {
  const QString contents = fuzz::utf8(text);
  const std::optional<projectfile::File> file = projectfile::parse(contents);
  if (!file) return;
  fuzz::print(contents);
  EXPECT_LE(file->scripts.size(), kMaxScripts);
  EXPECT_TRUE(file->defaultThreadEnvMode.isEmpty() || file->defaultThreadEnvMode == QLatin1String("local") ||
              file->defaultThreadEnvMode == QLatin1String("worktree"))
      << file->defaultThreadEnvMode.toStdString();
  for (const projectfile::Script& script : file->scripts) {
    EXPECT_FALSE(script.name.isEmpty());
    EXPECT_EQ(script.name, script.name.trimmed());
    EXPECT_FALSE(script.command.isEmpty());
    EXPECT_EQ(script.command, script.command.trimmed());
    EXPECT_TRUE(projectfile::icons().contains(script.icon)) << script.icon.toStdString();
    EXPECT_EQ(script.previewUrl, script.previewUrl.trimmed());
  }
}
FUZZ_TEST(ProjectFile, ParseHoldsItsLimits)
    .WithDomains(fuzz::Text(kWords))
    .WithSeeds({{"{\"scripts\":[{\"name\":\"Test\",\"command\":\"bun test\",\"icon\":\"test\"}]}"},
                {"// hal-c2 project file\n{\n  \"$schema\": \"https://hal-c2.example/schema/hal-c2.json\",\n"
                 "  /* the defaults */\n  \"defaultThreadEnvMode\": \"worktree\",\n  \"worktreeSubmodules\": \"none\",\n"
                 "  \"scripts\": [\n    {\n      \"name\": \"Dev\", // the server\n      \"command\": \"bun run dev\",\n"
                 "      \"previewUrl\": \"http://localhost:3000\", \"autoOpenPreview\": true,\n    },\n  ],\n}\n"},
                {"{\"iconPath\":\"assets/logo.svg\"}"},
                {"{\"scripts\":[{\"name\":\" a \",\"command\":\"b\",\"async\":false,\"runOnWorktreeCreate\":true}]}"}});

// The writer for the structured test: a JSON value as text, with comments and
// trailing commas spliced between its tokens, where JSON allows whitespace.
// Block comments carry no `*` and line comments no newline, so the noise can
// never end a comment early or change what the file says.
struct Noise {
  std::string block;
  std::string line;
  std::uint64_t bits = 0;
  std::size_t at = 0;

  bool flip() { return (bits >> (at++ % 64)) & 1; }
  std::string maybe() {
    if (!flip()) return {};
    if (flip()) return "/*" + block + "*/";
    return "//" + line + "\n";
  }
};

std::string token(const QJsonValue& scalar) {
  const std::string bracketed = QJsonDocument(QJsonArray{scalar}).toJson(QJsonDocument::Compact).toStdString();
  return bracketed.substr(1, bracketed.size() - 2);
}

std::string spliced(const QJsonValue& value, Noise& noise) {
  if (value.isObject()) {
    const QJsonObject object = value.toObject();
    std::string out = "{" + noise.maybe();
    for (auto it = object.begin(); it != object.end(); ++it) {
      if (it != object.begin()) out += "," + noise.maybe();
      out += token(QJsonValue(it.key())) + noise.maybe() + ":" + noise.maybe() + spliced(it.value(), noise);
    }
    if (!object.isEmpty() && noise.flip()) out += "," + noise.maybe();
    return out + "}";
  }
  if (value.isArray()) {
    const QJsonArray array = value.toArray();
    std::string out = "[" + noise.maybe();
    for (qsizetype i = 0; i < array.size(); ++i) {
      if (i > 0) out += "," + noise.maybe();
      out += spliced(array.at(i), noise);
    }
    if (!array.isEmpty() && noise.flip()) out += "," + noise.maybe();
    return out + "]";
  }
  return token(value);
}

void SplicedParsesAsItsObject(const fuzz::JsonSteps& steps, const std::string& comments, std::uint64_t bits) {
  const QJsonObject root = fuzz::object(steps);
  fuzz::print(root);
  // The limits hold on the file as written.
  const bool tooManyScripts = root.value(QLatin1String("scripts")).isArray() && root.value(QLatin1String("scripts")).toArray().size() > kMaxScripts;
  const bool tooLongPath = root.value(QLatin1String("iconPath")).isString() && root.value(QLatin1String("iconPath")).toString().size() > kMaxPath;

  // Comments made of this text, with `*` and newlines taken out of them.
  std::string block = comments;
  std::string line = comments;
  for (std::string* text : {&block, &line}) {
    for (char& c : *text) {
      if (c == '\n' || c == '\r' || (text == &block && c == '*')) c = ' ';
    }
  }
  Noise noise{block, line, bits};
  const QString noisy = fuzz::utf8(spliced(root, noise));
  const QString clean = QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Compact));

  const std::optional<projectfile::File> plain = projectfile::parse(clean);
  const std::optional<projectfile::File> parsed = projectfile::parse(noisy);
  if (tooManyScripts || tooLongPath) {
    EXPECT_FALSE(plain) << "over a limit, yet parsed: " << clean.toStdString();
  }
  // Comments and trailing commas change nothing: the same file, accepted or
  // refused either way.
  EXPECT_TRUE(same(plain, parsed)) << "the same file read differently with comments: " << noisy.toStdString();
}
FUZZ_TEST(ProjectFile, SplicedParsesAsItsObject)
    .WithDomains(fuzz::Json({"$schema", "iconPath", "defaultThreadEnvMode", "worktreeSubmodules", "scripts", "name",
                             "command", "icon", "runOnWorktreeCreate", "async", "autoOpenPreview", "previewUrl"},
                            {"https://hal-c2.example/schema/hal-c2.json", "assets/logo.svg", "  padded  ", "local",
                             "worktree", "top-level", "none", "recursive", "play", "test", "lint", "configure", "build",
                             "debug", "npm test", "bun run dev", "http://localhost:3000", ""}),
                 fuzz::Text(kWords), fuzztest::Arbitrary<std::uint64_t>())
    .WithSeeds([] {
      return std::vector<std::tuple<fuzz::JsonSteps, std::string, std::uint64_t>>{
          {fuzz::steps(R"j({"defaultThreadEnvMode":"worktree","scripts":[
              {"name":"Dev","command":"bun run dev","previewUrl":"http://localhost:3000","autoOpenPreview":true},
              {"name":"Test","command":"bun test","icon":"test","runOnWorktreeCreate":true,"async":false}]})j"),
           "// the server\n/* the defaults */", 0x5555555555555555ull},
          {fuzz::steps(R"j({"$schema":"https://hal-c2.example/schema/hal-c2.json","iconPath":"assets/logo.svg"})j"), "x", 1},
          {fuzz::steps(R"j({"worktreeSubmodules":"none","scripts":[]})j"), "", 0xffffffffffffffffull},
      };
    });

}  // namespace
