#include "upload_scheduler_core.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <iostream>

namespace {

bool Require(bool condition, const char* message) {
    if (condition) return true;
    std::cerr << "mg_upload_scheduler_core_test: FAIL: " << message << '\n';
    return false;
}

mg::upload::BufferIdentity Identity(std::uint64_t object_generation = 11,
                                    std::uint64_t storage_generation = 7,
                                    std::uint32_t frontend = 3,
                                    std::uint32_t backend = 103) {
    return {5, object_generation, storage_generation, frontend, backend};
}

} // namespace

int main() {
    using mg::upload::EnqueueResult;
    using mg::upload::Limits;
    using mg::upload::OpportunityModel;
    using mg::upload::Queue;

    const std::array<std::uint8_t, 4> first{1, 2, 3, 4};
    const std::array<std::uint8_t, 3> adjacent{5, 6, 7};
    const std::array<std::uint8_t, 4> overlap{9, 10, 11, 12};

    Queue queue(Limits{4, 32});
    if (!Require(queue.enqueue(Identity(), 8, first.size(), first.data()) == EnqueueResult::Queued,
                 "first write was not queued") ||
        !Require(queue.enqueue(Identity(), 12, adjacent.size(), adjacent.data()) == EnqueueResult::Merged,
                 "right-adjacent write was not merged") ||
        !Require(queue.enqueue(Identity(), 10, overlap.size(), overlap.data()) == EnqueueResult::Merged,
                 "overlapping write was not merged") ||
        !Require(queue.recordCount() == 1 && queue.payloadBytes() == 7,
                 "merged range changed queue cardinality or payload span")) {
        return 1;
    }

    const auto& merged = queue.records().front();
    const auto* bytes = reinterpret_cast<const std::uint8_t*>(queue.payload(merged));
    const std::array<std::uint8_t, 7> expected{1, 2, 9, 10, 11, 12, 7};
    for (std::size_t index = 0; index < expected.size(); ++index) {
        if (!Require(bytes[index] == expected[index], "last-write-wins payload is wrong")) return 1;
    }
    if (!Require(merged.source_calls == 3 && merged.source_bytes == 11,
                 "merged source accounting is wrong")) {
        return 1;
    }

    const std::array<std::uint8_t, 2> other{20, 21};
    if (!Require(queue.enqueue(Identity(12), 15, other.size(), other.data()) == EnqueueResult::Queued,
                 "new object generation incorrectly merged") ||
        !Require(queue.enqueue(Identity(12, 8), 17, other.size(), other.data()) == EnqueueResult::Queued,
                 "new storage generation incorrectly merged") ||
        !Require(queue.recordCount() == 3, "generation separation lost records")) {
        return 1;
    }

    Queue bounded(Limits{1, 4});
    if (!Require(bounded.enqueue(Identity(), 0, first.size(), first.data()) == EnqueueResult::Queued,
                 "bounded queue rejected its capacity") ||
        !Require(bounded.enqueue(Identity(12), 4, other.size(), other.data()) == EnqueueResult::RecordLimit,
                 "record watermark was not enforced") ||
        !Require(bounded.recordCount() == 1 && bounded.payloadBytes() == 4,
                 "rejected enqueue mutated the queue") ||
        !Require(bounded.enqueue(Identity(), 4, other.size(), other.data()) == EnqueueResult::PayloadLimit,
                 "payload watermark was not enforced")) {
        return 1;
    }
    bounded.clear();
    if (!Require(bounded.empty() && bounded.payloadBytes() == 0, "clear did not reset queue state")) return 1;

    OpportunityModel model;
    model.upload(Identity(), 0, 4);
    model.upload(Identity(), 4, 2);
    model.barrier();
    model.upload(Identity(), 6, 2);
    model.upload(Identity(12), 8, 2);
    const auto totals = model.totals();
    if (!Require(totals.eligible_calls == 4 && totals.eligible_bytes == 10,
                 "opportunity model input accounting is wrong") ||
        !Require(totals.mergeable_calls == 1 && totals.would_submit_calls == 3,
                 "barrier or identity did not split modeled submissions") ||
        !Require(totals.max_run_calls == 2 && totals.max_run_bytes == 6,
                 "run high-water marks are wrong")) {
        return 1;
    }

    std::cout << "mg_upload_scheduler_core_test: PASS\n";
    return 0;
}
