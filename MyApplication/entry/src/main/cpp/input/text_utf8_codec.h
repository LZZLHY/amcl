#ifndef AMCL_TEXT_UTF8_CODEC_H
#define AMCL_TEXT_UTF8_CODEC_H

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace amcl::input {

enum class TextUtf8CodecStatus : uint8_t {
    kOk = 0,
    kInvalidArgument,
    kInvalidLeadingByte,
    kTruncatedSequence,
    kInvalidContinuationByte,
    kOverlongEncoding,
    kSurrogateScalar,
    kScalarOutOfRange,
    kOutputTooSmall,
    kTooManyCandidates,
    kTooManyScalars,
    kMalformedCandidateBlob,
    kIntegerOverflow,
};

struct TextUtf8Span {
    const uint8_t* data = nullptr;
    size_t byteCount = 0u;
};

struct TextUtf8CandidateView {
    TextUtf8Span utf8{};
    size_t scalarCount = 0u;
};

// Candidate wire format, all integers explicitly little-endian:
//
//   u32 itemCount
//   repeat itemCount times: u32 byteLength, uint8_t utf8[byteLength]
//
// Empty candidate strings are representable. Trailing bytes are forbidden.
constexpr size_t kTextCandidateMaxItems = 64u;
constexpr size_t kTextCandidateMaxScalars = 4096u;
constexpr size_t kTextCandidateMaxUtf8Bytes =
    kTextCandidateMaxScalars * 4u;
constexpr size_t kTextCandidateBlobHeaderBytes = 4u;
constexpr size_t kTextCandidateLengthBytes = 4u;
constexpr size_t kTextCandidateMaxBlobBytes =
    kTextCandidateBlobHeaderBytes +
    kTextCandidateMaxItems * kTextCandidateLengthBytes +
    kTextCandidateMaxUtf8Bytes;

namespace text_utf8_detail {

inline bool IsContinuationByte(uint8_t value) {
    return (value & 0xc0u) == 0x80u;
}

inline TextUtf8CodecStatus DecodeOne(const uint8_t* bytes,
                                     size_t byteCount,
                                     size_t* offset,
                                     uint32_t* scalar) {
    if (!offset || !scalar || (!bytes && byteCount != 0u) ||
        *offset >= byteCount) {
        return TextUtf8CodecStatus::kInvalidArgument;
    }

    const size_t start = *offset;
    const uint8_t first = bytes[start];
    size_t sequenceLength = 0u;
    uint32_t value = 0u;
    uint32_t minimum = 0u;
    if (first <= 0x7fu) {
        sequenceLength = 1u;
        value = first;
    } else if (first >= 0xc2u && first <= 0xdfu) {
        sequenceLength = 2u;
        value = first & 0x1fu;
        minimum = 0x80u;
    } else if (first >= 0xe0u && first <= 0xefu) {
        sequenceLength = 3u;
        value = first & 0x0fu;
        minimum = 0x800u;
    } else if (first >= 0xf0u && first <= 0xf4u) {
        sequenceLength = 4u;
        value = first & 0x07u;
        minimum = 0x10000u;
    } else if (first == 0xc0u || first == 0xc1u) {
        return TextUtf8CodecStatus::kOverlongEncoding;
    } else if (first >= 0xf5u && first <= 0xf7u) {
        return TextUtf8CodecStatus::kScalarOutOfRange;
    } else {
        return TextUtf8CodecStatus::kInvalidLeadingByte;
    }

    if (sequenceLength > byteCount - start) {
        return TextUtf8CodecStatus::kTruncatedSequence;
    }
    for (size_t index = 1u; index < sequenceLength; ++index) {
        const uint8_t continuation = bytes[start + index];
        if (!IsContinuationByte(continuation)) {
            return TextUtf8CodecStatus::kInvalidContinuationByte;
        }
        value = (value << 6u) | (continuation & 0x3fu);
    }
    if (value < minimum) return TextUtf8CodecStatus::kOverlongEncoding;
    if (value >= 0xd800u && value <= 0xdfffu) {
        return TextUtf8CodecStatus::kSurrogateScalar;
    }
    if (value > 0x10ffffu) {
        return TextUtf8CodecStatus::kScalarOutOfRange;
    }

    *offset = start + sequenceLength;
    *scalar = value;
    return TextUtf8CodecStatus::kOk;
}

inline uint32_t ReadLe32(const uint8_t* bytes) {
    return static_cast<uint32_t>(bytes[0]) |
           (static_cast<uint32_t>(bytes[1]) << 8u) |
           (static_cast<uint32_t>(bytes[2]) << 16u) |
           (static_cast<uint32_t>(bytes[3]) << 24u);
}

inline void WriteLe32(uint8_t* bytes, uint32_t value) {
    bytes[0] = static_cast<uint8_t>(value & 0xffu);
    bytes[1] = static_cast<uint8_t>((value >> 8u) & 0xffu);
    bytes[2] = static_cast<uint8_t>((value >> 16u) & 0xffu);
    bytes[3] = static_cast<uint8_t>((value >> 24u) & 0xffu);
}

inline bool CheckedAdd(size_t left, size_t right, size_t* result) {
    if (!result || right > std::numeric_limits<size_t>::max() - left) {
        return false;
    }
    *result = left + right;
    return true;
}

}  // namespace text_utf8_detail

// Count-only pass for strict standard UTF-8. U+0000 is a valid Unicode scalar;
// surrogate code points are not. No replacement or byte skipping occurs.
inline TextUtf8CodecStatus CountTextUtf8Scalars(const uint8_t* bytes,
                                                size_t byteCount,
                                                size_t* scalarCount) {
    if (!scalarCount || (!bytes && byteCount != 0u)) {
        return TextUtf8CodecStatus::kInvalidArgument;
    }
    *scalarCount = 0u;
    size_t offset = 0u;
    while (offset < byteCount) {
        uint32_t scalar = 0u;
        const TextUtf8CodecStatus status =
            text_utf8_detail::DecodeOne(
                bytes, byteCount, &offset, &scalar);
        if (status != TextUtf8CodecStatus::kOk) return status;
        if (*scalarCount == std::numeric_limits<size_t>::max()) {
            *scalarCount = 0u;
            return TextUtf8CodecStatus::kIntegerOverflow;
        }
        ++(*scalarCount);
    }
    return TextUtf8CodecStatus::kOk;
}

// Two-pass zero-allocation decode. Pass scalars=nullptr/capacity=0 to query the
// exact count. Invalid UTF-8 or insufficient capacity never partially writes.
// The input bytes must remain immutable for both passes and must not overlap the
// scalar output storage.
inline TextUtf8CodecStatus DecodeTextUtf8Scalars(const uint8_t* bytes,
                                                 size_t byteCount,
                                                 uint32_t* scalars,
                                                 size_t scalarCapacity,
                                                 size_t* scalarCount) {
    if (!scalarCount || (!bytes && byteCount != 0u) ||
        (!scalars && scalarCapacity != 0u)) {
        return TextUtf8CodecStatus::kInvalidArgument;
    }
    size_t required = 0u;
    const TextUtf8CodecStatus countStatus =
        CountTextUtf8Scalars(bytes, byteCount, &required);
    if (countStatus != TextUtf8CodecStatus::kOk) {
        *scalarCount = 0u;
        return countStatus;
    }
    *scalarCount = required;
    if (!scalars && scalarCapacity == 0u) {
        return TextUtf8CodecStatus::kOk;
    }
    if (required > scalarCapacity) {
        return TextUtf8CodecStatus::kOutputTooSmall;
    }
    if (required != 0u && !scalars) {
        return TextUtf8CodecStatus::kInvalidArgument;
    }

    size_t offset = 0u;
    size_t outputIndex = 0u;
    while (offset < byteCount) {
        uint32_t scalar = 0u;
        const TextUtf8CodecStatus status =
            text_utf8_detail::DecodeOne(
                bytes, byteCount, &offset, &scalar);
        if (status != TextUtf8CodecStatus::kOk) {
            // The count pass validated the same immutable input. Reaching this
            // branch means the caller violated the non-overlap/stability contract.
            *scalarCount = 0u;
            return status;
        }
        scalars[outputIndex++] = scalar;
    }
    return TextUtf8CodecStatus::kOk;
}

// Two-pass encoder. candidates may be null only when candidateCount is zero.
// encoded=nullptr/capacity=0 queries the exact byte count without allocating.
// Candidate spans must stay immutable and must not overlap the encoded output;
// overlap would violate memcpy's contract.
inline TextUtf8CodecStatus EncodeTextCandidateBlob(
        const TextUtf8Span* candidates,
        size_t candidateCount,
        uint8_t* encoded,
        size_t encodedCapacity,
        size_t* encodedByteCount,
        size_t* totalScalarCount = nullptr) {
    if (!encodedByteCount || (!candidates && candidateCount != 0u) ||
        (!encoded && encodedCapacity != 0u)) {
        return TextUtf8CodecStatus::kInvalidArgument;
    }
    *encodedByteCount = 0u;
    if (totalScalarCount) *totalScalarCount = 0u;
    if (candidateCount > kTextCandidateMaxItems) {
        return TextUtf8CodecStatus::kTooManyCandidates;
    }

    size_t required = kTextCandidateBlobHeaderBytes;
    size_t scalarTotal = 0u;
    for (size_t index = 0u; index < candidateCount; ++index) {
        const TextUtf8Span& candidate = candidates[index];
        if ((!candidate.data && candidate.byteCount != 0u)) {
            return TextUtf8CodecStatus::kInvalidArgument;
        }
        if (candidate.byteCount > kTextCandidateMaxUtf8Bytes) {
            return TextUtf8CodecStatus::kTooManyScalars;
        }
        size_t candidateScalars = 0u;
        const TextUtf8CodecStatus utf8Status = CountTextUtf8Scalars(
            candidate.data, candidate.byteCount, &candidateScalars);
        if (utf8Status != TextUtf8CodecStatus::kOk) return utf8Status;
        if (candidateScalars > kTextCandidateMaxScalars - scalarTotal) {
            return TextUtf8CodecStatus::kTooManyScalars;
        }
        scalarTotal += candidateScalars;

        size_t withLength = 0u;
        if (!text_utf8_detail::CheckedAdd(
                required, kTextCandidateLengthBytes, &withLength) ||
            !text_utf8_detail::CheckedAdd(
                withLength, candidate.byteCount, &required)) {
            return TextUtf8CodecStatus::kIntegerOverflow;
        }
    }
    if (required > kTextCandidateMaxBlobBytes ||
        required > static_cast<size_t>(std::numeric_limits<uint32_t>::max())) {
        return TextUtf8CodecStatus::kIntegerOverflow;
    }

    *encodedByteCount = required;
    if (totalScalarCount) *totalScalarCount = scalarTotal;
    if (!encoded && encodedCapacity == 0u) {
        return TextUtf8CodecStatus::kOk;
    }
    if (required > encodedCapacity) {
        return TextUtf8CodecStatus::kOutputTooSmall;
    }
    if (!encoded) return TextUtf8CodecStatus::kInvalidArgument;

    text_utf8_detail::WriteLe32(
        encoded, static_cast<uint32_t>(candidateCount));
    size_t offset = kTextCandidateBlobHeaderBytes;
    for (size_t index = 0u; index < candidateCount; ++index) {
        const TextUtf8Span& candidate = candidates[index];
        text_utf8_detail::WriteLe32(
            encoded + offset, static_cast<uint32_t>(candidate.byteCount));
        offset += kTextCandidateLengthBytes;
        if (candidate.byteCount != 0u) {
            std::memcpy(encoded + offset, candidate.data, candidate.byteCount);
            offset += candidate.byteCount;
        }
    }
    return TextUtf8CodecStatus::kOk;
}

namespace text_utf8_detail {

inline TextUtf8CodecStatus InspectCandidateBlob(
        const uint8_t* encoded,
        size_t encodedByteCount,
        TextUtf8CandidateView* candidates,
        size_t* candidateCount,
        size_t* totalScalarCount) {
    if (!candidateCount || !totalScalarCount ||
        (!encoded && encodedByteCount != 0u)) {
        return TextUtf8CodecStatus::kInvalidArgument;
    }
    *candidateCount = 0u;
    *totalScalarCount = 0u;
    if (encodedByteCount < kTextCandidateBlobHeaderBytes || !encoded) {
        return TextUtf8CodecStatus::kMalformedCandidateBlob;
    }

    const size_t itemCount = ReadLe32(encoded);
    if (itemCount > kTextCandidateMaxItems) {
        return TextUtf8CodecStatus::kTooManyCandidates;
    }
    size_t offset = kTextCandidateBlobHeaderBytes;
    size_t scalarTotal = 0u;
    for (size_t index = 0u; index < itemCount; ++index) {
        if (kTextCandidateLengthBytes > encodedByteCount - offset) {
            return TextUtf8CodecStatus::kMalformedCandidateBlob;
        }
        const size_t candidateBytes = ReadLe32(encoded + offset);
        offset += kTextCandidateLengthBytes;
        if (candidateBytes > encodedByteCount - offset) {
            return TextUtf8CodecStatus::kMalformedCandidateBlob;
        }
        if (candidateBytes > kTextCandidateMaxUtf8Bytes) {
            return TextUtf8CodecStatus::kTooManyScalars;
        }

        size_t candidateScalars = 0u;
        const TextUtf8CodecStatus utf8Status = CountTextUtf8Scalars(
            encoded + offset, candidateBytes, &candidateScalars);
        if (utf8Status != TextUtf8CodecStatus::kOk) return utf8Status;
        if (candidateScalars > kTextCandidateMaxScalars - scalarTotal) {
            return TextUtf8CodecStatus::kTooManyScalars;
        }
        scalarTotal += candidateScalars;
        if (candidates) {
            candidates[index].utf8.data = encoded + offset;
            candidates[index].utf8.byteCount = candidateBytes;
            candidates[index].scalarCount = candidateScalars;
        }
        offset += candidateBytes;
    }
    if (offset != encodedByteCount) {
        return TextUtf8CodecStatus::kMalformedCandidateBlob;
    }

    *candidateCount = itemCount;
    *totalScalarCount = scalarTotal;
    return TextUtf8CodecStatus::kOk;
}

}  // namespace text_utf8_detail

// Decoder returns non-owning views into the immutable encoded blob. Pass
// candidates=nullptr/capacity=0 for the first pass. No partial views are written
// on malformed input or insufficient capacity.
inline TextUtf8CodecStatus DecodeTextCandidateBlob(
        const uint8_t* encoded,
        size_t encodedByteCount,
        TextUtf8CandidateView* candidates,
        size_t candidateCapacity,
        size_t* candidateCount,
        size_t* totalScalarCount = nullptr) {
    if (!candidateCount || (!encoded && encodedByteCount != 0u) ||
        (!candidates && candidateCapacity != 0u)) {
        return TextUtf8CodecStatus::kInvalidArgument;
    }
    *candidateCount = 0u;
    if (totalScalarCount) *totalScalarCount = 0u;

    size_t required = 0u;
    size_t scalarTotal = 0u;
    const TextUtf8CodecStatus inspectStatus =
        text_utf8_detail::InspectCandidateBlob(
            encoded, encodedByteCount, nullptr, &required, &scalarTotal);
    if (inspectStatus != TextUtf8CodecStatus::kOk) return inspectStatus;

    *candidateCount = required;
    if (totalScalarCount) *totalScalarCount = scalarTotal;
    if (!candidates && candidateCapacity == 0u) {
        return TextUtf8CodecStatus::kOk;
    }
    if (required > candidateCapacity) {
        return TextUtf8CodecStatus::kOutputTooSmall;
    }
    if (required != 0u && !candidates) {
        return TextUtf8CodecStatus::kInvalidArgument;
    }
    if (required == 0u) return TextUtf8CodecStatus::kOk;

    size_t filled = 0u;
    size_t filledScalars = 0u;
    return text_utf8_detail::InspectCandidateBlob(
        encoded, encodedByteCount, candidates, &filled, &filledScalars);
}

}  // namespace amcl::input

#endif  // AMCL_TEXT_UTF8_CODEC_H
