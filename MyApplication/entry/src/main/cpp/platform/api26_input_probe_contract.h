#pragma once

#include <cstdint>

namespace amcl::input {

// This is a build-surface contract, not an input source.  Its only enabled
// state proves that the formal desktop toolchain can compile the candidate
// headers and resolve their symbols while linking libentry.so.
enum class Api26InputProbeDisposition : std::uint8_t {
    Excluded = 0,
    CompileLinkOnly = 1,
    InvalidPlatform = 2,
};

struct Api26InputProbeContract final {
    Api26InputProbeDisposition disposition;
    bool compileTranslationUnit;
    bool linkGameControllerKit;
    bool mayRegisterCallbacks;
    bool mayPublishInput;
};

constexpr Api26InputProbeContract ResolveApi26InputProbeContract(
    bool api26RawMouseMotionEnabled,
    bool isOhosBuild) noexcept {
    if (!api26RawMouseMotionEnabled) {
        return {Api26InputProbeDisposition::Excluded, false, false, false, false};
    }
    if (!isOhosBuild) {
        return {Api26InputProbeDisposition::InvalidPlatform, false, false, false, false};
    }
    return {Api26InputProbeDisposition::CompileLinkOnly, true, true, false, false};
}

constexpr bool IsStrictlyNonRouting(const Api26InputProbeContract& contract) noexcept {
    return !contract.mayRegisterCallbacks && !contract.mayPublishInput;
}

} // namespace amcl::input
