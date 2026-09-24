#ifndef AMCL_NATIVE_WINDOW_LEASE_LEDGER_H
#define AMCL_NATIVE_WINDOW_LEASE_LEDGER_H

#include <cstddef>
#include <unordered_map>

// Legacy pointer-only reference accounting for the process-owner broker. The
// publication reference is tracked separately; this ledger only accounts for
// references explicitly granted to consumers by acquire(). This ABI cannot
// identify individual consumers: a duplicate release while another consumer
// still owns the same pointer is indistinguishable from that consumer's release.
// Callers must pair each successful acquire exactly once. Exclusive presentation
// ownership uses the separate opaque-token ledger, not this count.
class AmclNativeWindowLeaseLedger {
public:
    void granted(void* nativeWindow) {
        if (nativeWindow != nullptr) ++leases_[nativeWindow];
    }

    bool consume(void* nativeWindow) {
        if (nativeWindow == nullptr) return false;
        auto it = leases_.find(nativeWindow);
        if (it == leases_.end()) return false;
        if (--it->second == 0u) leases_.erase(it);
        return true;
    }

    std::size_t count(void* nativeWindow) const {
        const auto it = leases_.find(nativeWindow);
        return it == leases_.end() ? 0u : it->second;
    }

private:
    std::unordered_map<void*, std::size_t> leases_;
};

#endif
