# 公共兼容字符的真实消费轨迹

`test-callback-compat-characters.py` 编译完整生产 `CallbackBridge`，通过正式
`jni_registry` getter/方法表和实际 `jni_reregister` 的 `JNI_OnLoad` 绑定当前 Class。
同一真实 bridge/Core owner 保存 ring；GLFW执行正式callback泵，L2执行维护JAR的
`AMCLDisplay` 与原完整 `Keyboard.poll/next`，SDL执行正式字符dispatch正文和完整SDK
`SDL_SendKeyboardText`、TextInput队列、`SDL_PollEvent`。

平台窗口/未采集typed通道是显式宿主边缘，来源owner、注册表、JNI resolver、legacy
ring、字符消费及SDK队列不重写。`foreign.cpp.in` 是真实分离的DLL，它转发primary
真实表，使getter与bind分属不同module，正式resolver必须在注册前拒绝。

目前整份宿主配方使用Windows真实JDK/MSVC；其他平台明确Unsupported，不算消费PASS。
可传完整已应用SDL源与实际已编SDK重用，或者传含锁定commit的源Git仓，正常应用全部
series并重建完整宿主SDK。所有脚本/日志/build输出显式外置，不依赖维护者绝对路径。

本批范围是原公开 `char` 参数的UTF-16单位和有效BMP字符。ASCII、é、中、€分别经过
三个实际出口；不声称代理对重组、游戏相机/业务采用或OHOS设备通过。双写负控只恢复
Java第二次有副作用提交，必须成功编译，再由每种真实出口的独立断言拒绝。

默认参数读取专用 `AMCL_LWJGL2_JDK8`、锁定材料 `AMCL_LWJGL2_INPUTS` 和
`AMCL_SDL_TEST_REPO`。Windows执行示例（仓外路径均由调用者选择）：

```powershell
python -B scripts/test-callback-compat-characters.py `
  --jdk D:/reference/jdk8 --inputs D:/reference/lwjgl2-build-inputs `
  --sdl-source-repo D:/reference/SDL `
  --out D:/run/compat-char --build-out D:/build/compat-char
```

如果已有完整已应用源与实际静态SDK，可分别传 `--sdl-root`、`--sdl-sdk-root`。
测试会冻结C/C++头/正文、Java、维护JAR与fixture到仓外构建树，记录每份实际读取字节
的SHA和具体编译单元；同一轮仍使用唯一真实owner。返回false反控只改变正式字符JNI
函数的返回语句，已排队记录保持相同，Java不得据此再补发plain。最后恢复生产正文并
再次消费确认，避免留下反控DLL被误用为最终正例。
