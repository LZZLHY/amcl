/**
 * 仅default测试诊断的ledger算法验收。TU与唯一生产InputLedger实现共同链接neutral，
 * 使用本次调用独立的测试ledger/vector，不建立第二个进程输入owner或修改实际游戏持有。
 * entry只能调C runner；不跨库传递InputLedger、std::string/vector、锁或C++类ABI。
 */
#include "tests.h"

#ifdef MC_OHOS_BUILD_TESTS

#include "../platform/input_ledger.h"

#include <mutex>
#include <sstream>
#include <string>
#include <vector>

using amcl::input::InputLedger;
using amcl::input::Output;
using amcl::input::OutputKind;
using amcl::input::OwnerToken;

/**
 * 返回本线程诊断结果的借用C字符串。不同线程各自有缓存，不会互相clear/覆盖；指针仅
 * 有效到同线程下次本runner调用或线程退出。调用者必须当场复制，不能存入异步任务。
 * visibility与amclInput*版本规则配对；ledger本体C++方法仍全部local，不扩大生产ABI。
 */
extern "C" __attribute__((visibility("default"))) const char* amclInputRunInputLedgerTests() {
    thread_local std::string result;
    result.clear();

    std::mutex callbackMutex;
    std::vector<int> actions;
    InputLedger* ledgerPtr = nullptr;
    InputLedger ledger([&](const Output&, int action) {
        std::lock_guard<std::mutex> lock(callbackMutex);
        actions.push_back(action);
        // 原算法必须在emit lock交接后容许查询回入；不得以持锁回调造成同线程死锁。
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

    // 新owner的末松不得越过它此前的首按；两边沿顺序是实际callback记录的断言。
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

#endif // MC_OHOS_BUILD_TESTS：非诊断编译不产生runner或任何本TU测试逻辑。
