#include "../../glfw/amcl_native_window_lease_ledger.h"
#include <iostream>

namespace {
int failures = 0;
void require(bool condition, const char* message) {
    if (condition) return;
    std::cerr << "amcl_native_window_lease_ledger_test: FAIL: " << message << '\n';
    ++failures;
}
}

int main() {
    AmclNativeWindowLeaseLedger ledger;
    void* window = reinterpret_cast<void*>(0x1234);
    void* other = reinterpret_cast<void*>(0x5678);
    require(ledger.count(window) == 0u, "empty ledger");
    require(!ledger.consume(window), "ungranted release rejected");
    ledger.granted(window);
    ledger.granted(window);
    require(ledger.count(window) == 2u, "two grants counted");
    require(ledger.consume(window), "first release consumed");
    require(ledger.count(window) == 1u, "one grant remains");
    require(!ledger.consume(other), "foreign release rejected");
    require(ledger.consume(window), "second release consumed");
    require(!ledger.consume(window), "duplicate release rejected");
    return failures == 0 ? 0 : 1;
}
