# 字体回退源修复与回归边界

`0018-fontconfig-preserve-fallback-coverage.patch` 修复两类独立缺陷。Fontconfig 的实例/家族名
可能与 Java 注册的文件默认 face 名不同；`CompositeFont` 原来使用 `PHYSICAL_FALLBACK`
查找后会用默认字体替换已经加载成功的实际文件。候选只接受 `NO_FALLBACK` 真正返回的物理
字体；找不到名字时保留原文件，因此真实 TTC face 选择仍有效，未知变量实例名不会丢失脚本。
原有延迟初始化、合成样式和字形缓存继续工作。

OHOS 构建字体回退列表时，默认保留任何新增字符覆盖。原来的大于 20/50 个新字符阈值会丢掉
小字符集；候选继续按实际字符并集去重、沿用 254 个 slot 上限，不新增逐字形热路径扫描。
其它构建目标保持原阈值；显式调试阈值仍是开发者主动选择的诊断功能。

四代的 `FcCharSetUnion` 先成功取得新集合才交接所有权；NULL 时完整收敛旧 owned union、
四个数组、pattern、fontset、locale、provider 句柄，保留首个 JNI 异常，立即退出，不发布残缺列表。
JDK 8 另补回 owned union 的正常/失败释放以及每轮 local frame、临时字符串和对象引用释放。
四代 locale 转换失败不再清除原始异常；后续 JNI 字符串构造失败不会带异常进入下一轮。

`prepare-fallback-inputs.py` 从锁定 Git 对象导出四代完整原/候选文件并真实应用 `0018` 和 `0022`。
输入与补丁 SHA 由 `fallback-cases.json` 固定，`runtime-platform/run-tests.py` 还会从锁定对象
重放完整 series，独立确认最终 fontpath/CompositeFont 正文与测试输入完全一致。

`0022-freetype-stream-jni-and-cache-boundary.patch` 处理真实 PNG 字形初始化触发的 FreeType→Java
读桥缺陷。8/17 原来的 `CallIntMethod` 后缺异常检查；21/25 检查后清掉了原异常。四代还会在
读完成前发布 1024 字节缓存长度，短读/负数返回或异常后可能把未读尾部当成有效缓存。
候选只发布实际已读字节，异常后本次 native 调用的后续 FT 回调立即失败；正常热命中保持
一次内存复制，不增加 JNI 调用。初始化与轮廓/metrics 调用链不会带读异常继续创建 Java 对象，
scaler 失效先清 Java native 指针、释放资源，再恢复原异常。8 的 Type1 void 方法调用类型一并修正。

`stream-cases.json` 绑定真实完整 C 文件和补丁 SHA；v2 输入清单额外包含这些原/候选字节。
`run-stream.py` 抽取实际 `FTScalerInfo`、读回调、异常辅助函数和 scaler 失效函数，编译 JNI 动态库，
在真实宿主 JVM 的 `-Xcheck:jni` 和 UBSan 下执行。Java 仅控制返回值和异常对象；薄 JNI 转发器
只注入难以稳定制造的 direct-buffer OOME/无异常 NULL 和数组复制异常。覆盖正常/大块/数组读取、
短读、负数/越界结果、原异常对象身份、debug 打印后的身份，以及失效时首错与资源收敛；补前必须
复现相应负控，补后不得有 CheckJNI 警告。抽取回调验证不等于整个目标 libfontmanager 已编译执行，
仍以四代完整 images 构建和真实目标 Java 重验完成该资格。

`test-fallback-java.py` 编译执行四代真实 `doDeferredInitialisation` 方法。替身仅提供文件、
名称查找与缺失边界；原方法必须复现错误默认替换，候选覆盖四种样式的未知实例名、真实 TTC
命中、错误类型、已匹配名字、缺文件，以及再次读取不增加初始化/查找次数。

固定 `amcl` 的 `fontconfig-fallback` QA 使用已经登记的 JDK 工具链镜像，避免为测试依赖
新建镜像或永久容器。它使用镜像中**实际宿主 Fontconfig** 的 charset/pattern/fontset，记录
库版本与映射文件 SHA；这个库不等于目标 2.17.1 provider，不能据此宣称目标 ELF 已执行。

- 四代原/修复以及非 OHOS 对照共 12 个变体，各执行 100 次字符集选择；新增 1、19、20、21、
  49、50、51 字符全部覆盖，同时检查重复去重、借用集合不被误释放与 owned union 收敛。
- 实际 union 包装在第 1、3、7 次返回 NULL，并覆盖已有异常情形；源中的清理分支必须执行，
  原缺陷由明确断言确认，任意崩溃/超时不能算负控成功。ASan/UBSan/LSan 始终开启。
- 使用真实 JNI/Fontconfig 头编译修改后的整个 `getFontConfig` 函数，片段测试之外继续验证完整上下文。
- 用真实 Fontconfig 解析展开后的当前模板，核 `sans`、`sans-serif`、`serif`、`monospace` 优先序
  与请求的 weight/slant 保持。`sans` 是四代 JDK 实际请求的名称，不能只覆盖 `sans-serif`。

目标资格还要求完整重建四代 JDK，在真实设备复验所有逻辑字体的可用物理字形覆盖、JNI 警告、
冷/热开销、真实字体与图像输出。独立 CLI 的默认配置/缓存是 provider 的另一条来源与验证链，
不能由 HAP `FONTCONFIG_FILE` 成功代替。
