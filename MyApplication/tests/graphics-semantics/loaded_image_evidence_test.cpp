// 实际NOLOAD/dladdr与证据文件I/O控制；这里只验证取证边界，不创建图形context，
// 不把受控fixture当作MobileGL绘制或OHOS运行资格。
#include "../../entry/src/main/cpp/tests/test_loaded_image_evidence.h"
#include <cstdio>
#include <cstring>
#include <iostream>
#include <functional>

namespace {
unsigned checks = 0;
void Require(bool condition, const char* name) {
    ++checks;
    std::cout << "IMAGE_EVIDENCE_CHECK case=" << name << " pass=" << condition << '\n';
    if (!condition) throw std::runtime_error(name);
}
void Reject(const std::function<void()>& action, const char* reason, const char* name) {
    bool rejected = false;
    try { action(); }
    catch (const std::exception& error) { rejected = std::strstr(error.what(), reason) != nullptr; }
    Require(rejected, name);
}
bool Mapped(const std::string& image) {
    std::ifstream maps("/proc/self/maps");
    std::string line;
    while (std::getline(maps, line)) if (line.find(image) != std::string::npos) return true;
    if (maps.bad()) throw std::runtime_error("maps read failed");
    return false;
}
}  // namespace

int main(int argc, char** argv) {
    try {
        if (argc != 4) throw std::runtime_error("usage: TEST OWNER FACADE EXTERNAL_RUN");
        const std::string owner = amcl::test_evidence::CanonicalImagePath(argv[1]);
        const std::string facade = amcl::test_evidence::CanonicalImagePath(argv[2]);
        const std::string output = argv[3];
        Require(!Mapped(owner), "initial-image-unloaded");
        Reject([&] { amcl::test_evidence::NoLoadReference absent(owner); }, "not already loaded", "noload-does-not-load");
        Require(!Mapped(owner), "noload-keeps-image-unloaded");
        void* held = dlopen(owner.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!held) throw std::runtime_error(dlerror());
        amcl::test_evidence::NoLoadReference reference(owner);
        const auto identity = amcl::test_evidence::VerifyImageOwner(reference, owner, "image_anchor");
        Require(amcl::test_evidence::CanonicalImagePath(identity.dli_fname) == owner, "actual-owner-positive");
        Reject([&] { amcl::test_evidence::VerifyImageOwner(reference, owner, "absent_anchor"); },
               "owner unavailable", "missing-symbol-refused");
        const auto copied = amcl::test_evidence::CopyImageChecked(owner, output + "/loaded-owner.so");
        Require(copied > 64, "actual-image-copy");
        Reject([&] { amcl::test_evidence::CopyImageChecked(owner, "/dev/full"); }, "failed", "copy-write-flush-failure");
        Reject([&] { amcl::test_evidence::CopyImageChecked(output + "/absent.so", output + "/absent-copy.so"); },
               "cannot open actual", "missing-source-refused");
        const auto empty = amcl::test_evidence::SaveReportChecked(output + "/empty.so", "");
        Require(empty.empty(), "empty-fixture-created");
        Reject([&] { amcl::test_evidence::CopyImageChecked(output + "/empty.so", output + "/empty-copy.so"); },
               "size invalid", "empty-image-refused");
        Reject([&] { amcl::test_evidence::CopyImageChecked(owner, output + "/missing-parent/image.so"); },
               "cannot open unique", "missing-target-parent-refused");
        const std::string bytes = "MOBILEGL_QUAL_RUN runId=fixture-only\nactual-byte-roundtrip\n";
        Require(amcl::test_evidence::SaveReportChecked(output + "/result.txt", bytes) == bytes, "report-close-readback");
        Require(amcl::test_evidence::ReadReportChecked(output + "/result.txt", bytes) == bytes, "pure-report-readback");
        amcl::test_evidence::SaveReportChecked(output + "/result.txt", "truncated");
        Reject([&] { amcl::test_evidence::ReadReportChecked(output + "/result.txt", bytes); },
               "bytes differ", "pure-read-refuses-corruption");
        Require(amcl::test_evidence::ReadReportChecked(output + "/result.txt", "truncated") == "truncated",
                "pure-read-does-not-repair-evidence");
        Reject([&] { amcl::test_evidence::ReadReportChecked(output + "/missing-report.txt", bytes); },
               "cannot reopen", "pure-read-refuses-missing-original");
        Reject([&] { amcl::test_evidence::SaveReportChecked("/dev/full", bytes); }, "failed", "report-write-flush-failure");
        void* borrowed = dlopen(facade.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!borrowed) throw std::runtime_error(dlerror());
        amcl::test_evidence::NoLoadReference facadeReference(facade);
        Reject([&] { amcl::test_evidence::VerifyImageOwner(facadeReference, facade, "image_anchor"); },
               "dependency instead", "facade-dependency-owner-refused");
        facadeReference.Retire();
        if (dlclose(borrowed) != 0) throw std::runtime_error("facade release failed");
        reference.Retire();
        Require(Mapped(owner) && dlsym(held, "image_anchor") != nullptr, "extra-reference-retire-preserves-primary-owner");
        if (dlclose(held) != 0) throw std::runtime_error("primary release failed");
        Reject([&] { amcl::test_evidence::NoLoadReference retired(owner); }, "not already loaded", "no-extra-reference-leak");
        std::cout << "IMAGE_EVIDENCE_RESULT completed=1 checks=" << checks << " failures=0\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "IMAGE_EVIDENCE_FAILURE " << error.what() << '\n';
        return 1;
    }
}
