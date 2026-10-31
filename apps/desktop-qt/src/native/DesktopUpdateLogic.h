#pragma once

#include <QIODevice>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QStringList>
#include <QUrl>

#include <optional>

// The desktop app's own updates, the pure half: the state the update button
// shows and the steps that change it (upstream apps/desktop/src/updates/
// updateMachine.ts), which releases a track offers, release notes as the
// popover lists them (releaseNotes.ts), what a server-asked update does next
// (remoteUpdateFlow.ts), and the button's words (apps/web desktopUpdate.logic.ts).
// DesktopUpdater runs it. An empty string stands for upstream's null.
namespace desktopUpdate {

inline const QString kStable = QStringLiteral("latest");
inline const QString kNightly = QStringLiteral("nightly");

struct ReleaseNote {
  QString version;
  // At most eight, the last ones of the release, newest first.
  QStringList items;
  int totalItems = 0;
  bool operator==(const ReleaseNote&) const = default;
};

struct State {
  bool enabled = false;
  // disabled, idle, checking, up-to-date, available, downloading, downloaded, error
  QString status = QStringLiteral("disabled");
  QString channel = kStable;
  QString currentVersion;
  QString hostArch;
  QString appArch;
  bool runningUnderArm64Translation = false;
  QString availableVersion;
  QString downloadedVersion;
  QList<ReleaseNote> releaseNotes;
  int omittedReleaseCount = 0;
  // -1: none.
  int downloadPercent = -1;
  QString checkedAt;
  QString message;
  // check, download or install: the step that failed.
  QString errorContext;
  bool canRetry = false;

  bool operator==(const State&) const = default;
  // The contracts' DesktopUpdateState.
  QJsonObject toJson() const;
};

// "nightly" for a nightly build's version (1.4.0-nightly.20260101.3), else "latest".
QString channelOf(const QString& version);
// Orders versions as semver does: <0, 0, >0.
int compareVersions(const QString& a, const QString& b);

State initial(const QString& currentVersion, const QString& channel, bool enabled);
State onCheckStart(State state, const QString& checkedAt);
State onCheckFailure(State state, const QString& message, const QString& checkedAt);
State onUpdateAvailable(State state, const QString& version, const QString& checkedAt,
                        const QList<ReleaseNote>& notes = {}, int omitted = 0);
State onNoUpdate(State state, const QString& checkedAt);
State onDownloadStart(State state);
State onDownloadFailure(State state, const QString& message);
State onDownloadProgress(State state, int percent);
State onDownloadComplete(State state, const QString& version);
State onInstallFailure(State state, const QString& message);
// Whether a new percent changes what is shown: a whole ten percent, or done.
bool showsProgress(const State& state, int percent);

// A release of the update feed (a GitHub releases list).
struct Release {
  QString version;
  QString notes;
  bool prerelease = false;
  // The asset this machine installs.
  QUrl asset;
  qint64 size = 0;
  // The asset's published digest, lowercase hex.
  QString sha256;
};
// The feed's releases that are not drafts and have an asset for `platform`
// (linux, macos) and `arch` (x64, arm64), newest first. The app runs what it
// downloads, so an asset that is not https or has no sha256 digest does not count.
QList<Release> parseFeed(const QByteArray& json, const QString& platform, const QString& arch);
// Whether what `file` holds from its current position has the digest.
bool matchesDigest(QIODevice& file, const QString& sha256);

struct Offer {
  Release release;
  QList<ReleaseNote> notes;
  int omitted = 0;
};
// The release `channel` offers a build at `currentVersion`: the newest of the
// track when it is newer, or, with `allowDowngrade`, when it is another.
std::optional<Offer> select(const QList<Release>& releases, const QString& currentVersion, const QString& channel,
                            bool allowDowngrade);

// Release notes as plain lines: markup and GitHub boilerplate gone, each
// cut at 220 characters, releases of another track and empty ones left out,
// six at most.
struct Notes {
  QList<ReleaseNote> releaseNotes;
  int omittedReleaseCount = 0;
};
struct NoteSource {
  QString version;
  QString note;
};
Notes normalizeReleaseNotes(const QList<NoteSource>& notes, const QString& channel);

// A server-asked update's next step.
struct RemoteStep {
  enum Kind { Check, Download, Install, Wait, Done, Failed } kind = Wait;
  // Done: up-to-date. Failed: why.
  QString reason;
};
RemoteStep nextRemoteStep(const State& state, int checks, int downloads, const QString& disabledReason);

// Whether the downloaded update can be installed now.
bool installable(const State& state);
// The update button: what a press does (install, download, none).
QString buttonAction(const State& state);
QString tooltip(const State& state);
// What the button says when pointed at.
QString label(const State& state);
bool showsDetails(const State& state);
bool canCheck(const State& state);
QString confirmationTitle(const State& state);
inline const QString kConfirmationDetail =
    QStringLiteral("Any running tasks will be interrupted. Make sure you're ready before continuing.");
bool showsIntelWarning(const State& state);
QString intelWarning(const State& state);
QString releaseUrl(const QString& version);
inline const QString kReleaseHistoryUrl = QStringLiteral("https://github.com/hal-c2/hal-c2/releases");
// The nightly popover (empty when there is none): {header, groups:[{title,
// version, items, link, url}], footer, footerUrl}.
QJsonObject popover(const State& state);

}  // namespace desktopUpdate
