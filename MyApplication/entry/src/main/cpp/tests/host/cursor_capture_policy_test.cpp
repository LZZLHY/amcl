#include "../../platform/cursor_capture_policy.h"

#include <cstdlib>
#include <iostream>

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "CURSOR CAPTURE POLICY FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}

#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

void Check(bool requested, AmclCursorLockResult result, bool active,
           uint32_t reason) {
    const amcl::input::CursorCapturePublication publication =
        amcl::input::CursorCapturePublicationForResult(requested, result);
    CHECK(publication.requested == requested);
    CHECK(publication.active == active);
    CHECK(publication.reason == reason);
}

}  // namespace

int main() {
    Check(true, AMCL_CURSOR_LOCK_OK, true,
          AMCL_INPUT_CAPTURE_REASON_GRANTED);
    Check(true, AMCL_CURSOR_LOCK_UNCHANGED, true,
          AMCL_INPUT_CAPTURE_REASON_GRANTED);
    Check(false, AMCL_CURSOR_LOCK_OK, false,
          AMCL_INPUT_CAPTURE_REASON_NONE);
    Check(false, AMCL_CURSOR_LOCK_UNCHANGED, false,
          AMCL_INPUT_CAPTURE_REASON_NONE);
    Check(true, AMCL_CURSOR_LOCK_UNSUPPORTED, false,
          AMCL_INPUT_CAPTURE_REASON_UNSUPPORTED);
    Check(true, AMCL_CURSOR_LOCK_PERMISSION_DENIED, false,
          AMCL_INPUT_CAPTURE_REASON_PERMISSION_DENIED);
    Check(true, AMCL_CURSOR_LOCK_INVALID_ARGUMENT, false,
          AMCL_INPUT_CAPTURE_REASON_INVALID_ARGUMENT);
    Check(true, AMCL_CURSOR_LOCK_PLATFORM_ERROR, false,
          AMCL_INPUT_CAPTURE_REASON_PLATFORM_ERROR);
    Check(false, AMCL_CURSOR_LOCK_PLATFORM_ERROR, false,
          AMCL_INPUT_CAPTURE_REASON_NONE);
    std::cout << "cursor_capture_policy_test: PASS\n";
    return 0;
}
