#include "DesktopUpdateLogic.h"

#include <QHash>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QVersionNumber>

#include <algorithm>

namespace desktopUpdate {

namespace {

constexpr int kMaxGroups = 6;
constexpr int kMaxItems = 8;
constexpr int kMaxItemLength = 220;
constexpr int kMaxRemoteChecks = 2;
constexpr int kMaxRemoteDownloads = 3;

QJsonValue orNull(const QString& value) {
  return value.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(value);
}

// "1.4.0" as the button says it: "v1.4.0".
QString shown(const QString& version) {
  return version.startsWith(QLatin1Char('v')) ? version : QStringLiteral("v") + version;
}

QString decodeEntity(const QString& entity) {
  static const QHash<QString, QString> named{{QStringLiteral("amp"), QStringLiteral("&")},
                                             {QStringLiteral("apos"), QStringLiteral("'")},
                                             {QStringLiteral("gt"), QStringLiteral(">")},
                                             {QStringLiteral("lt"), QStringLiteral("<")},
                                             {QStringLiteral("nbsp"), QStringLiteral(" ")},
                                             {QStringLiteral("quot"), QStringLiteral("\"")}};
  if (named.contains(entity)) return named.value(entity);
  bool ok = false;
  qlonglong code = -1;
  if (entity.startsWith(QLatin1String("#x"))) {
    code = entity.mid(2).toLongLong(&ok, 16);
  } else if (entity.startsWith(QLatin1Char('#'))) {
    code = entity.mid(1).toLongLong(&ok, 10);
  }
  if (!ok || code < 0 || code > 0x10ffff) return QLatin1Char('&') + entity + QLatin1Char(';');
  const char32_t point = char32_t(code);
  return QString::fromUcs4(&point, 1);
}

QString stripMarkup(QString text) {
  const auto ci = QRegularExpression::CaseInsensitiveOption;
  text.replace(QRegularExpression(QStringLiteral("<br\\s*/?>"), ci), QStringLiteral("\n"));
  text.replace(QRegularExpression(QStringLiteral("<li\\b[^>]*>"), ci), QStringLiteral("\n- "));
  static const QRegularExpression heading(QStringLiteral("<h([1-6])\\b[^>]*>"), ci);
  for (auto match = heading.match(text); match.hasMatch(); match = heading.match(text, match.capturedStart())) {
    text.replace(match.capturedStart(), match.capturedLength(),
                 QStringLiteral("\n") + QString(match.captured(1).toInt(), QLatin1Char('#')) + QLatin1Char(' '));
  }
  text.replace(QRegularExpression(QStringLiteral("</(?:p|div|li|h[1-6]|ul|ol|blockquote)>"), ci), QStringLiteral("\n"));
  text.replace(QRegularExpression(QStringLiteral("<[^>]*>")), QString());
  text.replace(QRegularExpression(QStringLiteral("\\[([^\\]]+)\\]\\([^)]+\\)")), QStringLiteral("\\1"));
  text.replace(QRegularExpression(QStringLiteral("\\*\\*([^*]+)\\*\\*")), QStringLiteral("\\1"));
  static const QRegularExpression entity(QStringLiteral("&([a-zA-Z]+|#\\d+|#x[0-9a-fA-F]+);"));
  QString decoded;
  qsizetype from = 0;
  for (auto it = entity.globalMatch(text); it.hasNext();) {
    const auto match = it.next();
    decoded += text.mid(from, match.capturedStart() - from) + decodeEntity(match.captured(1));
    from = match.capturedEnd();
  }
  return decoded + text.mid(from);
}

QString normalizedLine(const QString& line) {
  static const QRegularExpression marks(QStringLiteral("[*_`#]"));
  return line.toLower().remove(marks).trimmed();
}

ReleaseNote extractItems(const QString& version, const QString& note) {
  ReleaseNote result{version, {}, 0};
  static const QRegularExpression bullet(QStringLiteral("^[-*]\\s+"));
  static const QRegularExpression numbered(QStringLiteral("^\\d+[.)]\\s+"));
  static const QRegularExpression spaces(QStringLiteral("\\s+"));
  static const QRegularExpression headingLine(QStringLiteral("^#{1,6}\\s+"));
  for (const QString& raw : stripMarkup(note).split(QLatin1Char('\n'))) {
    QString item = raw.trimmed();
    item.remove(bullet).remove(numbered).replace(spaces, QStringLiteral(" "));
    const QString normalized = normalizedLine(item);
    if (normalized == QLatin1String("new contributors") || normalized == QLatin1String("full changelog")) break;
    if (headingLine.match(item).hasMatch()) continue;
    if (normalized.isEmpty() || normalized == QLatin1String("what's changed") || normalized == QLatin1String("whats changed") ||
        normalized.startsWith(QLatin1String("compare: ")) || normalized.contains(QLatin1String("/compare/"))) {
      continue;
    }
    result.totalItems++;
    if (item.size() > kMaxItemLength) {
      QString cut = item.left(kMaxItemLength - 3);
      while (!cut.isEmpty() && cut.back().isSpace()) cut.chop(1);
      item = cut + QStringLiteral("...");
    }
    result.items.append(item);
    if (result.items.size() > kMaxItems) result.items.removeFirst();
  }
  std::reverse(result.items.begin(), result.items.end());
  return result;
}

// major.minor.patch and the dot-separated prerelease after "-".
struct Semver {
  QVersionNumber core;
  QStringList pre;
};

Semver parse(QString version) {
  if (version.startsWith(QLatin1Char('v'))) version.remove(0, 1);
  version = version.section(QLatin1Char('+'), 0, 0);
  const qsizetype dash = version.indexOf(QLatin1Char('-'));
  Semver semver{QVersionNumber::fromString(dash < 0 ? version : version.left(dash)), {}};
  if (dash >= 0) semver.pre = version.mid(dash + 1).split(QLatin1Char('.'));
  return semver;
}

}  // namespace

QJsonObject State::toJson() const {
  QJsonArray notes;
  for (const ReleaseNote& note : releaseNotes) {
    notes.append(QJsonObject{{QStringLiteral("version"), note.version},
                             {QStringLiteral("items"), QJsonArray::fromStringList(note.items)},
                             {QStringLiteral("totalItems"), note.totalItems}});
  }
  return {{QStringLiteral("enabled"), enabled},
          {QStringLiteral("status"), status},
          {QStringLiteral("channel"), channel},
          {QStringLiteral("currentVersion"), currentVersion},
          {QStringLiteral("hostArch"), hostArch},
          {QStringLiteral("appArch"), appArch},
          {QStringLiteral("runningUnderArm64Translation"), runningUnderArm64Translation},
          {QStringLiteral("availableVersion"), orNull(availableVersion)},
          {QStringLiteral("downloadedVersion"), orNull(downloadedVersion)},
          {QStringLiteral("releaseNotes"), notes},
          {QStringLiteral("omittedReleaseCount"), omittedReleaseCount},
          {QStringLiteral("downloadPercent"), downloadPercent < 0 ? QJsonValue(QJsonValue::Null) : QJsonValue(downloadPercent)},
          {QStringLiteral("checkedAt"), orNull(checkedAt)},
          {QStringLiteral("message"), orNull(message)},
          {QStringLiteral("errorContext"), orNull(errorContext)},
          {QStringLiteral("canRetry"), canRetry}};
}

QString channelOf(const QString& version) {
  static const QRegularExpression nightly(QStringLiteral("^[^-+]+-nightly\\.\\d{8}\\.\\d+$"));
  return nightly.match(version).hasMatch() ? kNightly : kStable;
}

int compareVersions(const QString& a, const QString& b) {
  const Semver left = parse(a), right = parse(b);
  if (const int core = QVersionNumber::compare(left.core, right.core)) return core < 0 ? -1 : 1;
  // A prerelease comes before its release.
  if (left.pre.isEmpty() || right.pre.isEmpty()) return int(left.pre.isEmpty()) - int(right.pre.isEmpty());
  for (qsizetype i = 0; i < std::min(left.pre.size(), right.pre.size()); ++i) {
    bool leftNumeric = false, rightNumeric = false;
    const qulonglong l = left.pre[i].toULongLong(&leftNumeric), r = right.pre[i].toULongLong(&rightNumeric);
    if (leftNumeric && rightNumeric) {
      if (l != r) return l < r ? -1 : 1;
    } else if (leftNumeric != rightNumeric) {
      return leftNumeric ? -1 : 1;
    } else if (const int text = left.pre[i].compare(right.pre[i])) {
      return text < 0 ? -1 : 1;
    }
  }
  return left.pre.size() == right.pre.size() ? 0 : (left.pre.size() < right.pre.size() ? -1 : 1);
}

State initial(const QString& currentVersion, const QString& channel, bool enabled) {
  State state;
  state.currentVersion = currentVersion;
  state.channel = channel;
  state.enabled = enabled;
  state.status = enabled ? QStringLiteral("idle") : QStringLiteral("disabled");
  return state;
}

State onCheckStart(State state, const QString& checkedAt) {
  const bool downloaded = !state.downloadedVersion.isEmpty();
  state.status = QStringLiteral("checking");
  state.checkedAt = checkedAt;
  if (!downloaded) {
    state.releaseNotes.clear();
    state.omittedReleaseCount = 0;
  }
  state.message.clear();
  state.downloadPercent = downloaded ? 100 : -1;
  state.errorContext.clear();
  state.canRetry = false;
  return state;
}

State onCheckFailure(State state, const QString& message, const QString& checkedAt) {
  state.checkedAt = checkedAt;
  state.canRetry = true;
  if (!state.downloadedVersion.isEmpty()) {
    state.status = QStringLiteral("downloaded");
    state.message.clear();
    state.downloadPercent = 100;
    state.errorContext.clear();
    return state;
  }
  state.status = QStringLiteral("error");
  state.message = message;
  state.downloadPercent = -1;
  state.errorContext = QStringLiteral("check");
  return state;
}

State onUpdateAvailable(State state, const QString& version, const QString& checkedAt, const QList<ReleaseNote>& notes,
                        int omitted) {
  const bool downloaded = state.downloadedVersion == version;
  const bool keepNotes = downloaded && notes.isEmpty();
  state.status = downloaded ? QStringLiteral("downloaded") : QStringLiteral("available");
  state.availableVersion = version;
  state.downloadedVersion = downloaded ? version : QString();
  if (!keepNotes) {
    state.releaseNotes = notes;
    state.omittedReleaseCount = omitted;
  }
  state.downloadPercent = downloaded ? 100 : -1;
  state.checkedAt = checkedAt;
  state.message.clear();
  state.errorContext.clear();
  state.canRetry = downloaded;
  return state;
}

State onNoUpdate(State state, const QString& checkedAt) {
  state.checkedAt = checkedAt;
  state.message.clear();
  state.errorContext.clear();
  if (!state.downloadedVersion.isEmpty()) {
    state.status = QStringLiteral("downloaded");
    state.availableVersion = state.downloadedVersion;
    state.downloadPercent = 100;
    state.canRetry = true;
    return state;
  }
  state.status = QStringLiteral("up-to-date");
  state.availableVersion.clear();
  state.downloadedVersion.clear();
  state.releaseNotes.clear();
  state.omittedReleaseCount = 0;
  state.downloadPercent = -1;
  state.canRetry = false;
  return state;
}

State onDownloadStart(State state) {
  state.status = QStringLiteral("downloading");
  state.downloadPercent = 0;
  state.message.clear();
  state.errorContext.clear();
  state.canRetry = false;
  return state;
}

State onDownloadFailure(State state, const QString& message) {
  state.status = state.availableVersion.isEmpty() ? QStringLiteral("error") : QStringLiteral("available");
  state.message = message;
  state.downloadPercent = -1;
  state.errorContext = QStringLiteral("download");
  state.canRetry = !state.availableVersion.isEmpty();
  return state;
}

State onDownloadProgress(State state, int percent) {
  state.status = QStringLiteral("downloading");
  state.downloadPercent = percent;
  state.message.clear();
  state.errorContext.clear();
  state.canRetry = false;
  return state;
}

State onDownloadComplete(State state, const QString& version) {
  state.status = QStringLiteral("downloaded");
  state.availableVersion = version;
  state.downloadedVersion = version;
  state.downloadPercent = 100;
  state.message.clear();
  state.errorContext.clear();
  state.canRetry = true;
  return state;
}

State onInstallFailure(State state, const QString& message) {
  state.status = QStringLiteral("downloaded");
  state.message = message;
  state.errorContext = QStringLiteral("install");
  state.canRetry = true;
  return state;
}

bool showsProgress(const State& state, int percent) {
  if (state.status != QLatin1String("downloading") || state.downloadPercent < 0) return true;
  return state.downloadPercent / 10 != percent / 10 || percent == 100;
}

namespace {

// GitHub's `digest` of a release asset, "sha256:<hex>"; "" without a usable one.
QString digestOf(const QJsonObject& asset) {
  static const QRegularExpression sha256(QStringLiteral("^sha256:([0-9a-fA-F]{64})$"));
  return sha256.match(asset.value(QLatin1String("digest")).toString()).captured(1).toLower();
}

}  // namespace

bool matchesDigest(const QCryptographicHash& hash, const QString& sha256) {
  return QString::fromLatin1(hash.resultView().toByteArray().toHex()) == sha256;
}

QList<Release> parseFeed(const QByteArray& json, const QString& platform, const QString& arch) {
  QList<Release> releases;
  for (const QJsonValue& value : QJsonDocument::fromJson(json).array()) {
    const QJsonObject release = value.toObject();
    if (release.value(QLatin1String("draft")).toBool()) continue;
    QString version = release.value(QLatin1String("tag_name")).toString();
    if (version.startsWith(QLatin1Char('v'))) version.remove(0, 1);
    if (version.isEmpty()) continue;
    // The AppImage, or the macOS zip: this arch's when there are several.
    QJsonObject chosen;
    for (const QJsonValue& assetValue : release.value(QLatin1String("assets")).toArray()) {
      const QJsonObject asset = assetValue.toObject();
      if (QUrl(asset.value(QLatin1String("browser_download_url")).toString()).scheme() != QLatin1String("https") ||
          digestOf(asset).isEmpty()) {
        continue;
      }
      const QString name = asset.value(QLatin1String("name")).toString().toLower();
      const bool fits = platform == QLatin1String("linux") ? name.endsWith(QLatin1String(".appimage"))
                        : platform == QLatin1String("macos") ? name.endsWith(QLatin1String(".zip")) && name.contains(QLatin1String("macos"))
                                                              : false;
      if (!fits) continue;
      const bool archNamed = name.contains(QLatin1String("arm64")) || name.contains(QLatin1String("x64")) ||
                             name.contains(QLatin1String("x86_64"));
      const bool ours = !archNamed || name.contains(arch) || (arch == QLatin1String("x64") && name.contains(QLatin1String("x86_64")));
      if (ours && (chosen.isEmpty() || archNamed)) chosen = asset;
    }
    if (chosen.isEmpty()) continue;
    releases.append({version, release.value(QLatin1String("body")).toString(), release.value(QLatin1String("prerelease")).toBool(),
                     QUrl(chosen.value(QLatin1String("browser_download_url")).toString()),
                     qint64(chosen.value(QLatin1String("size")).toDouble()), digestOf(chosen)});
  }
  std::stable_sort(releases.begin(), releases.end(),
                   [](const Release& a, const Release& b) { return compareVersions(a.version, b.version) > 0; });
  return releases;
}

std::optional<Offer> select(const QList<Release>& releases, const QString& currentVersion, const QString& channel,
                            bool allowDowngrade) {
  QList<Release> track;
  for (const Release& release : releases) {
    const bool onTrack = channel == kNightly ? channelOf(release.version) == kNightly
                                             : !release.prerelease && !release.version.contains(QLatin1Char('-'));
    if (onTrack) track.append(release);
  }
  std::stable_sort(track.begin(), track.end(),
                   [](const Release& a, const Release& b) { return compareVersions(a.version, b.version) > 0; });
  if (track.isEmpty()) return std::nullopt;
  const Release& newest = track.first();
  const int order = compareVersions(newest.version, currentVersion);
  if (order < 0 && !allowDowngrade) return std::nullopt;
  if (order == 0) return std::nullopt;
  // Nightly lists every release since this build (its full changelog);
  // stable, the offered one's.
  QList<NoteSource> sources;
  for (const Release& release : track) {
    if (&release != &newest && (channel != kNightly || compareVersions(release.version, currentVersion) <= 0)) continue;
    sources.append({release.version, release.notes});
  }
  const Notes notes = normalizeReleaseNotes(sources, channel);
  return Offer{newest, notes.releaseNotes, notes.omittedReleaseCount};
}

Notes normalizeReleaseNotes(const QList<NoteSource>& sources, const QString& channel) {
  QList<ReleaseNote> notes;
  for (const NoteSource& source : sources) {
    if (channelOf(source.version) != channel) continue;
    ReleaseNote note = extractItems(source.version, source.note);
    if (note.totalItems > 0) notes.append(note);
  }
  Notes result;
  result.omittedReleaseCount = int(std::max<qsizetype>(0, notes.size() - kMaxGroups));
  result.releaseNotes = notes.mid(0, kMaxGroups);
  return result;
}

RemoteStep nextRemoteStep(const State& state, int checks, int downloads, const QString& disabledReason) {
  const auto failed = [](const QString& reason, const QString& fallback) {
    const QString trimmed = reason.trimmed();
    return RemoteStep{RemoteStep::Failed, trimmed.isEmpty() ? fallback : trimmed};
  };
  if (!state.enabled || state.status == QLatin1String("disabled")) {
    return failed(disabledReason, QStringLiteral("Automatic updates are disabled on this machine."));
  }
  if (installable(state)) return {RemoteStep::Install, {}};
  if (state.status == QLatin1String("downloading") || state.status == QLatin1String("checking")) return {RemoteStep::Wait, {}};
  if (state.status == QLatin1String("available")) {
    if (downloads >= kMaxRemoteDownloads) return failed(state.message, QStringLiteral("The desktop app failed to download the update."));
    return {RemoteStep::Download, {}};
  }
  // An earlier check's answer is stale: a request looks again first.
  if (state.status == QLatin1String("up-to-date")) {
    return checks == 0 ? RemoteStep{RemoteStep::Check, {}} : RemoteStep{RemoteStep::Done, QStringLiteral("up-to-date")};
  }
  if (state.status == QLatin1String("error")) {
    return checks == 0 ? RemoteStep{RemoteStep::Check, {}} : failed(state.message, QStringLiteral("The desktop app update failed."));
  }
  if (checks >= kMaxRemoteChecks) return {RemoteStep::Failed, QStringLiteral("The desktop app did not report an update result.")};
  return {RemoteStep::Check, {}};
}

bool installable(const State& state) {
  return !state.downloadedVersion.isEmpty() &&
         (state.status == QLatin1String("downloaded") ||
          (state.status == QLatin1String("error") &&
           (state.errorContext.isEmpty() || state.errorContext == QLatin1String("install"))));
}

QString buttonAction(const State& state) {
  if (installable(state)) return QStringLiteral("install");
  if (state.status == QLatin1String("available")) return QStringLiteral("download");
  if (state.status == QLatin1String("error") && state.errorContext == QLatin1String("download") && !state.availableVersion.isEmpty()) {
    return QStringLiteral("download");
  }
  return QStringLiteral("none");
}

// getDesktopUpdateButtonTooltip, except that a failed download or install
// says so first: their reducers leave the status available or downloaded.
QString tooltip(const State& state) {
  if (state.errorContext == QLatin1String("download") && !state.availableVersion.isEmpty()) {
    return QStringLiteral("Download failed for %1. Click to retry.").arg(shown(state.availableVersion));
  }
  if (state.errorContext == QLatin1String("install") && !state.downloadedVersion.isEmpty()) {
    return QStringLiteral("Install failed for %1. Click to retry.").arg(shown(state.downloadedVersion));
  }
  if (state.status == QLatin1String("available")) {
    return QStringLiteral("Update %1 ready to download")
        .arg(state.availableVersion.isEmpty() ? QStringLiteral("available") : shown(state.availableVersion));
  }
  if (state.status == QLatin1String("downloading")) {
    return state.downloadPercent < 0 ? QStringLiteral("Downloading update")
                                     : QStringLiteral("Downloading update (%1%)").arg(state.downloadPercent);
  }
  const QString downloaded = !state.downloadedVersion.isEmpty() ? shown(state.downloadedVersion)
                             : !state.availableVersion.isEmpty() ? shown(state.availableVersion)
                                                                 : QStringLiteral("ready");
  if (state.status == QLatin1String("downloaded") || (state.status == QLatin1String("error") && !state.downloadedVersion.isEmpty())) {
    return QStringLiteral("Update %1 downloaded. Click to restart and install.").arg(downloaded);
  }
  if (state.status == QLatin1String("error")) return state.message.isEmpty() ? QStringLiteral("Update failed") : state.message;
  return QStringLiteral("Up to date");
}

bool showsDetails(const State& state) {
  return buttonAction(state) != QLatin1String("none") || state.status == QLatin1String("downloading");
}

QString label(const State& state) {
  if (showsDetails(state)) return tooltip(state);
  return state.status == QLatin1String("checking") ? QStringLiteral("Checking for updates…") : QStringLiteral("Check for updates");
}

bool canCheck(const State& state) {
  return state.enabled && state.status != QLatin1String("checking") && state.status != QLatin1String("downloading") &&
         state.status != QLatin1String("disabled");
}

QString confirmationTitle(const State& state) {
  const QString version = !state.downloadedVersion.isEmpty() ? state.downloadedVersion : state.availableVersion;
  return version.isEmpty() ? QStringLiteral("Install update and restart HAL-C2?")
                           : QStringLiteral("Install update %1 and restart HAL-C2?").arg(shown(version));
}

bool showsIntelWarning(const State& state) {
  return state.hostArch == QLatin1String("arm64") && state.appArch == QLatin1String("x64");
}

QString intelWarning(const State& state) {
  if (!showsIntelWarning(state)) return {};
  const QString prefix = QStringLiteral("This Mac has Apple Silicon, but HAL-C2 is still running the Intel build under Rosetta.");
  const QString action = buttonAction(state);
  if (action == QLatin1String("download")) return prefix + QStringLiteral(" Download the available update to switch to the native Apple Silicon build.");
  if (action == QLatin1String("install")) return prefix + QStringLiteral(" Restart to install the downloaded Apple Silicon build.");
  return prefix + QStringLiteral(" The next app update will replace it with the native Apple Silicon build.");
}

QString releaseUrl(const QString& version) {
  const QString trimmed = version.trimmed();
  if (trimmed.isEmpty()) return {};
  return kReleaseHistoryUrl + QStringLiteral("/tag/v") + QString::fromUtf8(QUrl::toPercentEncoding(trimmed));
}

QJsonObject popover(const State& state) {
  if (!showsDetails(state) || state.channel != kNightly || state.releaseNotes.isEmpty()) return {};
  QJsonArray groups;
  for (qsizetype i = 0; i < state.releaseNotes.size(); ++i) {
    const ReleaseNote& note = state.releaseNotes.at(i);
    const int more = note.totalItems - int(note.items.size());
    groups.append(QJsonObject{
        {QStringLiteral("title"), i == 0 ? QStringLiteral("What's changed") : QStringLiteral("Changes in %1").arg(note.version)},
        {QStringLiteral("version"), note.version},
        {QStringLiteral("items"), QJsonArray::fromStringList(note.items)},
        {QStringLiteral("link"), more <= 0 ? QStringLiteral("View release on GitHub")
                                           : QStringLiteral("%1 more %2 on GitHub").arg(more).arg(more == 1 ? QStringLiteral("change") : QStringLiteral("changes"))},
        {QStringLiteral("url"), releaseUrl(note.version)}});
  }
  QJsonObject view{{QStringLiteral("header"), state.status == QLatin1String("available") && !state.availableVersion.isEmpty()
                                                  ? QStringLiteral("Update ready to download")
                                                  : tooltip(state)},
                   {QStringLiteral("version"), state.status == QLatin1String("available") ? state.availableVersion : QString()},
                   {QStringLiteral("groups"), groups}};
  if (state.omittedReleaseCount > 0) {
    view.insert(QStringLiteral("footer"), QStringLiteral("%1 older %2 on GitHub")
                                              .arg(state.omittedReleaseCount)
                                              .arg(state.omittedReleaseCount == 1 ? QStringLiteral("release") : QStringLiteral("releases")));
    view.insert(QStringLiteral("footerUrl"), kReleaseHistoryUrl);
  }
  return view;
}

}  // namespace desktopUpdate
