# Sherpa OHOS 运行库来源与分发材料

本目录的 JNI 来自 `k2-fsa/sherpa-onnx` 提交
`330609dab49be6ee8b30702918ca7abbbad1286a`（v1.13.3），按 `build-inputs.json`
及项目 `scripts/build-sherpa-ohos.py` 用正式 OHOS SDK 交叉编译。
AMCL 自有构建调整在 `ohos-adjustments.cmake`，只修复裸 RPATH 的 Ninja 转义并
限定最终 RUNPATH，不替换语音算法。构建时静态并入 Sherpa core、Kaldi 相关库、
OpenFST、KissFFT、simple-sentencepiece、Piper phonemize、eSpeak NG/ucd。

- Sherpa：Apache-2.0，完整许可见 `licenses/SHERPA-APACHE-2.0.txt`。
- ONNX Runtime 1.16.3：MIT，OHOS 归档来自上游维护者的
  [onnxruntime-libs](https://github.com/csukuangfj/onnxruntime-libs/releases/tag/v1.16.3)，
  原件含源码提交与第三方声明；随附许可及原第三方声明保存在 `licenses/`。
- eSpeak NG/ucd：GPL-3.0，来源为
  [f6fed6c58b5e0998b8e68c6610125e2d07d595a7](https://github.com/csukuangfj/espeak-ng/tree/f6fed6c58b5e0998b8e68c6610125e2d07d595a7)，
  完整许可见 `licenses/ESPEAK-GPL-3.0.txt`。分发包含它的组合运行库时，应同时提供
  对应源码、AMCL 构建调整和可复现配方；不能把此组合统称为 Apache 许可。
- Piper phonemize：MIT，来源提交
  [78a788e0b719013401572d70fef372e77bff8e43](https://github.com/csukuangfj/piper-phonemize/tree/78a788e0b719013401572d70fef372e77bff8e43)。
- 其余静态依赖的原始 LICENSE/COPYING 另保存在 `licenses/<dependency>-src/`。
  完整源包中 `cmake/` 的 URL_HASH 锁定各依赖归档；不靠可变的 latest 下载重建。

本目录不重新分发 Verity 模组、Whisper/Piper 模型或人物素材。模型的授权与运行库
分别核对；宿主验证只消费用户选择的原模组内字节。Ryan medium 原卡片写明其
数据集为 CC BY-NC-SA 4.0，不能因 Piper/Sherpa 代码许可证较宽松就覆盖模型条件。

完整下载、展开源码、构建缓存、失败现场与推理日志位于工作区 E 盘任务目录，
正式资格摘要在 `artifacts.json`。宿主推理通过与 OHOS 真机录放音通过是不同状态。
