#include "../../platform/product_input_policy.h"
#include "host_test_check.h"

#include <cstdlib>
#include <iostream>

using amcl::input::ConfigureProductInputPolicy;
using amcl::input::InputProductKind;
using amcl::input::ProductInputConfigureResult;
using amcl::input::ProductInputPolicyMatchesCompiledProduct;
using amcl::input::ResetProductInputPolicyForTest;

int main() {
    CHECK(ProductInputPolicyMatchesCompiledProduct(
        InputProductKind::kDesktop, 26u));
    CHECK(ProductInputPolicyMatchesCompiledProduct(
        InputProductKind::kDesktop, 27u));
    CHECK(!ProductInputPolicyMatchesCompiledProduct(
        InputProductKind::kDesktop, 21u));
    CHECK(!ProductInputPolicyMatchesCompiledProduct(
        InputProductKind::kMobile, 26u));
    CHECK(!ProductInputPolicyMatchesCompiledProduct(
        InputProductKind::kDesktopTouch, 26u));

    ResetProductInputPolicyForTest();
    CHECK(ConfigureProductInputPolicy(InputProductKind::kMobile, 26u) ==
           ProductInputConfigureResult::kBuildMismatch);
    CHECK(ConfigureProductInputPolicy(InputProductKind::kDesktop, 21u) ==
           ProductInputConfigureResult::kBuildMismatch);
    CHECK(ConfigureProductInputPolicy(InputProductKind::kDesktop, 26u) ==
           ProductInputConfigureResult::kApplied);

    std::cout << "product_input_formal_build_contract_test: PASS\n";
    return 0;
}
