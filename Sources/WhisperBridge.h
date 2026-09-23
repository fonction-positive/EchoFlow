#pragma once
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
void * lt_whisper_open(const char * path);
void lt_whisper_close(void * context);
char * lt_whisper_transcribe(void * context, const float * samples, int32_t count, const char * prompt,
                            const char * vad_path, int32_t * status);
bool lt_repetition_candidate(const char * text);
void lt_whisper_free_text(char * text);
#ifdef __cplusplus
}
#endif
