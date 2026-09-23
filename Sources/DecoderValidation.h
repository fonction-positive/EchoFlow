#pragma once
#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

// A failed candidate is retried, never shortened into apparently valid speech.
// This also covers loops shorter than Whisper's 32-token entropy window.
inline bool echoflow_repetition_candidate(const std::string & text) {
    std::vector<std::string> words;
    std::string word;
    for (unsigned char c : text) {
        if (std::isalnum(c) || c == '\'') word += char(std::tolower(c));
        else if (!word.empty()) { words.push_back(word); word.clear(); }
    }
    if (!word.empty()) words.push_back(word);
    for (size_t start = 0; start < words.size(); ++start) {
        for (size_t width = 1; width <= 64 && start + width * 2 <= words.size(); ++width) {
            size_t end = start + width;
            while (end + width <= words.size() &&
                   std::equal(words.begin() + start, words.begin() + start + width, words.begin() + end)) {
                end += width;
            }
            // Preserve ordinary stutters/emphasis such as "no, no, no".
            if ((width >= 2 && end - start >= width * 3) || (width == 1 && end - start >= 8)) return true;
            if (width >= 4 && end - start >= width * 2 && (end - start) * 4 >= words.size() * 3) return true;
            // Long repeated phrases with an inserted clause can evade a purely
            // consecutive-loop check and then contaminate subsequent prompts.
            if (width >= 6 && width * 10 >= words.size() * 2) {
                for (size_t next = start + width; next + width <= words.size(); ++next) {
                    if (std::equal(words.begin() + start, words.begin() + start + width, words.begin() + next)) return true;
                }
            }
        }
    }
    return false;
}
