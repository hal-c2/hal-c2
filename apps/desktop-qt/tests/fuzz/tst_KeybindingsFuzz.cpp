// The keymap's parsers (Keybindings.h) against any text: the shortcut and `when`
// strings and the rules of a keybindings.json the user edits by hand, which the
// MC passes on as it is. Besides not crashing, what the shell writes back must
// read the same: the settings page saves keyText() and whenText().

#include "Fuzz.h"
#include "Keybindings.h"

#include <QSet>

#include <string>
#include <tuple>
#include <vector>

using namespace halc2;

namespace {

// What the parsers look for, so the engine can splice them in.
const std::vector<std::string> kKeyWords{"mod", "cmd", "meta", "ctrl", "control", "shift", "alt", "option",
                                         "space", "esc", "escape", "+", "++", " ", "arrowup", "enter",
                                         "[", "]", "=", "-", "k", "F5", "A"};
const std::vector<std::string> kWhenWords{"&&", "||", "!", "(", ")", " ", "true", "false", "terminalFocus",
                                          "previewFocus", "composerFocus", "a.b-c_d", "x"};

void ShortcutReadsBackAsWritten(const std::string& text) {
  const auto shortcut = keybindings::parseShortcut(fuzz::utf8(text));
  if (!shortcut) return;
  for (const bool mac : {false, true}) {
    keybindings::sequence(*shortcut, mac);
    keybindings::label(*shortcut, mac);
  }
  const QString written = keybindings::keyText(*shortcut);
  const auto reread = keybindings::parseShortcut(written);
  ASSERT_TRUE(reread.has_value()) << "keyText wrote " << written.toStdString();
  EXPECT_EQ(*reread, *shortcut) << "keyText wrote " << written.toStdString();
}
FUZZ_TEST(Keybindings, ShortcutReadsBackAsWritten)
    .WithDomains(fuzz::Text(kKeyWords))
    .WithSeeds({{"mod+shift+["}, {"mod++"}, {"ctrl+alt+space"}, {"cmd+esc"}, {"alt+arrowup"}, {"MOD + K"}});

// The identifiers a condition names, true or false by the bits of `truths`.
keybindings::Context contextOf(const keybindings::WhenPtr& when, std::uint64_t truths, keybindings::Context context = {}) {
  if (!when) return context;
  if (when->kind == keybindings::When::Kind::Identifier) {
    if (!context.contains(when->name)) context.insert(when->name, (truths >> (context.size() % 64)) & 1);
    return context;
  }
  return contextOf(when->right, truths, contextOf(when->left, truths, std::move(context)));
}

void ConditionReadsBackAsWritten(const std::string& text, std::uint64_t truths) {
  const keybindings::WhenPtr when = keybindings::parseWhen(fuzz::utf8(text));
  if (!when) return;
  const QString written = keybindings::whenText(when);
  const keybindings::WhenPtr reread = keybindings::parseWhen(written);
  ASSERT_TRUE(reread) << "whenText wrote " << written.toStdString();
  EXPECT_EQ(keybindings::whenText(reread), written);
  const keybindings::Context context = contextOf(when, truths);
  EXPECT_EQ(keybindings::evaluate(reread, context), keybindings::evaluate(when, context));
}
FUZZ_TEST(Keybindings, ConditionReadsBackAsWritten)
    .WithDomains(fuzz::Text(kWhenWords), fuzztest::Arbitrary<std::uint64_t>())
    .WithSeeds({{"!terminalFocus", 0}, {"a && (b || !c)", 5}, {"!(a || b) && c || d", 9}, {"((x))", 1}});

// A keybindings.json's rules (an array of {key, command, when}) merged over the
// defaults, then every merged shortcut resolved as the window would.
void RulesResolve(const fuzz::JsonSteps& rules, std::uint64_t truths) {
  const QJsonArray json = fuzz::array(rules);
  fuzz::print(json);
  const QList<keybindings::Binding> bindings = keybindings::merge(json);
  for (const bool mac : {false, true}) {
    for (const keybindings::Binding& binding : bindings) {
      ASSERT_TRUE(keybindings::isCommand(binding.command)) << binding.command.toStdString();
      keybindings::label(binding.shortcut, mac);
      keybindings::whenText(binding.when);
      keybindings::commandLabel(binding.command);
      // The defaults' shortcuts resolve the same every time; only the user's are new.
      if (keybindings::defaults().contains(binding.rule)) continue;
      const QString sequence = keybindings::sequence(binding.shortcut, mac);
      if (sequence.isEmpty()) continue;
      const QString command = keybindings::resolve(bindings, sequence, contextOf(binding.when, truths), mac);
      EXPECT_TRUE(command.isEmpty() || keybindings::isCommand(command)) << command.toStdString();
    }
  }
}
FUZZ_TEST(Keybindings, RulesResolve)
    .WithDomains(fuzz::Json({"key", "command", "when"},
                            {"mod+k", "mod+shift+d", "alt+arrowup", "commandPalette.toggle", "terminal.split",
                             "script.test-1.run", "thread.jump.3", "!terminalFocus", "terminalFocus && previewFocus"}),
                 fuzztest::Arbitrary<std::uint64_t>())
    .WithSeeds([] {
      return std::vector<std::tuple<fuzz::JsonSteps, std::uint64_t>>{
          {fuzz::steps(R"j([{"key":"mod+k","command":"terminal.split","when":"terminalFocus"},
                           {"key":"mod+shift+d","command":"script.test-1.run"},
                           {"key":"alt+arrowup","command":"thread.jump.3","when":"!terminalFocus && composerFocus"}])j"),
           1},
          {fuzz::steps(R"j([{"key":"mod+k","command":"commandPalette.toggle","when":"!(a || b)"},
                           {"key":"nope","command":"sidebar.toggle"}, 3, null])j"),
           0},
      };
    });

}  // namespace
