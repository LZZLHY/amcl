#include "../../platform/api26_input_probe_contract.h"
#include "host_test_check.h"

#include <cstdlib>

int main() {
    using amcl::input::Api26InputProbeDisposition;
    using amcl::input::IsStrictlyNonRouting;
    using amcl::input::ResolveApi26InputProbeContract;

    constexpr auto legacy = ResolveApi26InputProbeContract(false, true);
    static_assert(legacy.disposition == Api26InputProbeDisposition::Excluded);
    static_assert(!legacy.compileTranslationUnit);
    static_assert(!legacy.linkGameControllerKit);
    static_assert(IsStrictlyNonRouting(legacy));

    constexpr auto formal = ResolveApi26InputProbeContract(true, true);
    static_assert(formal.disposition == Api26InputProbeDisposition::CompileLinkOnly);
    static_assert(formal.compileTranslationUnit);
    static_assert(formal.linkGameControllerKit);
    static_assert(IsStrictlyNonRouting(formal));

    constexpr auto invalidHost = ResolveApi26InputProbeContract(true, false);
    static_assert(invalidHost.disposition == Api26InputProbeDisposition::InvalidPlatform);
    static_assert(!invalidHost.compileTranslationUnit);
    static_assert(!invalidHost.linkGameControllerKit);
    static_assert(IsStrictlyNonRouting(invalidHost));

    CHECK(IsStrictlyNonRouting(legacy));
    CHECK(IsStrictlyNonRouting(formal));
    CHECK(IsStrictlyNonRouting(invalidHost));
    return 0;
}
