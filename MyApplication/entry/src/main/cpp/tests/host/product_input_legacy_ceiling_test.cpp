#include "../../platform/product_input_policy.h"
#include "host_test_check.h"

int main() {
    using namespace amcl::input;
    for (const auto kind : {InputProductKind::kDesktop, InputProductKind::kDesktopTouch}) {
        ResetProductInputPolicyForTest();
        CHECK(ConfigureProductInputPolicy(kind, 26u) == ProductInputConfigureResult::kApplied);
        const auto policy = GetProductInputPolicy();
        CHECK(!policy.formalDesktop);
        CHECK(!policy.supportsHardwareRawMouse);
        CHECK(policy.compatibilityDesktop);
        CHECK(policy.acceptDirectTouchInGame == (kind == InputProductKind::kDesktopTouch));
    }
    return 0;
}
