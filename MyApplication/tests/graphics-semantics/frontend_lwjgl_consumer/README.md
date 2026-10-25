# 真实 Linux JVM / LWJGL frontend 消费者

此测试直接运行现役 `lwjgl.jar` 与 `lwjgl-opengl.jar` 中的 `GL.createCapabilities()`，
匹配官方 Linux/x64 `lwjgl`/`lwjgl-opengl` native 模块。官方 `GL.create(FunctionProvider)`
接缝只交付同线程 production owner 的真实 GL 地址；不复制 capabilities 算法、
driver、版本数值或 Java 字段。`org.lwjgl.opengl.explicitInit=true` 阻止先加载系统
OpenGL provider，JNI 每次核验当前 owner 线程/context 与函数真实 DSO。

输入显式指定 stock Linux `java`、现役 JAR、匹配 Linux native 目录、官方 JNI 头、
完整 production `libamcl_graphics_runtime.so`/`libamcl_gl_host.so` 所在目录及编译过的
测试 classes。Java类应从这里的源码用 stock javac 编译，例如 `javac --release 8`
并把 classes 输出到仓外。`run-host.py` 会编译实际 JNI 源，四个版本各用干净进程
和配置创建合法 WINDOW|PBUFFER config、专用 auxiliary/parking surface 与context，
并在退出前清 LWJGL TLS、沿原 owner 退休全部EGL资源及许可。

```text
python run-host.py --java <stock-linux-java> --classes <outside-classes>
  --core-jar <current-lwjgl.jar> --opengl-jar <current-lwjgl-opengl.jar>
  --native-dir <official-linux-x64-libraries> --jni-include <official-jni-headers>
  --runtime-dir <actual-runtime-and-glhost-directory> --driver-dir <linux-GLES-dependencies>
  --expected-mg-commit <exact-source-SHA1> --output <new-outside-directory> --no-core-tokens
```

`--no-core-tokens` 用于已经移除合成标识的候选，要求 raw/indexed/count一致且没有
`OpenGLxx`、冷 cache查询保留真实旧INVALID_ENUM，以及低grant flags不能超出版本。
真正flags仍由现役Java算法和required functions决定。每次解析都有seq/tid/current/
地址/映像记录，缺入口如实返回0；JVM、LWJGL native、JNI/runtime/GL host实际maps
路径及所有输入/日志SHA进入收据。进程、报告、唯一末尾退休标记与来源同时成立才接受。

4.0请求另执行已知FP64和polygon直接反例；它们的 `FAIL` 与 `CONSUMER_PASS` 是两个
独立结论。FP64动态uint转换在真实MG编译器拒绝，线框内点在FILL红色校准后应黑；
颜色期望不来自当前getter值。能力flags、入口非零或消费者可运行不代表这些语义合规。

宿主使用实际X11 EGL环境及已审 MG；没有验证 OHOS NativeWindow/broker、SDK、游戏、
物理 GPU或完整CTS。现役JAR的部分结构类与官方JAR可不同，本测试只为实际使用的
消费者/通用JNI路径留证，不能由匹配native版本推定所有结构ABI正确。
