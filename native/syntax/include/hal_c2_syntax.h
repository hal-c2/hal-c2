// native/syntax's C functions (src/ffi.rs): code coloured by its language. A
// handle reads one block or file a line at a time and keeps where it got to;
// each coloured run comes back once for the light theme and once for the
// dark one, offsets in UTF-16 units from the start of all it has read.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HalC2Syntax HalC2Syntax;

typedef struct HalC2SyntaxSpan {
  uint32_t start;
  uint32_t length;
  uint32_t color;  // 0xAARRGGBB
  uint8_t theme;   // 0 light, 1 dark
  uint8_t flags;   // 1 bold, 2 italic, 4 underline
} HalC2SyntaxSpan;

typedef void (*HalC2SyntaxEmit)(void* context, const HalC2SyntaxSpan* span);

// Null for plain text and what has no syntax.
HalC2Syntax* hal_c2_syntax_for_language(const char* language, size_t len);
HalC2Syntax* hal_c2_syntax_for_path(const char* path, size_t len);
HalC2Syntax* hal_c2_syntax_clone(const HalC2Syntax* syntax);
void hal_c2_syntax_free(HalC2Syntax* syntax);
// Reads `len` bytes of UTF-8 going on from the last call. 0 once a line was
// too long to colour; nothing after it is.
uint8_t hal_c2_syntax_feed(HalC2Syntax* syntax, const char* code, size_t len, HalC2SyntaxEmit emit, void* context);

#ifdef __cplusplus
}
#endif
