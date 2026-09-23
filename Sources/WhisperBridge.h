#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void * lt_whisper_open(const char * path);
void lt_whisper_close(void * context);
char * lt_whisper_transcribe(void * context, const float * samples, int32_t count, const char * prompt);
void lt_whisper_free_text(char * text);
#ifdef __cplusplus
}
#endif
