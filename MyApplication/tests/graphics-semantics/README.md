# 共享真实图形语义场景

这是规划书 §22.4 的 B1 首批实现。`depth_range_scene.cpp` 是 host 与 OHOS
default/TestHooks 共用的场景，全部 GL 操作来自调用者的生产 resolver。
场景不创建或切换 context，不安装全局函数表；调用者先建立合法、专用的 current
context，核对每个函数的真实映像，场景结束后再由同一个资源 owner 退休 context。

深度范围验收使用非默认、反向、越界 clamp、超大有限 double、两端相等、float/double
交替。两种查询都检查两个分量和数组 guard。真实绘制使用独立的 64×64
RGBA4/DEPTH_COMPONENT16 FBO，每个用例以两个预先固定的 clear-depth 阈值执行
`GL_LESS` 比较，读回内点 8×8 区域。预期像素直接来自规范和用例常量，绝不从
被测查询结果生成；原始 RGBA、匹配像素数量、查询值及 GL 错误逐项输出 JSONL。

查询容差固定为 `2e-6`，RGBA 通道容差固定为 `3`，完整参考默认重复三次；阈值
远离 16-bit 深度量化边界。没有进行性能测量，不据此声称速度或内存改善。
旧 GL 错误在开始时单独记录并有限清空；shader/FBO/新 GL 错误等使
`completed=false`，不能用这类环境失败冒充成功检出 stub。

规范依据是 Khronos 官方
[glDepthRange](https://registry.khronos.org/OpenGL-Refpages/gl4/html/glDepthRange.xhtml)、
[glDepthRangef](https://registry.khronos.org/OpenGL-Refpages/es3.0/html/glDepthRangef.xhtml)
和 [glDepthFunc](https://registry.khronos.org/OpenGL-Refpages/es3.0/html/glDepthFunc.xhtml)。
这些规则要求桌面深度范围在 `[0,1]` 内 clamp、允许 near 大于 far，并由实际深度
比较决定 fragment 是否写色；测试使用固定精度深度附件，满足 GLES 对 clamp 的前提。

## Linux 软件参考与判据负控

系统需要 C++17 编译器、Python 3、Mesa EGL/桌面 OpenGL 运行库和 `readelf`。
默认使用已消费 MG 的 vendored EGL 及初始化 ABI 头，因而不要求安装系统 dev 包。
输出目录必须显式指定且在主工程外；重复运行换一个新的目录，不覆盖旧失败证据。

```bash
python3 -B tests/graphics-semantics/run-host.py \
  --output /absolute/external/run/depth-range \
  --build /absolute/external/build/depth-range
```

参考通过 EGL 的 Mesa desktop OpenGL 真实执行 shared scene。每次 case group 都
是独立新进程，固定软件 rasterizer、surfaceless EGL。三项局部 resolver 负控分别
返回空 double setter、忽略开启 depth test、仅写 double 查询第一分量；它们必须
完成绘制并命中特定语义反例，否则 runner 失败。这些是 oracle 校准，**不等于
MG 旧版本或新修复的像素证据**。

可选 `--library /absolute/libmobileglues.so` 在参考校准之外增加真实 Linux MG
DSO 测试，要求指定库导出 MG 初始化、完整 GL 与 EGL 包装接口。所有 GL/EGL
符号必须属于该 MG 映像，不允许缺符号时回退系统实现。该选项不会构建 MG，也不
用宿主结果替代 OHOS 最终载荷验证。正式消费的是 OHOS 整合 `libamcl_gl_host.so`，
其最终身份和设备结论由应用探针及交付验收记录确认。

`identity.json` 记录测试源、编译器、编译命令、主仓 HEAD、实际 executable SHA/BuildID、
固定阈值与环境；`results.json` 区分正例、负控校准及可选生产结果。
每个独立进程保留 `process.log`、`functions.tsv`、`graphics-maps.txt`、
`summary.json` 和 `evidence.jsonl`。实际映射的 GLVND 与 Mesa rasterizer DSO
另记录 SHA/BuildID，入口 dispatch 映像与真正驱动身份不混用。

`depth_range_cases.json` 是薄宿主解析器共用的机器清单：必需场景、查询类别、
像素数量、资源退休检查及完成计数均从此读取；必需函数从实际场景的 `LOAD`
语句读取。判定必须核对全部原始条目、函数映像和唯一末尾 `scene-end`，报告
缺失或只剩一个合法 JSONL 行都失败，不能仅凭进程退出零或 summary 自述 PASS。
场景的 `ValidateCompleteDepthRangeEvidence()` 也在 caller 写 PASS 前核对同一范围。

## OHOS 同路径入口

default/TestHooks 的开发者工具增加“MG 深度范围”。它经 `NativeProbeRegistry`
唯一绑定 `runMgDepthRangeTest()`，再调用 `graphics_depth_range_test.cpp`。
进程环境登记已封存、图形 runtime 已存在或 MG 已非 COLD 时明确返回 `NOT_RUN`，
需要重启应用后在启动游戏前运行；拒绝样本不能记成资格 PASS。

合法启动在冷启动的专用诊断 app 进程直接冻结 `mobileglues/OPENGL`，调用生产
context 操作表建立独立 auxiliary pbuffer，在 current owner 线程执行 shared scene，
逐个 `dladdr` 核对 MG 实际映像，然后由同一 context owner 退休。不从多线程
ArkUI/NAPI 进程 fork 后运行 C++、动态装载器或驱动；fork 不足以证明冷进程。

探针认领后原子门永久要求重启，TestHooks 的游戏/JVM 入口拒绝继续运行。
宿主在动作前开始采集 hilog，监督 30 秒上限；收到完成报告后必须 force-stop
这个诊断 app 进程，下一次游戏或测试从重启后的进程开始。强制停止只负责清理，
不当作进程自然退出资格。配置和缓存隔离在探针专用沙箱目录，报告为
`files/mg-depth-range-probe/result.txt`；该测试不触碰游戏窗口。

每次报告绑定 `PROBE_RUN` 的 runId/PID/实际 Unix 与单调时钟，末尾 `PROBE_END`
说明函数执行完成。所有文件写入、flush、close 及回读成功后，NAPI 返回与 hilog
额外发布外部 `PROBE_RETURN`，绑定相同 runId/PID/报告字节数；这个外部 marker
必须由宿主动作前启动的观测通道收取。缺外部返回证据或不完整 case/计数/身份
都不能仅凭报告内的 PASS 验收。宿主同时回收原报告和实际最终 DSO/HAP 身份。

探针在 `dladdr` 确认实际已装入 provider 后，严格检查读取、写入、flush、close
和字节数，将该实际文件复制为 `files/mg-depth-range-probe/loaded-libamcl_gl_host.so`。
报告记录 `IMAGE_COPY` 的文件名、实际字节数和回收路径。宿主必须 HDC 回收
这个设备实际加载库的副本、计算 SHA，再与已安装最终 HAP 的对应 ZIP 成员及
资格解析器的预期库 SHA 比较；只对构建产物自取 SHA 不足以证明设备载荷身份。

其他产品的正常构建继续裁剪 TestHooks 整条 native 入口和 shared scene。
设备通过只覆盖实际执行的 GPU/provider/载荷；context 共享、完整 CTS、世界
生命周期和游戏场景资格仍分别按规划书的后续批次验收。

## 声明初值共享场景

同一受控入口接续 `RunUniformInitializer()`，仍使用生产resolver、同映像地址和
同一个专用current owner。两份结果独立：depth为83/26/24，initializer为16/2/2；
新场景的机器契约是 `uniform_initializer_cases.json` / sceneVersion1，真实函数
清单从 `U_LOAD`读取。原depth清单与旧历史证据不被改写成新shader通过。

GLSL330的 `uniform vec4 tint=vec4(.25,.5,.75,1)` 在成功link之后、任何UseProgram
或setter之前查询；随后在独立线性RGBA8附件绘制，读回固定8×8内部像素。
预期 `[64,128,191,255]` 及容差1来自独立Mesa实际校准。再合法设置绿色并查询/绘制，
用于排除“只是query路径坏”或“固定色/FBO读回路径坏”。声明初值是
[GLSL3.30规范 §4.3.5](https://registry.khronos.org/OpenGL/specs/gl/GLSLangSpec.3.30.pdf)
定义的link初始化语义；该场景不是ESSL原生初值资格或完整GLSL能力证明。

```bash
python3 -B tests/graphics-semantics/run-host.py --scene initializer \
  --output /absolute/external/run/initializer \
  --build /absolute/external/build/initializer \
  --library /absolute/actual/libmobileglues.so
```

Mesa参考与只移除声明的局部oracle控制分开记录；MG生产正例必须来自指定完整DSO，
包括真实MG EGL/current包装。旧完整a3d在同一场景的default query/pixel两项失败、
manual query/pixel正确，已审b976新完整库与Mesa均16/2/2通过。底层库装载失败的
初次尝试保留，不能当作initializer负反例。软件结果仍不替代最终OHOS载荷。

OHOS报告以 `BEGIN MG_UNIFORM_INITIALIZER sceneVersion=1 shader=desktop330` 分段，
独立 `initializer-scene-end` 与 `MG_UNIFORM_INITIALIZER_RESULT`。两份scene、函数
分段multiplicity、同owner退休和外部PROBE_RETURN都完整才返回整体PASS。
第三批宿主验收必须给 `scripts/check-mg-depth-evidence.mjs --require-initializer 1`，
否则仅可复核旧depth范围。不能借旧83/26/24或GLES public desktop版本字符串
宣称B2 namespace合同/FP64/所有shader语义成立。

## MobileGL实际映像取证

现成RenderPage出帧探针仍调用production capability executor。default/TestHooks
包装仅追加 `MOBILEGL_QUAL_RUN/IMAGE/END/RETURN`，原capability文本/admission不变。
以已装入的同目录 `libmobilegl.so` 作NOLOAD引用，`eglGetDisplay` 的真实dladdr文件
canonical路径必须等于请求DSO，依赖facade借出的符号被拒绝。额外NOLOAD引用经
RAII退役，production静态hold不被接管。只复制符号实际文件，不声称所有内存字节SHA。

每次run在 `files/mobilegl-capability-probe/<PID-steadyNs>/` 新建唯一目录，严格检查
copy原字节数、读/写/flush/close及报告关闭后完整回读。I/O失败仅使artifact资格
INCOMPLETE，原production功能PASS保持原文。实际独立UI返回的RETURN必须晚于
成功close/readback；文件END或旧目录copy不能自行证明这一步完成。

宿主回收该run的原report和 `loaded-libmobilegl.so`，使用
`scripts/check-mobilegl-loaded-evidence.mjs` 绑定独立HDC PID/runId、冻结HAP SHA、
真实copy原字节及包内唯一库成员。函数完成不代表app自然退出，lifecycle_smoke
仍单独NOT_RUN。`run-image-evidence-host.py` 的16项NOLOAD/facade/真实I/O控制只
证明此取证接缝，Node正反例只证明薄门，不冒充目标GPU或OHOS资格。

## MG frontend owner 宿主资格

`scripts/test-mg-frontend-context.py` 显式接收完整 Linux GL host DSO、真实 MG commit
和新的仓外输出目录。它编译当前主 runtime、实际 owner factory 与 probe，并逐字执行
GLFW 属性及 client API 前置门；每种读取顺序在独立进程建立本次自己的 X11 窗口、
auxiliary/parking/context。使用外置 Linux transport 依赖时传 `--driver-dir`，不覆盖
游戏表；`--x11-include` 允许传真实解包头根，`--sanitizers` 只重编译主runtime/harness。

成功必须有对应 MG source identity、EGL/GL同provider、四次交叉查询、hint变更后
实际授予属性、显式 ES 零分配拒绝、停车/恢复/错线程拒绝、配置上限拒绝的资源保留与
退休、真实共享对象读回，以及同current的depth83/26/24/0和initializer16/2/2/0。
唯一 `FINAL failures=0 contexts=0 permits=0` 必须处于日志末尾；环境错误、截断、
错库或缺项不得当 PASS。普通 preflight 继续通过原 runtime TU 门检查完整 API合同。
宿主仅给 WindowHost 的只读 generation 提供链接桩，尚未验证 OHOS NativeWindow
租约、最终包、目标 GPU、真实 JVM capabilities 或完整 core/CTS。

## 后续default/TestHooks场景与原始证据

MG身份入口 `runMgContextIdentityTest(0/1)` 分别运行低/高版本首次顺序，必须在不同
冷app进程执行。共享 `mg_context_identity_scene.cpp` 使用原production factory，
首个owner后调用真实feature probe取得第二aux资格，再交叉EGL/GL/owner grant与
held pointer内容，固定11/4/0。它不替代depth83/26/24、initializer16/2/2或JVM/Core资格。

`runMobileGlProgramTest()` 使用 `mobilegl_program_scene.cpp` 的monolithic/current
与固定动态uint pair判据；当前目标入口只接受独立系统Vulkan实测nativeFloat64=false，
并核实际Magma/物理device相符。40/7/9的合法Double link拒绝是限制资格，Core FP64
仍不合格；宿主支持分支43/8/10不是vertexFloat64/pipeline/compute或完整GL43资格。
失败重链后的旧current像素、managed sampler/UBO、公开link状态及四API错误各有原值。
同FP64对象的pending-error Link与空旧错freshLink分开测试，完整UTF8日志长度和error尾
均为必需原字段，不能只借pass或首错。

三个新UI工具在现有DevTools图形类别。每次报告与实际库副本位于
`files/graphics-semantic-probes/<PID-steadyNs>/` 唯一目录。生产runtime/provider不可替换，
test process永久认领后游戏/JVM入口要求重启；报告fclose后纯读原文件，不重写修复
截断。只有成功close/readback才产生独立 `GRAPHICS_SCENE_RETURN`；它表示函数完成，
不表示app自然退出，副本也不表示所有映射内存字节hash。

宿主 `scripts/check-graphics-scene-evidence.mjs` 要求原report、独立原UI或hilog RETURN、
实际loaded副本、最终HAP及动作前expected JSON（pid/runId/probe/sourceHead/HAP与库SHA；
MGL另需独立driver deviceName/vendorId/shaderFloat64=false）。它核HAP的真实sourceRevision、
库原字节、同映像GL/EGL解析、固定场景分母与原始查询/像素、退休及外部返回，不从报告
自行补期望或借旧目录PASS。三个轻量Node回归接入现有graphics preflight；昂贵GPU/CTS
和物理设备场景通过显式资格命令执行。原JSONL固定样本按SHA保原字节、`-text`检出。
