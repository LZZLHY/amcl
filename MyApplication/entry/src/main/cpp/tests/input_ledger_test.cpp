#include "../platform/input_ledger.h"

#include <mutex>
#include <sstream>
#include <string>
#include <vector>

using amcl::input::InputLedger;
using amcl::input::Output;
using amcl::input::OutputKind;
using amcl::input::OwnerToken;

extern "C" const char* runInputLedgerTests() {
    static std::string result;
    result.clear();

    std::mutex callbackMutex;
    std::vector<int> actions;
    InputLedger* ledgerPtr = nullptr;
    InputLedger ledger([&](const Output&, int action) {
        std::lock_guard<std::mutex> lock(callbackMutex);
        actions.push_back(action);
        // Re-entry must not deadlock while the ledger emit lock is held.
        if (action == 1 && ledgerPtr != nullptr) ledgerPtr->owns(100, {OutputKind::Key, 65});
    });
    ledgerPtr = &ledger;

    const Output key{OutputKind::Key, 65};
    ledger.acquire(100, key);
    ledger.acquire(200, key);
    ledger.release(100, key);
    if (actions.size() != 1 || actions[0] != 1) {
        result = "shared-owner press edge failed";
        return result.c_str();
    }
    ledger.release(200, key);
    if (actions.size() != 2 || actions[1] != 0) {
        result = "shared-owner release edge failed";
        return result.c_str();
    }

    // A new owner must not allow a later RELEASE to overtake the preceding PRESS.
    ledger.acquire(300, key);
    ledger.release(300, key);
    if (actions.size() != 4 || actions[2] != 1 || actions[3] != 0) {
        result = "transition ordering failed";
        return result.c_str();
    }

    ledger.releaseAll();
    result = "InputLedger: PASS";
    return result.c_str();
}
