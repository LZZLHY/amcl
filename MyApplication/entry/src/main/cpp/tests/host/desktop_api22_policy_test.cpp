#include "../../platform/product_input_policy.h"
#include <cstdlib>
#include <iostream>
#define CHECK(x) do { if (!(x)) { std::cerr << "failed " << __LINE__ << '\n'; std::exit(1); } } while(false)
int main() {
    using namespace amcl::input;
    CHECK(!ProductInputPolicyMatchesCompiledProduct(InputProductKind::kDesktop,21));
    CHECK(ProductInputPolicyMatchesCompiledProduct(InputProductKind::kDesktop,22));
    CHECK(!ProductInputPolicyMatchesCompiledProduct(InputProductKind::kMobile,26));
    for (unsigned api=22;api<=26;++api) {
        ResetProductInputPolicyForTest();
        CHECK(ConfigureProductInputPolicy(InputProductKind::kDesktop,api)==ProductInputConfigureResult::kApplied);
        const auto state=GetProductInputPolicy();
        CHECK(state.supportsCursorLock && state.supportsRelativeMouse && !state.acceptDirectTouchInGame);
        CHECK(state.supportsHardwareRawMouse==(api>=26));
    }
    std::cout << "Desktop API22 floor and runtime API26 raw capability PASS\n";
}
