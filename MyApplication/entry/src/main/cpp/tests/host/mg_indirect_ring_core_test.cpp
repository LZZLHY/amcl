#include "indirect_ring_core.h"

#include <array>
#include <cstdlib>
#include <iostream>

namespace {

void Require(bool condition, const char* message) {
    if (condition) return;
    std::cerr << "mg_indirect_ring_core_test: FAIL: " << message << '\n';
    std::exit(1);
}

} // namespace

int main() {
    mg::indirect_ring::Cursor<4> cursor;
    std::array<bool, 4> available{true, true, true, true};
    const auto acquire = [&]() {
        return cursor.acquire([&](std::size_t slot) { return available[slot]; });
    };

    Require(acquire() == 0 && acquire() == 1 && acquire() == 2 && acquire() == 3,
            "ring did not rotate fairly through free slots");
    Require(acquire() == 0, "ring did not wrap to slot zero");

    available = {false, false, true, false};
    Require(acquire() == 2, "ring did not skip busy slots");

    available = {false, false, false, false};
    Require(acquire() == -1, "MD-02: all-busy ring did not request backend fallback");

    available[1] = true;
    Require(acquire() == 1, "retired slot did not become acquirable");

    cursor.reset();
    available = {true, true, true, true};
    Require(cursor.next() == 0 && acquire() == 0, "context reset did not reset ring ownership");

    std::cout << "mg_indirect_ring_core_test: PASS\n";
    return 0;
}
