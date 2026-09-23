#include "WhisperBridge.h"
#include "whisper.h"
#include "DecoderValidation.h"
#include <cstdlib>
#include <cstring>
#include <string>

void * lt_whisper_open(const char * path) {
    auto params = whisper_context_default_params();
    params.use_gpu = true;
    return whisper_init_from_file_with_params(path, params);
}

void lt_whisper_close(void * context) {
    if (context) whisper_free(static_cast<whisper_context *>(context));
}

bool lt_repetition_candidate(const char * text) { return echoflow_repetition_candidate(text); }

char * lt_whisper_transcribe(void * context, const float * samples, int32_t count, const char * prompt,
                            const char * vad_path, int32_t * status) {
    auto ctx = static_cast<whisper_context *>(context);
    auto params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
    params.n_threads = 4;
    params.beam_search.beam_size = 5;
    params.language = "en";
    params.translate = false;
    params.no_context = true;
    params.initial_prompt = prompt;
    params.single_segment = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.suppress_nst = true;
    // Retain Whisper's default fallback for failed/low-confidence decoding.
    params.temperature_inc = 0.2f;
    params.vad = true;
    params.vad_model_path = vad_path;
    params.vad_params.threshold = 0.5f;
    params.vad_params.min_speech_duration_ms = 250;
    params.vad_params.min_silence_duration_ms = 500;
    params.vad_params.speech_pad_ms = 200;
    params.vad_params.samples_overlap = 0.0f;
    *status = whisper_full(ctx, params, samples, count);
    if (*status != 0) return nullptr;
    std::string text;
    for (int i = 0; i < whisper_full_n_segments(ctx); ++i) {
        if (whisper_full_get_segment_no_speech_prob(ctx, i) < 0.6f)
            text += whisper_full_get_segment_text(ctx, i);
    }
    // A loop can straddle decoder segments. Never publish it or feed it back.
    if (echoflow_repetition_candidate(text)) { *status = -100; return nullptr; }
    return strdup(text.c_str());
}

void lt_whisper_free_text(char * text) { free(text); }
