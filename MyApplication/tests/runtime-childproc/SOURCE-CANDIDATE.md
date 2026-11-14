# 0024：完整 childproc 源与默认选择资格

权威输入在 reference/source.json，每个文件绑定 OpenJDK 固定 commit、原路径与 SHA256；
保持上游许可证正文。prepare_source_candidate.py 对受影响文件先应用现役完整前置
series，再生成 0024。没有复制另一份 PATH 算法，也没有给 JDK 增加进程代理层。

实际 API26 平板的 fd-cleanup 矩阵已明确区分平台能力：close_range 和 AUTO 都被
SIGSYS 终止，未产生 child POD；原始 waitStatus 为159。直接 raw getdents64 正常退出，
10个已知 FD（含32767与最后创建的64）全部关闭，stdio/FD3保持，父侧10个FD仍开放。
该路径读取2批、24条记录、执行19次close。此记录不能当作其他设备/API20或性能基准。
因此0024生产调用固定 DENTS_ONLY，既不试探 close_range，也不捕获 SIGSYS 或修改系统策略。

四代 childproc.c 仅增加 OHOS 分支：FD清理失败沿原 fail pipe 返回原 errno；不执行
sysconf/盲目RLIMIT循环。继承环境转为现有 environ 指针，只读而不赋值；绝对路径与
父侧预制 parentPathv 继续调用原有 execve/ENOEXEC shell fallback。原 PATH 遍历、
EACCES sticky errno、argv临时展开与恢复都保留。非OHOS分支沿用上游。

现代17/21/25仅在 launchMechanism 未显式设置时查询新增本地 JNI 入口。
__OHOS__构建且真实 uname.sysname 为 HarmonyOS、OpenHarmony 或 OHOS 才默认FORK；
读取失败、普通Linux或非OHOS构建保持原平台默认。查询不读取可覆写的os.name或amcl属性，
不因exec EACCES自动换路。显式FORK/POSIX_SPAWN/VFORK及非法选择错误保持原行为。
JDK8的Java默认VFORK保持，不能从该名称推定商业libc实现真的共享父VM地址空间。

宿主验证分为三层：

- 四代原源对照真实走到execvp；候选每代32项执行原源函数的PATH、环境、脚本回退与errno
  语义，通过ASan/UBSan。替身只位于最后的exec边界，不替换被测算法。
- 每代7项完整childProcess真实fork/exec/wait，核UTF-8 argv/env、cwd、正常退出7/255、
  无shebang脚本、缺程序、拒绝执行、坏cwd与FD清理失败。非CLOEXEC的高FD由child清理，
  父FD及环境保持；成功exec的255与failpipe错误明确区分。
- 17/21/25完整候选ProcessImpl.java各编译并运行10个新VM。JVMTI仅在ClassPrepare注册
  新增JNI入口，使用同一C谓词并替换uname边界；覆盖三种OHOS名、相反os.name、uname失败、
  非OHOS构建、显式机制和非法值，保留25的原VFORK弃用提示。CheckJNI启用。
  这证明真实Java选择与JNI边界调用，并不等于目标内核身份或完整JDK产物已通过。

标准入口是 docker/project.py test --suite runtime-childproc，使用已登记工具链镜像的
boot JVM、固定amcl/qa服务，不覆盖QA默认镜像配置。原runtime-process继续独立FD/NCP矩阵。
SDK的四代优化对象另查未定义依赖与LLVM IR：清理只调用openat/close/getdents64，
没有close_range，也没有堆/DIR*/execvp/sysconf依赖。DEBUG上游故障模拟不属于本轮release资格。

后续必须用四代完整新JDK构建与真实默认extended profile核对实际JNI导出、默认选择、
ProcessBuilder、VM正常关闭，不能拿旧FORK参数对照替代新默认产物的资格。
