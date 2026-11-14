# JavaSound 的宿主回调边界

商业平板的原播放试验已加载 libjsound 并成功 GenerateRenderer/Start，随后在
OS_AudioWriteCB 的系统 CFI 检查处 SIGABRT。实际包 DT_INIT=0x1bf20，目标 init 地址
0x5bc351cf20；得到映像基址0x5bc3501000，再加真实 render_data 符号0x1b290，
精确等于检测器报告0x5bc351c290。SDK的高级回调返回/参数类型也与原函数一致。
这证明失败地址是预期自加载函数，不能仅因栈中某个系统检查函数而认定其模块有缺陷，
也不能只凭CFI栈就宣布发生UAF或内存踩写。

CFI的跨DSO设计依赖平台已知映像。修复使用正常HAP加载的libentry作为系统回调归属，
不写CFI shadow，不关闭检查，不通过一个泛型跳板再调用自加载函数。
官方设计依据见 [Clang CFI shared library support](https://clang.llvm.org/docs/ControlFlowIntegrityDesign.html#shared-library-support)。
本文只借其解释边界；商业系统具体实现仍以原始检测器和目标对照为准。

共享事实源是 entry/src/main/cpp/javasound/ohos_daudio_callbacks.h。它保留原POD和
六个回调算法，宿主C文件与独立CLI都从该头编译。0028 getter为 amcl_javasound_callbacks_v2，
返回 AmclDAudioCallbackAbiV2，包含独立ABI/layout版本、表/line/context/capture-ring/timeline
大小、line/context/timeline对齐和六个SDK精确类型指针。布局变化必须提升对应版本；
未发布的0025原实验由不可变源/产物重现，不维护两套可选生产回调。

回调只操作数据、原子字段和原PCM环；没有JNI、分配、日志、平台控制或外来函数指针。
PCM复制次数与帧语义保持。DAUDIO控制侧负责版本/尺寸/对齐、getter/表/六函数的同映像
核验，以及原libjsound代码租约和宿主hostLease。Release成功且在途回调退出后释放；
失败保留最小上下文和必要代码寿命，不能制造迟到回调悬空。

本目录回归正常dlopen由实际HAP C源生成的DSO，验证表与函数的归属、ABI负例、完整帧、
环回绕、Capture、事件/首错、撤销owner并free line后的迟到回调。错误void返回签名
必须被SDK类型拒绝。宿主GCC只移除availability注解，不改API声明；ASan/UBSan/LSan
只授予宿主协议资格，实际系统CFI仍需新HAP和新JDK一起播放/录音验证。

执行入口为 run-host.py，参数 --sdk-headers 指向实际SDK声明快照，--out 指向仓外新目录。
SDK AArch64另以完整sysroot进行严格C11编译；0028正常优化对象仅使用数据复制/清零外部函数；
不把带sanitizer的宿主对象当作实时回调性能证据。
