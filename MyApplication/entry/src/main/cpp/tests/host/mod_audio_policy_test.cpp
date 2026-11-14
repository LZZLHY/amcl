/**
 * 执行真实 audio_host_policy：系统权限与设备owner是明确夹具，私有政策文件使用真实文件IO。
 * 该测试验证双进程共享撤销/旧epoch不复活和本进程意图，不声明麦克风硬件可用。
 */
#include "../../audio_host_policy.h"
#include "../../audio/audio_runtime.h"
#include "test_check.h"
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <unistd.h>
#include <vector>

namespace {
bool granted = true;
AmclAudioRecordPermissionV1 record = nullptr;
void* recordContext = nullptr;
std::string policyPath;
std::vector<int> foregroundCalls;
/** 模拟唯一Entry owner原子发布后的完整字节；测试不伪造Native缓存中的授权结果。 */
void policy(const std::string& bytes) { std::ofstream file(policyPath); file << bytes; file.close(); }
bool allowed() { return record && record(recordContext) == 1; }
}
extern "C" bool OH_AT_CheckSelfPermission(const char* permission) {
    AMCL_TEST_CHECK(std::strcmp(permission, "ohos.permission.MICROPHONE") == 0);
    return granted;
}
extern "C" int amclAudioHostBeginV1(uint64_t, AmclAudioRecordPermissionV1 check, void* context, int) {
    record = check; recordContext = context; return 0;
}
extern "C" int amclAudioHostSetForegroundV1(uint64_t, int value) { foregroundCalls.push_back(value); return 0; }
extern "C" int amclAudioHostRefreshPermissionV1(uint64_t) { return 0; }
extern "C" int amclAudioHostEndV1(uint64_t) { return 0; }

int main(int count, char** args) {
    AMCL_TEST_CHECK(count == 3);
    const std::string scenario = args[2];
    const std::string directory = args[1]; policyPath = directory + "/mod-audio-policy.v1";
    AMCL_TEST_CHECK(!amclModAudioConfigureRoot("relative"));
    AMCL_TEST_CHECK(amclModAudioConfigureRoot(directory.c_str()));
    AMCL_TEST_CHECK(amclModAudioConfigureRoot(directory.c_str()));
    AMCL_TEST_CHECK(!amclModAudioConfigureRoot("/tmp"));
    policy("v1 1 1\n");
    amclModAudioSetPolicy(true, true);
    AMCL_TEST_CHECK(amclModAudioBegin() == 0);
    AMCL_TEST_CHECK(allowed());
    if (scenario != "local") {
        // 每个首错场景在独立进程中运行；不能让前一个坏记录的永久退休掩盖下一个解析分支。
        if (scenario == "missing") unlink(policyPath.c_str());
        else if (scenario == "off-on") policy("v1 2 0\n");
        else if (scenario == "epoch") policy("v1 2 1\n");
        else if (scenario == "empty") policy("");
        else if (scenario == "zero") policy("v1 0 1\n");
        else if (scenario == "overflow") policy("v1 9007199254740992 1\n");
        else if (scenario == "trailing") policy("v1 1 1\nx");
        else if (scenario == "flag") policy("v1 1 2\n");
        else if (scenario == "negative") policy("v1 -1 1\n");
        else AMCL_TEST_CHECK(false);
        AMCL_TEST_CHECK(!allowed());
        if (scenario == "off-on") { policy("v1 3 1\n"); AMCL_TEST_CHECK(!allowed()); }
        policy("v1 1 1\n"); AMCL_TEST_CHECK(!allowed());
        amclModAudioEnd(); AMCL_TEST_CHECK(amclModAudioBegin() != 0);
        std::cout << "PASS isolated native policy first-failure case " << scenario << "\n";
        return 0;
    }
    amclModAudioSetPolicy(false, true); AMCL_TEST_CHECK(!allowed());
    amclModAudioSetPolicy(true, false); AMCL_TEST_CHECK(!allowed());
    amclModAudioSetPolicy(true, true);
    AMCL_TEST_CHECK(!allowed());
    AMCL_TEST_CHECK(amclModAudioApplyPolicy() == 0);
    AMCL_TEST_CHECK(foregroundCalls.size() == 2 && foregroundCalls[0] == 0 && foregroundCalls[1] == 1);
    AMCL_TEST_CHECK(allowed());
    granted = false; AMCL_TEST_CHECK(!allowed()); granted = true; AMCL_TEST_CHECK(allowed());
    amclModAudioEnd(); AMCL_TEST_CHECK(amclModAudioBegin() != 0);
    std::cout << "PASS real native microphone policy: private root, local intent, system token, sticky background edge and terminal session\n";
}
