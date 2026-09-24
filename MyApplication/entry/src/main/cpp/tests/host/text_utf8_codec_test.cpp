#include "../../input/text_utf8_codec.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

using amcl::input::DecodeTextCandidateBlob;
using amcl::input::DecodeTextUtf8Scalars;
using amcl::input::EncodeTextCandidateBlob;
using amcl::input::TextUtf8CandidateView;
using amcl::input::TextUtf8CodecStatus;
using amcl::input::TextUtf8Span;

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "text_utf8_codec_test: FAIL line " << line
              << ": " << expression << '\n';
    std::exit(1);
}

#define CHECK(expression) \
    do { if (!(expression)) Fail(#expression, __LINE__); } while (0)

TextUtf8Span Span(const std::vector<uint8_t>& bytes) {
    return TextUtf8Span{bytes.data(), bytes.size()};
}

TextUtf8Span Span(const std::string& text) {
    return TextUtf8Span{
        reinterpret_cast<const uint8_t*>(text.data()), text.size()};
}

void AppendLe32(std::vector<uint8_t>* bytes, uint32_t value) {
    CHECK(bytes != nullptr);
    bytes->push_back(static_cast<uint8_t>(value & 0xffu));
    bytes->push_back(static_cast<uint8_t>((value >> 8u) & 0xffu));
    bytes->push_back(static_cast<uint8_t>((value >> 16u) & 0xffu));
    bytes->push_back(static_cast<uint8_t>((value >> 24u) & 0xffu));
}

void CheckDecodeStatus(const std::vector<uint8_t>& bytes,
                       TextUtf8CodecStatus expected) {
    size_t count = 99u;
    CHECK(DecodeTextUtf8Scalars(
              bytes.data(), bytes.size(), nullptr, 0u, &count) == expected);
    if (expected != TextUtf8CodecStatus::kOk) CHECK(count == 0u);
}

void TestStrictUtf8Decode() {
    const std::vector<uint8_t> input{
        0x00u, 0x24u,                    // U+0000, U+0024
        0xc2u, 0xa2u,                    // U+00A2
        0xe2u, 0x82u, 0xacu,             // U+20AC
        0xf0u, 0x9fu, 0x98u, 0x80u,      // U+1F600
    };
    size_t count = 0u;
    CHECK(DecodeTextUtf8Scalars(
              input.data(), input.size(), nullptr, 0u, &count) ==
          TextUtf8CodecStatus::kOk);
    CHECK(count == 5u);

    uint32_t output[5]{};
    CHECK(DecodeTextUtf8Scalars(
              input.data(), input.size(), output, 5u, &count) ==
          TextUtf8CodecStatus::kOk);
    CHECK(count == 5u);
    CHECK(output[0] == 0u);
    CHECK(output[1] == 0x24u);
    CHECK(output[2] == 0xa2u);
    CHECK(output[3] == 0x20acu);
    CHECK(output[4] == 0x1f600u);

    const std::vector<uint8_t> maximum{0xf4u, 0x8fu, 0xbfu, 0xbfu};
    uint32_t maximumOutput = 0u;
    CHECK(DecodeTextUtf8Scalars(
              maximum.data(), maximum.size(), &maximumOutput, 1u, &count) ==
          TextUtf8CodecStatus::kOk);
    CHECK(count == 1u && maximumOutput == 0x10ffffu);

    count = 99u;
    CHECK(DecodeTextUtf8Scalars(
              nullptr, 0u, nullptr, 0u, &count) ==
          TextUtf8CodecStatus::kOk);
    CHECK(count == 0u);
}

void TestStrictUtf8RejectsMalformedSequences() {
    CheckDecodeStatus({0x80u}, TextUtf8CodecStatus::kInvalidLeadingByte);
    CheckDecodeStatus({0xffu}, TextUtf8CodecStatus::kInvalidLeadingByte);
    CheckDecodeStatus({0xc0u, 0x80u}, TextUtf8CodecStatus::kOverlongEncoding);
    CheckDecodeStatus({0xc1u, 0xbfu}, TextUtf8CodecStatus::kOverlongEncoding);
    CheckDecodeStatus(
        {0xe0u, 0x80u, 0x80u}, TextUtf8CodecStatus::kOverlongEncoding);
    CheckDecodeStatus(
        {0xf0u, 0x80u, 0x80u, 0x80u},
        TextUtf8CodecStatus::kOverlongEncoding);
    CheckDecodeStatus(
        {0xedu, 0xa0u, 0x80u}, TextUtf8CodecStatus::kSurrogateScalar);
    CheckDecodeStatus(
        {0xedu, 0xbfu, 0xbfu}, TextUtf8CodecStatus::kSurrogateScalar);
    CheckDecodeStatus(
        {0xf4u, 0x90u, 0x80u, 0x80u},
        TextUtf8CodecStatus::kScalarOutOfRange);
    CheckDecodeStatus(
        {0xf5u, 0x80u, 0x80u, 0x80u},
        TextUtf8CodecStatus::kScalarOutOfRange);
    CheckDecodeStatus({0xc2u}, TextUtf8CodecStatus::kTruncatedSequence);
    CheckDecodeStatus(
        {0xe2u, 0x82u}, TextUtf8CodecStatus::kTruncatedSequence);
    CheckDecodeStatus(
        {0xf0u, 0x9fu, 0x98u}, TextUtf8CodecStatus::kTruncatedSequence);
    CheckDecodeStatus(
        {0xc2u, 0x20u}, TextUtf8CodecStatus::kInvalidContinuationByte);
    CheckDecodeStatus(
        {0xe2u, 0x28u, 0xa1u},
        TextUtf8CodecStatus::kInvalidContinuationByte);
}

void TestDecodeCountThenFillIsAtomic() {
    const std::vector<uint8_t> input{'a', 'b', 'c'};
    uint32_t output[2]{0xaaaaaaaau, 0xbbbbbbbbu};
    size_t count = 0u;
    CHECK(DecodeTextUtf8Scalars(
              input.data(), input.size(), output, 2u, &count) ==
          TextUtf8CodecStatus::kOutputTooSmall);
    CHECK(count == 3u);
    CHECK(output[0] == 0xaaaaaaaau && output[1] == 0xbbbbbbbbu);

    CHECK(DecodeTextUtf8Scalars(
              input.data(), input.size(), nullptr, 1u, &count) ==
          TextUtf8CodecStatus::kInvalidArgument);
    CHECK(DecodeTextUtf8Scalars(
              nullptr, 1u, nullptr, 0u, &count) ==
          TextUtf8CodecStatus::kInvalidArgument);
    CHECK(DecodeTextUtf8Scalars(
              input.data(), input.size(), nullptr, 0u, nullptr) ==
          TextUtf8CodecStatus::kInvalidArgument);
}

std::vector<uint8_t> EncodeCandidates(
        const std::vector<TextUtf8Span>& candidates,
        size_t* scalarCount = nullptr) {
    size_t required = 0u;
    CHECK(EncodeTextCandidateBlob(
              candidates.data(), candidates.size(), nullptr, 0u,
              &required, scalarCount) == TextUtf8CodecStatus::kOk);
    std::vector<uint8_t> encoded(required, 0u);
    size_t written = 0u;
    CHECK(EncodeTextCandidateBlob(
              candidates.data(), candidates.size(), encoded.data(),
              encoded.size(), &written, scalarCount) ==
          TextUtf8CodecStatus::kOk);
    CHECK(written == encoded.size());
    return encoded;
}

void TestCandidateWireRoundTripAndEndian() {
    const std::vector<uint8_t> ascii{'A'};
    const std::vector<uint8_t> chineseEmoji{
        0xe4u, 0xb8u, 0xadu,             // U+4E2D
        0xf0u, 0x9fu, 0x98u, 0x80u,      // U+1F600
    };
    const std::vector<uint8_t> empty;
    const std::vector<TextUtf8Span> candidates{
        Span(ascii), Span(chineseEmoji), Span(empty),
    };
    size_t scalarCount = 0u;
    const std::vector<uint8_t> encoded =
        EncodeCandidates(candidates, &scalarCount);
    CHECK(scalarCount == 3u);
    CHECK(encoded.size() == 24u);
    CHECK(encoded[0] == 3u && encoded[1] == 0u &&
          encoded[2] == 0u && encoded[3] == 0u);
    CHECK(encoded[4] == 1u && encoded[5] == 0u &&
          encoded[6] == 0u && encoded[7] == 0u);
    CHECK(encoded[8] == static_cast<uint8_t>('A'));
    CHECK(encoded[9] == 7u && encoded[10] == 0u &&
          encoded[11] == 0u && encoded[12] == 0u);
    CHECK(encoded[20] == 0u && encoded[21] == 0u &&
          encoded[22] == 0u && encoded[23] == 0u);

    size_t candidateCount = 0u;
    size_t decodedScalars = 0u;
    CHECK(DecodeTextCandidateBlob(
              encoded.data(), encoded.size(), nullptr, 0u,
              &candidateCount, &decodedScalars) ==
          TextUtf8CodecStatus::kOk);
    CHECK(candidateCount == 3u && decodedScalars == 3u);

    TextUtf8CandidateView decoded[3]{};
    CHECK(DecodeTextCandidateBlob(
              encoded.data(), encoded.size(), decoded, 3u,
              &candidateCount, &decodedScalars) ==
          TextUtf8CodecStatus::kOk);
    CHECK(decoded[0].utf8.byteCount == 1u && decoded[0].scalarCount == 1u);
    CHECK(decoded[1].utf8.byteCount == 7u && decoded[1].scalarCount == 2u);
    CHECK(decoded[2].utf8.byteCount == 0u && decoded[2].scalarCount == 0u);
    CHECK(std::memcmp(decoded[0].utf8.data, ascii.data(), ascii.size()) == 0);
    CHECK(std::memcmp(
              decoded[1].utf8.data, chineseEmoji.data(),
              chineseEmoji.size()) == 0);

    std::vector<TextUtf8Span> decodedSpans;
    for (const TextUtf8CandidateView& candidate : decoded) {
        decodedSpans.push_back(candidate.utf8);
    }
    CHECK(EncodeCandidates(decodedSpans) == encoded);

    const std::string longCandidate(300u, 'x');
    const std::vector<TextUtf8Span> longCandidates{Span(longCandidate)};
    const std::vector<uint8_t> longEncoded = EncodeCandidates(longCandidates);
    CHECK(longEncoded[0] == 1u);
    CHECK(longEncoded[4] == 0x2cu && longEncoded[5] == 0x01u &&
          longEncoded[6] == 0u && longEncoded[7] == 0u);
}

void TestCandidateOutputCapacityIsAtomic() {
    const std::vector<uint8_t> a{'a'};
    const std::vector<uint8_t> b{'b'};
    const std::vector<TextUtf8Span> candidates{Span(a), Span(b)};

    size_t required = 0u;
    CHECK(EncodeTextCandidateBlob(
              candidates.data(), candidates.size(), nullptr, 0u,
              &required) == TextUtf8CodecStatus::kOk);
    std::vector<uint8_t> tooSmall(required - 1u, 0x5au);
    size_t reported = 0u;
    CHECK(EncodeTextCandidateBlob(
              candidates.data(), candidates.size(), tooSmall.data(),
              tooSmall.size(), &reported) ==
          TextUtf8CodecStatus::kOutputTooSmall);
    CHECK(reported == required);
    for (uint8_t value : tooSmall) CHECK(value == 0x5au);

    const std::vector<uint8_t> encoded = EncodeCandidates(candidates);
    uint8_t sentinel = 0u;
    TextUtf8CandidateView views[1]{};
    views[0].utf8.data = &sentinel;
    views[0].utf8.byteCount = 77u;
    views[0].scalarCount = 88u;
    size_t candidateCount = 0u;
    CHECK(DecodeTextCandidateBlob(
              encoded.data(), encoded.size(), views, 1u,
              &candidateCount) == TextUtf8CodecStatus::kOutputTooSmall);
    CHECK(candidateCount == 2u);
    CHECK(views[0].utf8.data == &sentinel);
    CHECK(views[0].utf8.byteCount == 77u && views[0].scalarCount == 88u);
}

void CheckCandidateDecodeStatus(const std::vector<uint8_t>& encoded,
                                TextUtf8CodecStatus expected) {
    size_t candidateCount = 99u;
    size_t scalarCount = 99u;
    CHECK(DecodeTextCandidateBlob(
              encoded.data(), encoded.size(), nullptr, 0u,
              &candidateCount, &scalarCount) == expected);
    if (expected != TextUtf8CodecStatus::kOk) {
        CHECK(candidateCount == 0u && scalarCount == 0u);
    }
}

void TestCandidateBlobRejectsMalformedLengths() {
    CheckCandidateDecodeStatus({}, TextUtf8CodecStatus::kMalformedCandidateBlob);
    CheckCandidateDecodeStatus(
        {0u, 0u, 0u}, TextUtf8CodecStatus::kMalformedCandidateBlob);
    CheckCandidateDecodeStatus(
        {1u, 0u, 0u, 0u}, TextUtf8CodecStatus::kMalformedCandidateBlob);
    CheckCandidateDecodeStatus(
        {1u, 0u, 0u, 0u, 5u, 0u, 0u, 0u, 'a', 'b', 'c', 'd'},
        TextUtf8CodecStatus::kMalformedCandidateBlob);
    CheckCandidateDecodeStatus(
        {1u, 0u, 0u, 0u, 0xffu, 0xffu, 0xffu, 0xffu},
        TextUtf8CodecStatus::kMalformedCandidateBlob);
    CheckCandidateDecodeStatus(
        {0u, 0u, 0u, 0u, 0u},
        TextUtf8CodecStatus::kMalformedCandidateBlob);
    CheckCandidateDecodeStatus(
        {65u, 0u, 0u, 0u}, TextUtf8CodecStatus::kTooManyCandidates);
    CheckCandidateDecodeStatus(
        {1u, 0u, 0u, 0u, 1u, 0u, 0u, 0u, 0x80u},
        TextUtf8CodecStatus::kInvalidLeadingByte);
}

void TestCandidateResourceLimits() {
    const std::vector<uint8_t> empty;
    std::vector<TextUtf8Span> maximumItems(
        amcl::input::kTextCandidateMaxItems, Span(empty));
    const std::vector<uint8_t> maximumItemBlob =
        EncodeCandidates(maximumItems);
    CHECK(maximumItemBlob.size() ==
          amcl::input::kTextCandidateBlobHeaderBytes +
          amcl::input::kTextCandidateMaxItems *
              amcl::input::kTextCandidateLengthBytes);

    maximumItems.push_back(Span(empty));
    size_t required = 0u;
    CHECK(EncodeTextCandidateBlob(
              maximumItems.data(), maximumItems.size(), nullptr, 0u,
              &required) == TextUtf8CodecStatus::kTooManyCandidates);
    CHECK(required == 0u);

    const std::string exactAscii(amcl::input::kTextCandidateMaxScalars, 'a');
    const std::vector<TextUtf8Span> exactCandidates{Span(exactAscii)};
    size_t scalarCount = 0u;
    const std::vector<uint8_t> exactBlob =
        EncodeCandidates(exactCandidates, &scalarCount);
    CHECK(scalarCount == amcl::input::kTextCandidateMaxScalars);
    CheckCandidateDecodeStatus(exactBlob, TextUtf8CodecStatus::kOk);

    const std::string tooManyAscii(
        amcl::input::kTextCandidateMaxScalars + 1u, 'a');
    const std::vector<TextUtf8Span> tooManyCandidates{Span(tooManyAscii)};
    CHECK(EncodeTextCandidateBlob(
              tooManyCandidates.data(), tooManyCandidates.size(),
              nullptr, 0u, &required) ==
          TextUtf8CodecStatus::kTooManyScalars);

    std::vector<uint8_t> tooManyBlob;
    AppendLe32(&tooManyBlob, 1u);
    AppendLe32(
        &tooManyBlob,
        static_cast<uint32_t>(amcl::input::kTextCandidateMaxScalars + 1u));
    tooManyBlob.insert(
        tooManyBlob.end(), amcl::input::kTextCandidateMaxScalars + 1u,
        static_cast<uint8_t>('a'));
    CheckCandidateDecodeStatus(
        tooManyBlob, TextUtf8CodecStatus::kTooManyScalars);

    std::vector<uint8_t> maximumUtf8;
    maximumUtf8.reserve(amcl::input::kTextCandidateMaxUtf8Bytes);
    for (size_t index = 0u;
         index < amcl::input::kTextCandidateMaxScalars; ++index) {
        maximumUtf8.insert(
            maximumUtf8.end(), {0xf0u, 0x9fu, 0x98u, 0x80u});
    }
    const std::vector<TextUtf8Span> maximumUtf8Candidate{Span(maximumUtf8)};
    const std::vector<uint8_t> maximumUtf8Blob =
        EncodeCandidates(maximumUtf8Candidate, &scalarCount);
    CHECK(scalarCount == amcl::input::kTextCandidateMaxScalars);
    CHECK(maximumUtf8Blob.size() ==
          amcl::input::kTextCandidateBlobHeaderBytes +
          amcl::input::kTextCandidateLengthBytes +
          amcl::input::kTextCandidateMaxUtf8Bytes);
    CHECK(maximumUtf8Blob.size() <= amcl::input::kTextCandidateMaxBlobBytes);
}

}  // namespace

int main() {
    TestStrictUtf8Decode();
    TestStrictUtf8RejectsMalformedSequences();
    TestDecodeCountThenFillIsAtomic();
    TestCandidateWireRoundTripAndEndian();
    TestCandidateOutputCapacityIsAtomic();
    TestCandidateBlobRejectsMalformedLengths();
    TestCandidateResourceLimits();
    std::cout << "text_utf8_codec_test: PASS\n";
    return 0;
}
