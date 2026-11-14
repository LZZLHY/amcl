# OHOS JavaSound Ports

0027 将 OHAudio 返回的真实设备描述符映射为标准 JavaSound `PortMixer` 和 `Port`。本目录的宿主、SDK 与静态产物检查分别保留证据，不把模拟供应者或 AArch64 链接成功写成目标设备测试通过。

## 公开能力边界

当前普通应用可使用 OHAudio 路由/设备查询 API，`native_audio_routing_manager.h` 和 `native_audio_device_base.h` 中本实现所用入口均自 API 12 提供，因而覆盖产品 API 20 基线。实际 SDK 头和库身份由 `verify-sdk.py` 的收据固定。

系统音量/静音另有权限边界。[官方音量管理](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/volume-management)区分系统、应用和单条音频流音量，普通应用读取/监听系统音量，主动修改通过用户操作系统音量面板完成。[API 20 NDK 音量管理接口](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/capi-native-audio-volume-manager-h)没有系统音量/静音 setter。Renderer gain、应用音量和废弃/系统 API 都不能冒充 JavaSound 硬件 Port 控制。

因此真实设备仍可枚举、按类型获得 Port 并执行 open/close；当前控制数组为空，`isControlSupported` 返回 false，私有 native setter 的误调用明确抛出不支持异常。`open` 重新核实具体设备仍在并建立本地查询句柄，不启动采集/播放，不声称占用了系统硬件或取得了麦克风权限。此限制保存在独立能力字段，未来公开 SDK 提供合法 setter 时再扩展实际映射。

## 生产实现

- `ports_ohos.c/.h` 复制 SDK 返回的完整名字/地址并立即释放 SDK 数组；真实 id、role、type、name、address 联合确定身份。列表重排保持 token，同数量设备替换使旧 token 失效，已持有的旧 Java 对象不能打开新设备。
- 每个真实 descriptor 对应一个 mixer 和一个 source/target Port。系统 DEFAULT/INVALID 选择占位符不伪装设备；未知但真实的设备保留名字和未知类型。已知麦克风、扬声器、有线/USB 耳机映射标准 Port 类型。
- `ports_jni.c` 将标准 UTF-8 精确解码成 UTF-16，保留非 BMP 字符和长名字；无效编码明确失败。Java 层原两类通过 `patch-java.py` 精确修改，完整候选数组准备成功后才发布缓存，并在 open 失败时撤销资源。
- 只在显式枚举/open/控制查询时同步刷新。没有系统回调、后台轮询线程或 PCM 热路径扫描，也不需要新的 HAP CFI 回调桥。互斥保护快照/句柄，单调计数到有符号 jlong 边界时明确失败。
- 非 OHOS 继续上游平台实现；通用 `PortMixerProvider.c` 新增返回 0 的代次兼容入口。JDK 8 两个显式 mapfile 都补兼容导出，主 jsound 另外导出 snapshot/open 两个新入口。

## 来源和补丁

`reference/source.json` 固定四代上游提交、URL、逐文件 SHA，原版权/许可正文逐字保留。`reference/**` 使用 `-text` 属性，不能由 Git 换行转换。`prepare-reference.py` 只获取精确提交原文到新外置目录；`--reuse` 可消费已核身份的先前获取目录。

`make-patches.py` 从这些原文重放已登记 0001–0025 和明确的 0026，再生成 `0027-ohos-javasound-device-ports.patch`，逐字节比较重放结果。它不修改 `series` 或共享 packager。正式生成顺序必须接当前已冻结 MIDI 0026 后像；0028 在其后，不能覆盖现有尾项。

```sh
python3 -B tests/java-sound-ports/make-patches.py --output /outside/ports-patches --write-patches
```

## 验证入口

固定 `amcl/qa` 服务执行 `java-ports` suite，沿项目 Docker 工作卷/状态合同传外置输出。`run-host.sh` 先运行实际生产 C 的 ASan/UBSan/LSan 回归，再由 `run-jni-host.py` 编译四代真实补后 Java 类与同源生产 JNI。SDK 供应者和 RegisterNatives 只用于明确的宿主注入，不冒充产品加载。

核心回归包含完整名字、设备重排/同数量替换、旧句柄、空列表、13 类 SDK 错误、所有刷新/open/复制分配点失败、计数边界和并发 open/close。Java 回归覆盖真实标准类型、对象身份保留、异常后恢复、失败回滚、无假控制和完整 Unicode；将同一供应者强行变成旧零设备结果必须触发功能断言失败。

JDK 8 宿主 `java` 直接入口曾在测试 main 之前产生一条 CheckJNI 警告，原输出单独保留。正式四代正负例改用 `ports_vm_launcher.c` 的标准 JNI Invocation，逐步检查异常并先 Detach 后 Destroy，始终启用 `-Xcheck:jni`，正负例都不允许诊断。该结果只授宿主 Invocation/Ports 行为资格，不能授目标独立 CLI 资格。

```sh
python3 -B tests/java-sound-ports/verify-sdk.py \
  --sdk /outside/openharmony/native --jni-headers /outside/locked-jni-headers \
  --patches /outside/ports-patches --output /outside/ports-sdk
python3 -B tests/java-sound-ports/test-artifact.py \
  --sdk-libs /outside/openharmony/native/sysroot/usr/lib/aarch64-linux-ohos \
  --sdk-audit /outside/ports-sdk --output /outside/ports-artifact
```

`verify-sdk.py` 真实编译链接生产代码，读回 SDK 强导入、只读能力节和 JNI 导出；JDK 8 原/候选 version-script 实际链接作正负控。专项只含 Ports 两个编译单元，`--undefined-version` 仅允许完整 mapfile 列出本专项未编译的 PCM/MIDI 符号；三项新 Ports 导出必须实际存在，不能借该参数跳过导出检查。

`test-artifact.py` 检查 `docker/scripts/verify_jdk_ports.py` 的正负边界；可重复传 `--legacy-ledger /outside/candidates.json`，逐包核原 ZIP SHA 后确认旧无 Ports 库仍返回无后端。损坏 SDK 只写测试输出，不修改 SDK 或历史运行包。

## 产物合同与剩余验证

唯一 `.amcl.ports` 标记为 33 字节 `AMCL_PORTS_OHOS_API20_DEVICES_V1\0`，要求 PROGBITS、flags=2 且位于真实 R&&!W PT_LOAD。静态门要求 `libohaudio.so` 的 8 个精确强导入和 15 个可解析 JNI 导出，逐项绑定本次实际 SDK provider SHA。

`javaSound.ports` 为 `device-ports-requires-device-test`。`javaSoundPortsBackend` 为 `ohos-device-ports-v1`、minimumApi 20、qualification `implemented-requires-device-test`，并明确 `systemControlWrites=not-public-api`、`controlsExposed=false`；`requiredSymbols` 仅列固定 8 个 Ports API。无 marker 的历史库保持 `unavailable-safe`。主 packager 和发布仓独立 JS 门由总负责人接线，不能仅改能力字符串。

完整四代 JDK 构建、实际设备枚举/名字/类型/open/close/拔插、普通应用权限边界和公开预览交付仍需分别验收。宿主测试中的四个固定描述符不是目标设备清单，也不保证每台设备都存在某种硬件。
