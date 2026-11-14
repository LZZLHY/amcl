# Verity 使用的 Sherpa OHOS 运行库

此目录交付 `libsherpa-onnx-jni.so` 与 `libonnxruntime.so`。Sherpa、Piper、
eSpeak/ucd 等核心代码静态合入 JNI；系统依赖按 `artifacts.json` 的实际 ELF
NEEDED 记录，包含 OHOS 的 hilog/rawfile 及 libc++/libc。模型不随启动器重复打包。

`verified-bindings.json` 精确记录已验证的 Verity 5.7.3 和 6.0.0 各 235 个原
Sherpa class 的 SHA-256。两版 class 字节不同，全部私有字段/方法描述符一致，
原模型与宿主 JNI/ORT 也相同。`java-abi-contract.json` 保留完整 ABI。
只对命中已知完整 class 集合的实例设置官方 `sherpa_onnx.native.path`；发现
未知、混合或冲突定义时不得强制覆盖。不能将一个 ABI pin 扩写为所有 AI 模组支持。

实际产物经正式 OHOS SDK 编译，AArch64、SONAME、RUNPATH、依赖和使用到的 JNI
导出由 `scripts/check-sherpa-artifacts.py` 检查。相同锁定源码和 ORT 1.16.3 另经
Windows MSVC 编成真实宿主 JNI，分别用两版原绑定与原模型完成 Piper 合成回调→
22050Hz 波形→Whisper 重采样/识别，并正确释放对象。固定句开头存在 hello/a low
误识别，验证的是推理链而非识别质量。OHOS 执行、音频硬件、完整模组启动仍未实测。

重建时先准备显式仓外输入与输出（以下路径是本轮任务示例）：

```powershell
python -B scripts/prepare-sherpa-inputs.py --output E:/AMCL/.workspace/run/ai-voice-1025/sherpa/inputs
python -B scripts/build-sherpa-ohos.py --inputs E:/AMCL/.workspace/run/ai-voice-1025/sherpa/inputs --build E:/AMCL/.workspace/build/ai-voice-sherpa --output E:/AMCL/.workspace/run/ai-voice-1025/sherpa/new-ohos-run --sdk D:/Huawei/command-line-tools/sdk/default/openharmony/native
python -B scripts/check-sherpa-artifacts.py
```

构建只改子进程的临时目录，所有大文件外置，不安装新 SDK、不开 Docker 环境。
`build-inputs.json` 同时固定 Sherpa 归档、候选 ORT 和本工程 JNI 头。新增运行库
版本先比较完整 Java/native 契约，再取得真实模型证据，更新清单与制品锁。
分发资料与对应源码入口见 [NOTICE.md](NOTICE.md)。
