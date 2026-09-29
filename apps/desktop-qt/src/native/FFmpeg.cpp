#include "FFmpeg.h"

#include <QLibrary>
#include <QMutex>
#include <QMutexLocker>
#include <QStringList>

namespace ffmpeg {
namespace {

QMutex mutex;
bool pretending = false;
bool loaded = false;
Api table;
// The first library that did not load, for missing().
QString absent;

// Where `name` (avcodec, avutil, swscale) at `major` may be, most likely first.
QStringList candidates(const QString& name, int major) {
#if defined(Q_OS_MACOS)
  const QString file = QStringLiteral("lib%1.%2.dylib").arg(name).arg(major);
  // A bundle's own search path, then Homebrew on Apple silicon and Intel, then MacPorts.
  return {file,
          QStringLiteral("/opt/homebrew/opt/ffmpeg/lib/") + file,
          QStringLiteral("/opt/homebrew/lib/") + file,
          QStringLiteral("/usr/local/opt/ffmpeg/lib/") + file,
          QStringLiteral("/usr/local/lib/") + file,
          QStringLiteral("/opt/local/lib/") + file};
#elif defined(Q_OS_WIN)
  return {QStringLiteral("%1-%2.dll").arg(name).arg(major)};
#else
  return {QStringLiteral("lib%1.so.%2").arg(name).arg(major)};
#endif
}

// Loads one library, kept loaded for the life of the process.
QLibrary* open(const QString& name, int major) {
  for (const QString& candidate : candidates(name, major)) {
    auto* library = new QLibrary(candidate);
    if (library->load()) return library;
    delete library;
  }
  absent = candidates(name, major).constFirst();
  return nullptr;
}

template <typename Function>
bool resolve(QLibrary* library, Function& slot, const char* symbol) {
  slot = reinterpret_cast<Function>(library->resolve(symbol));
  if (!slot) absent = QStringLiteral("%1 in %2").arg(QLatin1String(symbol), library->fileName());
  return slot != nullptr;
}

bool load() {
  // libavutil first: the other two need it.
  QLibrary* util = open(QStringLiteral("avutil"), LIBAVUTIL_VERSION_MAJOR);
  if (!util) return false;
  QLibrary* scale = open(QStringLiteral("swscale"), LIBSWSCALE_VERSION_MAJOR);
  if (!scale) return false;
  QLibrary* codec = open(QStringLiteral("avcodec"), LIBAVCODEC_VERSION_MAJOR);
  if (!codec) return false;
  Api api{};
  const bool resolved = resolve(codec, api.find_decoder, "avcodec_find_decoder") &&
                        resolve(codec, api.alloc_context3, "avcodec_alloc_context3") && resolve(codec, api.open2, "avcodec_open2") &&
                        resolve(codec, api.free_context, "avcodec_free_context") && resolve(codec, api.send_packet, "avcodec_send_packet") &&
                        resolve(codec, api.receive_frame, "avcodec_receive_frame") && resolve(codec, api.packet_alloc, "av_packet_alloc") &&
                        resolve(codec, api.packet_free, "av_packet_free") && resolve(codec, api.packet_unref, "av_packet_unref") &&
                        resolve(codec, api.new_packet, "av_new_packet") && resolve(util, api.frame_alloc, "av_frame_alloc") &&
                        resolve(util, api.frame_free, "av_frame_free") && resolve(util, api.frame_unref, "av_frame_unref") &&
                        resolve(util, api.frame_move_ref, "av_frame_move_ref") && resolve(util, api.avMalloc, "av_malloc") &&
                        resolve(util, api.avMallocz, "av_mallocz") && resolve(util, api.avFree, "av_free") &&
                        resolve(scale, api.getCachedContext, "sws_getCachedContext") && resolve(scale, api.scale, "sws_scale") &&
                        resolve(scale, api.freeContext, "sws_freeContext");
  if (resolved) table = api;
  return resolved;
}

}  // namespace

const Api* api() {
  QMutexLocker lock(&mutex);
  if (pretending) {
    absent = candidates(QStringLiteral("avcodec"), LIBAVCODEC_VERSION_MAJOR).constFirst();
    return nullptr;
  }
  if (!loaded) loaded = load();
  return loaded ? &table : nullptr;
}

QString missing() {
  QMutexLocker lock(&mutex);
  return QStringLiteral("Install FFmpeg to watch device screens (%1 was not found).").arg(absent);
}

void pretendMissing(bool missing) {
  QMutexLocker lock(&mutex);
  pretending = missing;
}

}  // namespace ffmpeg
