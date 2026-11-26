#pragma once

#include <QString>

#ifdef HAL_C2_HAS_FFMPEG
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/macros.h>
#include <libavutil/mem.h>
#include <libswscale/swscale.h>
}
#endif

// FFmpeg's libavcodec, libavutil and libswscale as the Device tab decodes
// with them, loaded at run time: the app is not linked to FFmpeg and ships
// none, so it starts without it and only the Device tab's screen needs it.
// The headers it builds against fix the major versions it loads (the
// structs it reads change between them): libavcodec.so.61 on Linux,
// libavcodec.61.dylib on macOS (also under Homebrew's prefixes).
//
// A build without those headers (Android's, which does not define
// HAL_C2_HAS_FFMPEG) has no decoder at all: api() is always null there.
namespace ffmpeg {

#ifndef HAL_C2_HAS_FFMPEG
struct Api;
#else
struct Api {
  decltype(&::avcodec_find_decoder) find_decoder;
  decltype(&::avcodec_alloc_context3) alloc_context3;
  decltype(&::avcodec_open2) open2;
  decltype(&::avcodec_free_context) free_context;
  decltype(&::avcodec_send_packet) send_packet;
  decltype(&::avcodec_receive_frame) receive_frame;
  decltype(&::av_packet_alloc) packet_alloc;
  decltype(&::av_packet_free) packet_free;
  decltype(&::av_packet_unref) packet_unref;
  decltype(&::av_new_packet) new_packet;
  decltype(&::av_frame_alloc) frame_alloc;
  decltype(&::av_frame_free) frame_free;
  decltype(&::av_frame_unref) frame_unref;
  decltype(&::av_frame_move_ref) frame_move_ref;
  decltype(&::av_malloc) avMalloc;
  decltype(&::av_mallocz) avMallocz;
  decltype(&::av_free) avFree;
  decltype(&::sws_getCachedContext) getCachedContext;
  decltype(&::sws_scale) scale;
  decltype(&::sws_freeContext) freeContext;
};
#endif

// The loaded libraries, or null when they are not installed. A failed load is
// tried again on the next call, so installing FFmpeg needs no restart.
const Api* api();
// What the user should do when api() is null.
QString missing();
// Tests: behave as if FFmpeg were not installed.
void pretendMissing(bool missing);

}  // namespace ffmpeg
