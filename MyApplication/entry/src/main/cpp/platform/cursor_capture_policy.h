#ifndef AMCL_CURSOR_CAPTURE_POLICY_H
#define AMCL_CURSOR_CAPTURE_POLICY_H

#include "cursor_lock.h"
#include "../input/amcl_input_event.h"

#include <cstdint>

namespace amcl::input {

struct CursorCapturePublication {
    bool requested = false;
    bool active = false;
    uint32_t reason = AMCL_INPUT_CAPTURE_REASON_NONE;
};

// Converts the synchronous WindowManager outcome into the backend-neutral
// capture tuple.  Request intent and platform activation stay distinct: only a
// successful lock (or a proven unchanged locked state) may publish active=true.
inline CursorCapturePublication CursorCapturePublicationForResult(
        bool requested, AmclCursorLockResult result) {
    CursorCapturePublication publication{};
    publication.requested = requested;
    // Releasing intent makes application-side capture inactive immediately.
    // Unlock errors remain in the cursor-lock result/log; publishing them as a
    // capture loss would count "unsupported" four times a second on API < 22
    // even though capture was never requested.
    if (!requested) return publication;
    switch (result) {
        case AMCL_CURSOR_LOCK_OK:
        case AMCL_CURSOR_LOCK_UNCHANGED:
            publication.active = true;
            publication.reason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
            break;
        case AMCL_CURSOR_LOCK_UNSUPPORTED:
            publication.reason = AMCL_INPUT_CAPTURE_REASON_UNSUPPORTED;
            break;
        case AMCL_CURSOR_LOCK_PERMISSION_DENIED:
            publication.reason =
                AMCL_INPUT_CAPTURE_REASON_PERMISSION_DENIED;
            break;
        case AMCL_CURSOR_LOCK_INVALID_ARGUMENT:
            publication.reason =
                AMCL_INPUT_CAPTURE_REASON_INVALID_ARGUMENT;
            break;
        case AMCL_CURSOR_LOCK_PLATFORM_ERROR:
        default:
            publication.reason = AMCL_INPUT_CAPTURE_REASON_PLATFORM_ERROR;
            break;
    }
    return publication;
}

}  // namespace amcl::input

#endif  // AMCL_CURSOR_CAPTURE_POLICY_H
