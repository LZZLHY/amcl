#pragma once

#include <cstdint>
#include <limits>
#include <string>

namespace download {

struct ParsedContentRange {
    int64_t start = -1;
    int64_t end = -1;
    int64_t total = -1;
};

inline bool parseUnsignedInt64(const std::string& text, size_t& pos, int64_t& value) {
    if (pos >= text.size() || text[pos] < '0' || text[pos] > '9') return false;
    int64_t result = 0;
    while (pos < text.size() && text[pos] >= '0' && text[pos] <= '9') {
        const int digit = text[pos] - '0';
        if (result > (std::numeric_limits<int64_t>::max() - digit) / 10) return false;
        result = result * 10 + digit;
        ++pos;
    }
    value = result;
    return true;
}

inline bool parseContentRangeValue(const std::string& raw, ParsedContentRange& out) {
    size_t first = raw.find_first_not_of(" \t");
    size_t last = raw.find_last_not_of(" \t\r\n");
    if (first == std::string::npos || last < first) return false;
    const std::string value = raw.substr(first, last - first + 1);
    if (value.size() < 8) return false;
    const char prefix[] = "bytes ";
    for (size_t i = 0; i < sizeof(prefix) - 1; ++i) {
        char actual = value[i];
        if (actual >= 'A' && actual <= 'Z') actual = static_cast<char>(actual - 'A' + 'a');
        if (actual != prefix[i]) return false;
    }
    size_t pos = sizeof(prefix) - 1;
    ParsedContentRange parsed;
    if (!parseUnsignedInt64(value, pos, parsed.start) || pos >= value.size() || value[pos++] != '-' ||
        !parseUnsignedInt64(value, pos, parsed.end) || pos >= value.size() || value[pos++] != '/' ||
        !parseUnsignedInt64(value, pos, parsed.total) || pos != value.size()) {
        return false;
    }
    if (parsed.start < 0 || parsed.end < parsed.start || parsed.total <= parsed.end) return false;
    out = parsed;
    return true;
}

inline bool parseContentRangeHeader(const char* data, size_t length, ParsedContentRange& out) {
    if (!data || length <= 14) return false;
    const char key[] = "content-range:";
    for (size_t i = 0; i < sizeof(key) - 1; ++i) {
        char actual = data[i];
        if (actual >= 'A' && actual <= 'Z') actual = static_cast<char>(actual - 'A' + 'a');
        if (actual != key[i]) return false;
    }
    return parseContentRangeValue(std::string(data + sizeof(key) - 1,
                                               length - (sizeof(key) - 1)), out);
}

inline bool contentRangeMatches(const ParsedContentRange& range,
                                int64_t requested_start,
                                int64_t requested_end,
                                int64_t expected_total) {
    if (range.start != requested_start) return false;
    if (requested_end >= requested_start && range.end != requested_end) return false;
    if (expected_total > 0 && range.total != expected_total) return false;
    return range.end < range.total;
}

} // namespace download
