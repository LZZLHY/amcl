#!/usr/bin/env python3
"""复验审查中已成立的两个合法 DSO 反例，直接运行生产通用链接/版本查询。

Linux x86_64 只拒绝桩化两个未执行的 AArch64 TLS 函数；实际 mapper/TLSDESC 仍必须
走原 AArch64 套件和目标设备。正常结果对照真实 glibc，不根据实现生成预期值。
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.lib.host_test_lifecycle import HostTestScope
from scripts.lib.workspace_paths import external_output_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-ref', help='显式读取真实旧Git提交的loader，作为成本撤回反例')
    parser.add_argument('--git-dir', type=Path, help='WSL只读Windows工作树共同对象库时显式指定')
    parser.add_argument('--sanitize', action='store_true', help='在同一真实链接/卸载用例上启用ASan与UBSan')
    args = parser.parse_args()
    output = external_output_path(args.output); output.mkdir(parents=True, exist_ok=False)
    work = HostTestScope('fixtures-', parent=output)
    source = ROOT / 'entry/src/main/cpp/jvm/elf_loader.cpp'
    # 负控只换完整旧生产源码；不删条件或拼一份人为慢算法。当前实现与旧输入共用同一驱动。
    git = ['git', '--git-dir=' + str(args.git_dir)] if args.git_dir else ['git', '-C', str(ROOT)]
    data = subprocess.check_output(git + ['show', args.source_ref + ':entry/src/main/cpp/jvm/elf_loader.cpp']) if args.source_ref else source.read_bytes()
    # Windows检出的CRLF只在宿主副本规范成LF，原始输入摘要仍取data，不改变C++语义。
    body = data.decode('utf-8').replace('\r\n', '\n')
    body, one = re.subn(r'int64_t tlsdesc_resolve_helper\(tlsdesc_data\* data\) \{.*?\n\}',
                        'int64_t tlsdesc_resolve_helper(tlsdesc_data*) { abort(); }', body, count=1, flags=re.S)
    body, two = re.subn(r'__attribute__\(\(naked, visibility\("default"\)\)\)\nvoid tlsdesc_resolver_asm\(\) \{.*?\n\}',
                        'void tlsdesc_resolver_asm() { abort(); }', body, count=1, flags=re.S)
    if one != 1 or two != 1: raise ValueError('AArch64 拒绝桩接点改变')
    body = re.sub(r'#include "([^\"]+)"', lambda m: '#include "' + str((source.parent / m[1]).resolve()) + '"', body)
    (work.directory / 'loader.cpp').write_text(body, encoding='utf-8')
    files = {
        'provider.c': 'extern void provider_finished(void);\nint anchor(void) { return 73; }\n__attribute__((destructor)) static void done(void) { provider_finished(); }\n',
        'consumer.c': 'extern int anchor(void);\nint call_anchor(void) { return anchor(); }\n',
        # 两个真实原生库同时导出 anchor。shadow 不会赢得全局选择，但它的元数据
        # 必须可安全复用；不能只测试唯一提供者而漏掉实际系统 C++ 库的重复候选。
        'shadow.c': '''extern void shadow_finished(void);
#ifndef SHADOW_VALUE
#define SHADOW_VALUE 91
#endif
int anchor(void) { return -19; }
int shadow_only(void) { return SHADOW_VALUE; }
__attribute__((destructor)) static void done(void) { shadow_finished(); }
''',
        'versions.c': 'int old_value(void) { return 11; }\nint new_value(void) { return 22; }\n__asm__(".symver old_value,versioned@OLD");\n__asm__(".symver new_value,versioned@@NEW");\n',
        'versions.map': 'OLD {};\nNEW {} OLD;\n',
    }
    for name, content in files.items(): (work.directory / name).write_text(content)
    (work.directory / 'driver.cpp').write_text(r'''/** 仅运行生产通用路径；每个生命周期断言都有真实 native 对照。 */
#include "loader.cpp"
#include <cassert>
#include <cstdio>
#include <thread>
// 计数真实公开PHDR遍历，既验证已持有依赖不会反复重建视图，也保留原生卸载对照。
static size_t phdrWalks = 0;
extern "C" int __real_dl_iterate_phdr(int (*callback)(dl_phdr_info*,size_t,void*),void* data);
extern "C" int __wrap_dl_iterate_phdr(int (*callback)(dl_phdr_info*,size_t,void*),void* data) {
  ++phdrWalks; return __real_dl_iterate_phdr(callback,data);
}
// 只在显式负例区间令生产 C++ 分配失败；正常 native 对照及初始化不注入故障。
static bool rejectAllocation = false;
// 记录真实热查询分配量，避免CPU调度噪声；只包围固定查询，不包含编译或夹具初始化。
static bool countAllocation = false;
static size_t lookupAllocatedBytes = 0;
void* operator new(std::size_t bytes) {
  if (rejectAllocation) throw std::bad_alloc();
  if (countAllocation) lookupAllocatedBytes += bytes;
  if (void* value = std::malloc(bytes ? bytes : 1)) return value;
  throw std::bad_alloc();
}
void operator delete(void* value) noexcept { std::free(value); }
void operator delete(void* value, std::size_t) noexcept { std::free(value); }
static int finished = 0;
extern "C" void provider_finished(void) { ++finished; }
static int shadowFinished = 0;
static bool checkShadowReentry = false;
extern "C" void shadow_finished(void) {
  ++shadowFinished;
  if (checkShadowReentry) {
    // 原生 fini 等待另一个线程取得自定义注册锁，验证批次清理确实释放了该锁。
    // 不在 worker 调用 native dlsym：glibc 的 dlclose 仍持有系统锁，那会构造
    // 与本修复无关的原生锁循环。单线程递归锁重入同样不能验证跨线程释放。
    std::thread query([] { RegistryLock guard; });
    query.join();
  }
}
extern "C" FILE* amclIfInet6ShimOpen(const char*,const char*) { return nullptr; }
extern "C" void amclLogPrint(AmclLogLevel,unsigned int,const char*,const char*,...) {}
int main(int argc,char** argv) {
  assert(argc == 4);
  void* provider = ::dlopen(argv[2], RTLD_NOW | RTLD_GLOBAL); assert(provider);
  if (!strcmp(argv[1], "reference")) {
    void* consumer = ::dlopen(argv[3], RTLD_NOW | RTLD_LOCAL); assert(consumer);
    assert(::dlclose(provider) == 0 && finished == 0);
    assert(reinterpret_cast<int(*)()>(::dlsym(consumer, "call_anchor"))() == 73);
    assert(::dlclose(consumer) == 0 && finished == 1);
  } else {
    void* shadow = ::dlopen("./shadow.so", RTLD_NOW | RTLD_GLOBAL); assert(shadow);
    RegistryLock guard; elf_handle_t consumer{}; uint64_t target = 0;
    // 直接运行实际重定位函数，批次与生产 open_elf_with_flags 的有效区间一致；
    // unique_ptr 的销毁也让真实旧源码负控可编译，不依赖新缓存的字段或内部布局。
    auto batch = std::make_unique<LoadBatch>(); g_loadBatch = batch.get();
    Elf64_Sym symbols[2]{}; const char names[] = "\0anchor\0";
    symbols[1].st_name = 1; symbols[1].st_info = ELF64_ST_INFO(STB_GLOBAL, STT_FUNC);
    consumer.name = "real-relocation"; consumer.base = &target; consumer.dynsym = symbols; consumer.dynstr = names;
    consumer.relocations.push_back({0,ELF64_R_INFO(1,R_AARCH64_JUMP_SLOT),0});
    assert(apply_relocs(&consumer) && target && !consumer.systemDependencies.empty());
    const size_t warmWalks=phdrWalks, ownedReferences=consumer.systemDependencies.size();
    lookupAllocatedBytes=0; countAllocation=true;
    for(unsigned i=0;i<64;++i) {
      bool hotFound=false, rejected=false;
      void* again=resolve_system_global("anchor",hotFound,nullptr,&consumer,&rejected);
      assert(hotFound && !rejected && again==reinterpret_cast<void*>(target));
      assert(reinterpret_cast<int(*)()>(again)()==73);
      assert(consumer.systemDependencies.size()==ownedReferences);
    }
    countAllocation=false;
    std::printf("held provider: PHDR walks=%zu for 64 relocations, references=%zu, allocatedBytes=%zu\n",phdrWalks-warmWalks,ownedReferences,lookupAllocatedBytes);
    std::fflush(stdout);
    assert(phdrWalks-warmWalks<=64); // 每次仅候选枚举一次；未选中的 shadow 同样不重复核同。
    // 512KiB/64次为实际热查询留有余量，同时拒绝对所有无关DSO分配完整描述。
    // 真实旧Git源码在同一驱动中的分配量超过此界；不是按CPU运行时长做易抖动断言。
    assert(lookupAllocatedBytes<512*1024);
    lookupAllocatedBytes=0; countAllocation=true;
    for(unsigned i=0;i<64;++i) {
      bool absentFound=false, rejected=false;
      assert(!resolve_system_global("amcl_no_native_definition_1030",absentFound,nullptr,&consumer,&rejected));
      assert(!absentFound && !rejected && consumer.systemDependencies.size()==ownedReferences);
    }
    countAllocation=false;
    std::printf("absent provider: allocatedBytes=%zu for 64 lookups\n",lookupAllocatedBytes);
    std::fflush(stdout);
    assert(lookupAllocatedBytes<512*1024);
    // 未被选中的候选只由当前批次临时保活，不能进入 consumer 的永久依赖图。
    // 撤回外部引用后，批次销毁应立即运行其 fini；被选中提供者仍由 consumer 保活。
    guard.unlock(); assert(::dlclose(shadow) == 0 && shadowFinished == 0); guard.lock();
    checkShadowReentry = true;
    g_loadBatch = nullptr; batch.reset();
    checkShadowReentry = false;
    assert(shadowFinished == 1 && finished == 0);
    // 新批次重新加载同一组符号、不同载荷。不得继承上个批次的名字/缺失/地址缓存；
    // native dlsym 仍决定实际提供者，两个返回值均由独立真实 DSO 定义。
    guard.unlock();
    void* next = ::dlopen("./shadow-next.so", RTLD_NOW | RTLD_GLOBAL); assert(next);
    guard.lock();
    auto nextBatch = std::make_unique<LoadBatch>(); g_loadBatch = nextBatch.get();
    elf_handle_t nextOwner{}; bool nextFound = false, nextRejected = false;
    auto nextValue = reinterpret_cast<int(*)()>(resolve_system_global("shadow_only",nextFound,nullptr,&nextOwner,&nextRejected));
    assert(nextFound && !nextRejected && nextValue && nextValue() == 92);
    assert(reinterpret_cast<int(*)()>(resolve_system_global("anchor",nextFound,nullptr,&nextOwner,&nextRejected))() == 73);
    g_loadBatch = nullptr; nextBatch.reset();
    guard.unlock(); assert(::dlclose(next) == 0 && shadowFinished == 1); guard.lock();
    while (!nextOwner.systemDependencies.empty()) close_one_system_dependency(&nextOwner);
    assert(shadowFinished == 2);
    guard.unlock(); assert(::dlclose(provider) == 0 && finished == 0);
    assert(reinterpret_cast<int(*)()>(target)() == 73);
    guard.lock(); while (!consumer.systemDependencies.empty()) close_one_system_dependency(&consumer);
    assert(finished == 1);
  }
  void* versions = ::dlopen("./versions.so", RTLD_NOW | RTLD_LOCAL); assert(versions);
  auto expected = reinterpret_cast<int(*)()>(::dlsym(versions, "versioned")); assert(expected && expected() == 22);
  auto old = reinterpret_cast<int(*)()>(::dlvsym(versions, "versioned", "OLD")); assert(old && old() == 11);
  LoadBatch snapshot{}; SystemLookupImage metadata{};
  auto* mapped = system_view_for_handle(snapshot, versions); assert(mapped && describe_system_mapped_image(*mapped, metadata));
  elf_handle_t custom{}; custom.base = reinterpret_cast<void*>(metadata.loadBias);
  custom.gnuHash = metadata.gnuHash; custom.svHash = metadata.sysvHash;
  custom.dynsym = metadata.symbols; custom.dynsymCount = metadata.symbolCount; custom.dynstr = metadata.strings;
  custom.symbolVersions = metadata.versionTable;
  bool found = false;
  auto selected = reinterpret_cast<int(*)()>(resolve_in_lib(&custom, "versioned", &found));
  assert(found && selected == expected && selected() == 22);
  const amcl::elfversions::Request request{"OLD", amcl::elfversions::hash("OLD"), false};
  selected = reinterpret_cast<int(*)()>(resolve_in_lib(&custom, "versioned", &found, &request));
  assert(found && selected == old && selected() == 11);
  const amcl::elfversions::Request missing{"ABSENT", amcl::elfversions::hash("ABSENT"), false};
  assert(!resolve_in_lib(&custom, "versioned", &found, &missing) && !found);
  // 使用真实系统库元数据建立已发布查询组，直接进入四个公开 C 查询入口。
  // 元数据复制失败必须成为 dlerror，不能越过 C ABI；失败后原组仍可查询和关闭。
  custom.published = true; custom.openReferences = 1; custom.mappingIdentity = 1;
  metadata.lookupHandles.push_back(versions);
  custom.systemImages.push_back(metadata);
  custom.handleScope = std::make_shared<LookupScope>();
  custom.handleScope->members.push_back({&custom,1,true,0});
  g_loaded.push_back(&custom); g_globalScope = custom.handleScope->members;
  for (int entry = 0; entry < 4; ++entry) {
    while (elf_dlerror()) {}
    rejectAllocation = true;
    void* value = entry == 0 ? elf_sym(&custom,"versioned") :
        entry == 1 ? elf_dlsym(&custom,"versioned") :
        entry == 2 ? elf_dlvsym(&custom,"versioned","OLD") : elf_sym_global("versioned");
    rejectAllocation = false;
    assert(!value); const char* error = elf_dlerror();
    assert(error && strstr(error,"allocation failed"));
    assert(custom.lookupReferences == 0 && g_lookupPins == 0);
    assert(reinterpret_cast<int(*)()>(elf_sym(&custom,"versioned"))() == 22);
  }
  g_globalScope.clear(); g_loaded.clear();
  // LOCAL分配失败反例结束之后才晋升真实版本库，避免改变前面入口的作用域分支。
  // 名称预筛只能增加候选；GLOBAL默认、显式旧版本和缺失版本仍须符合系统选择。
  void* globalVersions=::dlopen("./versions.so",RTLD_NOW|RTLD_NOLOAD|RTLD_GLOBAL); assert(globalVersions);
  {
    RegistryLock guard; elf_handle_t versionOwner{}; bool rejected=false;
    assert(resolve_system_global("versioned",found,nullptr,&versionOwner,&rejected)==reinterpret_cast<void*>(expected));
    assert(found && !rejected);
    assert(resolve_system_global("versioned",found,&request,&versionOwner,&rejected)==reinterpret_cast<void*>(old));
    assert(found && !rejected);
    assert(!resolve_system_global("versioned",found,&missing,&versionOwner,&rejected) && !found && !rejected);
    while(!versionOwner.systemDependencies.empty()) close_one_system_dependency(&versionOwner);
  }
  assert(::dlclose(globalVersions)==0);
  assert(::dlclose(versions) == 0);
  puts("PASS native provider ownership, default/explicit versions, missing-version rejection and C ABI allocation failures");
}
''', encoding='utf-8')
    commands = [
        ['gcc', '-shared', '-fPIC', '-Wl,--hash-style=both', 'provider.c', '-o', 'provider.so'],
        ['gcc', '-shared', '-fPIC', '-Wl,--hash-style=sysv', 'provider.c', '-o', 'provider-sysv.so'],
        ['gcc', '-shared', '-fPIC', '-Wl,--hash-style=both', 'consumer.c', '-o', 'consumer.so'],
        ['gcc', '-shared', '-fPIC', '-Wl,--hash-style=both', 'shadow.c', '-o', 'shadow.so'],
        ['gcc', '-shared', '-fPIC', '-Wl,--hash-style=both', '-DSHADOW_VALUE=92', 'shadow.c', '-o', 'shadow-next.so'],
        ['gcc', '-shared', '-fPIC', '-Wl,--hash-style=both', '-Wl,--version-script=versions.map', 'versions.c', '-o', 'versions.so'],
        ['g++', '-std=c++17', '-O1', '-g', '-pthread', '-rdynamic',
         *(['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if args.sanitize else []),
         '-I' + str(ROOT / 'tests/runtime-elf/stubs'),
         'driver.cpp', str(ROOT / 'entry/src/main/cpp/download/hmac_sha256.cpp'), '-ldl', '-Wl,--wrap=dl_iterate_phdr', '-o', 'driver'],
        ['./driver', 'reference', './provider.so', './consumer.so'],
        ['./driver', 'production', './provider.so', './consumer.so'],
        ['./driver', 'reference', './provider-sysv.so', './consumer.so'],
        ['./driver', 'production', './provider-sysv.so', './consumer.so'],
    ]
    success = False
    records = []
    try:
        env = dict(os.environ, TMPDIR=str(work.directory))
        if args.sanitize:
            env.update(ASAN_OPTIONS='detect_leaks=1', UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
        for number, command in enumerate(commands):
            result = subprocess.run(command, cwd=work.directory, env=env, capture_output=True, timeout=180)
            log = output / (str(number) + '.log'); log.write_bytes(result.stdout + result.stderr)
            records.append({'command': command, 'exitCode': result.returncode, 'log': str(log)})
            print((result.stdout + result.stderr).decode('utf-8', 'replace'), flush=True)
            if result.returncode: raise RuntimeError('链接反例执行失败：' + str(number))
        success = True
    finally:
        record = {'recordedAt': datetime.now().astimezone().isoformat(), 'passed': success,
                  'scope': 'Linux x86_64 production generic linkage; not AArch64/OHOS mapper qualification',
                  'sanitizers': ['address', 'undefined'] if args.sanitize else [],
                  'sourceSha256': hashlib.sha256(data).hexdigest(), 'commands': records}
        (output / 'receipt.json').write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding='utf-8')
        work.close(success=success)


if __name__ == '__main__': main()
