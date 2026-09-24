#ifndef AMCL_PRESENTATION_OWNER_H
#define AMCL_PRESENTATION_OWNER_H
#include <cstdint>

// Pure host-side ledger. The caller serializes it with publication changes.
// Token allocation belongs to the XComponent-owning image, never a consumer
// DSO's static counter. Reference leases are a separate, non-exclusive concern.
class AmclPresentationOwner {
public:
    bool claim(void* window, uint64_t generation, uint32_t api, uint64_t& token) {
        token = 0;
        if (owner_ != 0 || !window || generation == 0 ||
            (api != 1 && api != 2) || next_ == UINT64_MAX) return false;
        owner_ = ++next_;
        window_ = window;
        generation_ = generation;
        api_ = api;
        token = owner_;
        return true;
    }
    bool move(uint64_t token, void* window, uint64_t generation) {
        if (token == 0 || token != owner_ || !window || generation == 0) return false;
        window_ = window;
        generation_ = generation;
        return true;
    }
    bool release(uint64_t token) {
        if (token == 0 || token != owner_) return false;
        owner_ = 0;
        window_ = nullptr;
        generation_ = 0;
        api_ = 0;
        return true;
    }
    uint64_t token() const { return owner_; }
    uint64_t generation() const { return generation_; }
private:
    uint64_t next_ = 0;
    uint64_t owner_ = 0;
    void* window_ = nullptr;
    uint64_t generation_ = 0;
    uint32_t api_ = 0;
};
#endif
