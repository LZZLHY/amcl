#ifndef AMCL_INPUT_SHADOW_CONSUMER_H
#define AMCL_INPUT_SHADOW_CONSUMER_H

#include "amcl_input_api.h"

namespace amcl::input::shadow {

struct DrainResult {
    // completed is true only after nextEvent reaches EMPTY; every host error,
    // including STALE, leaves it false so recovery can fail closed.
    bool completed;
    bool observedResetState;
    bool observedReset;
    bool resetLatched;
    bool staleConsumer;
};

// forceReopen is used at session boundaries where a cached handle can no
// longer be proven to belong to the session being created.
bool Open(const AmclInputHostApiV1* api, bool forceReopen = false);
DrainResult Drain(const AmclInputHostApiV1* api, bool terminal = false);
// Best-effort host close followed by unconditional local state cleanup.
void CloseBestEffort(const AmclInputHostApiV1* api);
// Unconditional local cleanup when no host API can safely be called.
void Abandon();

}  // namespace amcl::input::shadow

#endif
