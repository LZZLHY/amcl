# LWJGL MR 视图的真实 Java 验证

两个探针只读 JAR，不定义游戏类、不加载 LWJGL native。默认离线测试为
`python scripts/test-lwjgl-jdk-views.py`，执行生产转换器并验证整槽保留字节、
可重现性、FFM 保留与畸形输入拒绝。

`JarEffectiveViewProbe` 使用标准 JarFile 的指定 feature 选择，逐项比较有效类/资源。
显式 feature 25 的元数据比较不证明真实 JDK 25 的 FFM 执行；后者须在设备另验。

`RemapperClasspathProbe` 运行 TinyRemapper 0.8.2 / ASM 9.5 的真实扫描。依赖通过
外部 `--scanner-dir` 提供，不编入应用或改写整合包。脚本核对如下完整 SHA-256：

| 外部文件名 | 固定坐标 / 官方取得入口 | SHA-256 |
|---|---|---|
| `device-tiny-remapper.jar` | [TinyRemapper 0.8.2](https://maven.fabricmc.net/net/fabricmc/tiny-remapper/0.8.2/tiny-remapper-0.8.2.jar) | `160c436c19707b4ae9e87502e5f04d733d8e09b4143735400c3464cb04163476` |
| `device-asm.jar` | [ASM 9.5](https://maven.fabricmc.net/org/ow2/asm/asm/9.5/asm-9.5.jar) | `b62e84b5980729751b0458c534cf1366f727542bb8d158621335682a460f0353` |
| `device-asm-tree.jar` | [ASM Tree 9.5](https://maven.fabricmc.net/org/ow2/asm/asm-tree/9.5/asm-tree-9.5.jar) | `3c33a648191079aeaeaeb7c19a49b153952f9e40fe86fbac5205554ddd9acd94` |
| `device-asm-commons.jar` | [ASM Commons 9.5](https://maven.fabricmc.net/org/ow2/asm/asm-commons/9.5/asm-commons-9.5.jar) | `72eee9fbafb9de8d9463f20dd584a48ceeb7e5152ad4c987bfbe17dd4811c9ae` |

公开克隆与 CI 可以按这些来源、文件名和摘要准备外部依赖。它们是实际故障手机取回
文件的固定身份，不声称来自一个未提供摘要的 Fabric 版本清单。第三方实现仍遵循
其上游许可，仓库只包含自有探针源代码。原包必须观察到 major 71 失败，17/21 的
完整所选槽必须 `SCAN_OK`，不能只运行正向样本。

```powershell
python scripts/test-lwjgl-jdk-views.py --java-home <宿主JDK目录> `
  --scanner-dir <仓外固定扫描器目录> --work-dir <仓外宿主构建目录> `
  --report-dir <仓外收据目录>
```

所有宿主编译输出和完整日志均外置，独立公开克隆未指定路径时使用系统临时容器；
构建、扫描和有效视图比较均记录实际执行时间、返回码与完整输出。
