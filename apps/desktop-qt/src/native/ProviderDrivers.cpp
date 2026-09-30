#include "ProviderDrivers.h"

#include <QRegularExpression>

namespace ProviderDrivers {

namespace {

using Choices = QList<QPair<QString, QString>>;

Field binaryPath(const QString& description, const QString& placeholder) {
  return {QStringLiteral("binaryPath"), QStringLiteral("Binary path"), description, placeholder};
}

const Choices kEffort{{QStringLiteral("low"), QStringLiteral("Low")},
                      {QStringLiteral("medium"), QStringLiteral("Medium")},
                      {QStringLiteral("high"), QStringLiteral("High")},
                      {QStringLiteral("xhigh"), QStringLiteral("Extra High")}};

Option effort(const QString& id) {
  return {id, QStringLiteral("Reasoning"), QStringLiteral("select"), kEffort, QStringLiteral("medium")};
}

Option flag(const QString& id, const QString& label) {
  return {id, label, QStringLiteral("boolean"), {}, {}};
}

QList<Driver> make() {
  return {
      {QStringLiteral("codex"), QStringLiteral("Codex"), {}, true,
       {binaryPath(QStringLiteral("Path to the Codex binary used by this instance."), QStringLiteral("codex")),
        {QStringLiteral("homePath"), QStringLiteral("CODEX_HOME path"), QStringLiteral("Custom Codex home and config directory."),
         QStringLiteral("~/.codex")},
        {QStringLiteral("shadowHomePath"), QStringLiteral("Shadow home path"),
         QStringLiteral("Account-specific Codex home. Keeps auth.json separate while sharing state from CODEX_HOME."),
         QStringLiteral("~/.codex-hal-c2/personal")},
        {QStringLiteral("launchArgs"), QStringLiteral("Launch arguments"),
         QStringLiteral("Additional CLI arguments passed to codex app-server on session start."), {}}},
       {},
       {effort(QStringLiteral("reasoningEffort")),
        {QStringLiteral("serviceTier"), QStringLiteral("Speed"), QStringLiteral("select"),
         {{QStringLiteral("default"), QStringLiteral("Standard")}, {QStringLiteral("fast"), QStringLiteral("Fast")}},
         QStringLiteral("default")}}},
      {QStringLiteral("claudeAgent"), QStringLiteral("Claude"), {}, true,
       {binaryPath(QStringLiteral("Path to the Claude binary used by this instance."), QStringLiteral("claude")),
        {QStringLiteral("homePath"), QStringLiteral("CLAUDE_CONFIG_DIR path"),
         QStringLiteral("Custom Claude home and config directory. Keeps .claude.json and .claude separate."), QStringLiteral("~/.claude")},
        {QStringLiteral("autoCompactWindow"), QStringLiteral("Auto-compact after"),
         QStringLiteral("Compact after 100,000 to 1,000,000 tokens. Leave empty to use Claude's default."), QStringLiteral("e.g. 300000")},
        {QStringLiteral("launchArgs"), QStringLiteral("Launch arguments"), QStringLiteral("Additional CLI arguments passed on session start."),
         QStringLiteral("e.g. --chrome")}},
       {},
       {{QStringLiteral("effort"), QStringLiteral("Reasoning"), QStringLiteral("select"),
         {{QStringLiteral("low"), QStringLiteral("Low")}, {QStringLiteral("medium"), QStringLiteral("Medium")},
          {QStringLiteral("high"), QStringLiteral("High")}, {QStringLiteral("xhigh"), QStringLiteral("Extra High")},
          {QStringLiteral("max"), QStringLiteral("Max")}},
         QStringLiteral("high")},
        flag(QStringLiteral("fastMode"), QStringLiteral("Fast Mode")),
        flag(QStringLiteral("thinking"), QStringLiteral("Thinking"))}},
      {QStringLiteral("cursor"), QStringLiteral("Cursor"), {}, true,
       {},
       {{QStringLiteral("CURSOR_API_KEY"), QStringLiteral("Cursor API key"),
         QStringLiteral("Optional. Overrides browser sign-in for this provider."), QStringLiteral("Paste API key"), true}},
       {effort(QStringLiteral("reasoning")), flag(QStringLiteral("fastMode"), QStringLiteral("Fast Mode")),
        flag(QStringLiteral("thinking"), QStringLiteral("Thinking"))}},
      {QStringLiteral("grok"), QStringLiteral("Grok"), {}, true,
       {binaryPath(QStringLiteral("Path to the Grok CLI binary."), QStringLiteral("grok"))},
       {},
       {effort(QStringLiteral("reasoningEffort"))}},
      {QStringLiteral("opencode"), QStringLiteral("OpenCode"), {}, true,
       {binaryPath(QStringLiteral("Path to the OpenCode binary."), QStringLiteral("opencode")),
        {QStringLiteral("serverUrl"), QStringLiteral("Server URL"), QStringLiteral("Leave blank to let HAL-C2 spawn the server when needed."),
         QStringLiteral("http://127.0.0.1:4096")},
        {QStringLiteral("serverPassword"), QStringLiteral("Server password"), QStringLiteral("Stored in plain text on disk."),
         QStringLiteral("Optional"), QStringLiteral("password")}},
       {},
       {effort(QStringLiteral("variant")),
        {QStringLiteral("agent"), QStringLiteral("Agent"), QStringLiteral("select"),
         {{QStringLiteral("build"), QStringLiteral("Build")}, {QStringLiteral("plan"), QStringLiteral("Plan")}}, QStringLiteral("build")}}},
      {QStringLiteral("antigravity"), QStringLiteral("Antigravity"), {}, true,
       {{QStringLiteral("authMethod"), QStringLiteral("Sign-in method"),
         QStringLiteral("Google accounts use your subscription; API keys and Agent Platform bill usage."), {}, QStringLiteral("select"),
         {{QStringLiteral("oauth-personal"), QStringLiteral("Google account")},
          {QStringLiteral("oauth-business"), QStringLiteral("Gemini Enterprise")},
          {QStringLiteral("gemini-api-key"), QStringLiteral("Gemini API key")},
          {QStringLiteral("agent-platform"), QStringLiteral("Agent Platform (Vertex AI)")}}},
        {QStringLiteral("apiKey"), QStringLiteral("API key"), QStringLiteral("Gemini or Vertex AI express key. Stored in plain text."),
         QStringLiteral("Optional"), QStringLiteral("password")},
        {QStringLiteral("gcpProject"), QStringLiteral("GCP project"),
         QStringLiteral("Required for Gemini Enterprise. Agent Platform uses it when no API key is set."), QStringLiteral("my-project-id")},
        {QStringLiteral("gcpLocation"), QStringLiteral("GCP location"), QStringLiteral("Region for Gemini Enterprise or Agent Platform."),
         QStringLiteral("us-central1")},
        {QStringLiteral("binaryPath"), QStringLiteral("Binary path"), QStringLiteral("Custom ACP executable. Leave empty to select automatically."),
         QStringLiteral("Automatic"), QStringLiteral("text"), {}, true}},
       {},
       {}},
      {QStringLiteral("pi"), QStringLiteral("Pi"), QStringLiteral("Early Access"), true,
       {binaryPath(QStringLiteral("Path to the Pi coding agent binary."), QStringLiteral("pi")),
        {QStringLiteral("launchArgs"), QStringLiteral("Launch arguments"),
         QStringLiteral("Additional CLI arguments passed to pi --mode rpc on session start."), {}}},
       {},
       {{QStringLiteral("thinking"), QStringLiteral("Thinking"), QStringLiteral("select"),
         {{QStringLiteral("off"), QStringLiteral("Off")}, {QStringLiteral("minimal"), QStringLiteral("Minimal")},
          {QStringLiteral("low"), QStringLiteral("Low")}, {QStringLiteral("medium"), QStringLiteral("Medium")},
          {QStringLiteral("high"), QStringLiteral("High")}, {QStringLiteral("xhigh"), QStringLiteral("Extra High")},
          {QStringLiteral("max"), QStringLiteral("Max")}},
         QStringLiteral("medium")}}},
      {QStringLiteral("acpRegistry"), QStringLiteral("ACP Registry"), QStringLiteral("Early Access"), false,
       {{QStringLiteral("agentId"), QStringLiteral("Registry agent ID"),
         QStringLiteral("Agent identifier from the official ACP Registry, for example 'devin'."), QStringLiteral("devin"),
         QStringLiteral("text"), {}, true},
        {QStringLiteral("commandPath"), QStringLiteral("Executable override"),
         QStringLiteral("Optional local executable to use instead of installing the registry distribution. Registry arguments and "
                        "environment are still applied."),
         QStringLiteral("Registry default")},
        {QStringLiteral("authMethodId"), QStringLiteral("Authentication method"),
         QStringLiteral("Optional ACP authentication method ID. By default, the first agent-managed method is selected."),
         QStringLiteral("auto")}},
       {},
       {}},
  };
}

}  // namespace

const QList<Driver>& all() {
  static const QList<Driver> drivers = make();
  return drivers;
}

const Driver* find(const QString& id) {
  for (const Driver& driver : all()) {
    if (driver.id == id) return &driver;
  }
  return nullptr;
}

QString slug(const QString& label) {
  static const QRegularExpression other(QStringLiteral("[^a-z0-9]+"));
  static const QRegularExpression edges(QStringLiteral("^_+|_+$"));
  return label.trimmed().toLower().replace(other, QStringLiteral("_")).remove(edges).left(48);
}

QString deriveId(const QString& driver, const QString& label, const QSet<QString>& taken) {
  const Driver* found = find(driver);
  QString base;
  if (label.trimmed().isEmpty() || (found && label == found->label)) {
    base = found && !found->builtIn ? driver + QStringLiteral("_custom") : driver;
  } else {
    const QString suffix = slug(label);
    base = suffix.isEmpty() ? QString() : driver + QLatin1Char('_') + suffix;
  }
  if (base.isEmpty() || !taken.contains(base)) return base;
  for (int number = 2;; ++number) {
    const QString suffix = QStringLiteral("_%1").arg(number);
    const QString candidate = base.left(64 - suffix.size()) + suffix;
    if (!taken.contains(candidate)) return candidate;
  }
}

QString validateId(const QString& id, const QSet<QString>& taken) {
  static const QRegularExpression pattern(QStringLiteral("^[a-zA-Z][a-zA-Z0-9_-]*$"));
  if (id.isEmpty()) return QStringLiteral("Instance ID is required.");
  if (id.size() > 64) return QStringLiteral("Instance ID must be 64 characters or fewer.");
  if (!pattern.match(id).hasMatch()) {
    return QStringLiteral("Instance ID must start with a letter and use only letters, digits, '-', or '_'.");
  }
  if (taken.contains(id)) return QStringLiteral("An instance named '%1' already exists.").arg(id);
  return {};
}

}  // namespace ProviderDrivers
