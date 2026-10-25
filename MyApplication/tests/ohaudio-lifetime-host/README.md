# OHAudio 回调代码映像生命周期合同

该Linux宿主入口直接编译生产OpenAL、`ohaudio.cpp`和完整L2 backend TU，经真实
`extal_LoadLibrary/UnloadLibrary`调用标准ALC生命周期。GC只除去未执行的窗口/输入
代码，不复制音频算法。系统mock复用既有`ohaudio-host`，在独立DSO内保存Release
失败的回调地址；测试进程持有mock，不持有被测OpenAL的隐式DT_NEEDED引用。

每例使用干净进程：正常Release成功后卸载/重建两轮；失败有实际额外dlopen引用；
失败无额外引用；取得当前owner失败；NOLOAD返回真实外库handle但出口owner不符。
失败获取引用必须在发布任何回调/Generate前拒绝，并证明本次错handle已回滚。
成功报告要求唯一末尾完成行、实际退出与必需映射/晚回调/拒绝行完整，Python-O
不会取消平台调用或检查。

所有Source/Header路径均为所属真实输入，支持公开clone显式仓外目录。正常L2 JNI
头及固定上游展开树来自`scripts/build-lwjgl2-ohos.py`；不可手写伪ABI头替代。

```bash
cmake -S tests/ohaudio-lifetime-host -B /external/new-build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DLIBTYPE=SHARED \
  -DAMCL_OPENAL_SOURCE_DIR=/actual/pinned-openal-source \
  -DAMCL_JNI_HEADERS=/actual/jni-headers \
  -DAMCL_LWJGL2_HEADERS=/actual/generated-l2-jni-headers \
  -DAMCL_LWJGL2_UPSTREAM=/actual/fixed-l2-upstream
cmake --build /external/new-build -j4
python3 tests/ohaudio-lifetime-host/probe.py --build /external/new-build --output /external/new-evidence
```

运行遵循主工程固定`amcl/qa`服务及现有OS锁；对象/日志显式外置。不得强制NODELETE、
手工munmap、关音频或改变reload来制造通过。正常调用者持有原库句柄直至其API
调用返回；backend额外lease只覆盖已发布回调。Release确认成功且active归零后
释放lease，原调用栈返回后L2卸载才可真正unmap；Release失败时数据与code一起保留。

该合同证明独立通用代码生命周期，不能用来认定PID5071/system AudioPolicy首错。
实际OHOS库、平台服务、JVM/LWJGL2消费者与真机资源reload须另行验收。Windows生产
分支使用实际FROM_ADDRESS引用，并非此Linux映射测试的已测范围。

## L2 原卸载诊断边界的宿主反例

新增夹具仍包含完整生产 backend C TU，仅让自有测试在同一 TU 绑定私有 provider
状态，避免为生产增加 setter；CMake 不再重复编译该 TU。真实 provider DSO 提供
identity getter 和 glfwCreateWindow anchor，错 provider 使用实际不同的映像 base。
link-time `--wrap=dlclose` 只在生产 unload 周围启用，真实转调系统 close，分别核
空 handle 零次、非空一次、入口与返回 errno。OpenAL DSO 内 CodeLease close 不由
该 executable wrapper 计数；测试注入的返回值/errno只校准观察合同，不是平台失败。

mask3/7 正例须有同 PID/TID/epoch、handle 与预取地址/base 的 enter/return 对；缺
provider、缺 getter、不同映像、非default、缺必需位或无效canonical字符串须零
marker。全局同名getter不能代替当前provider出口；stderr sink失败也必须完成原
close和清handle。原五项数据/代码寿命、两轮正常卸载与拒绝发布检查继续独立成立。

`unload_epoch_ns` 是close前事务时间，不是return完成时间或耗时；pair/result0
不证明unmap、refcount0、Builder/CodeLease完成、系统weak对象退休或音频修复。
新增源码与解析的静态检查、真实host运行、OHOS Native/HAP及新设备进程各自授
资格。尚未执行新增用例时须记录NOT_RUN；设备因果判定见现有规划书§22.13。
