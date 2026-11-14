# zstd-JNI 的 OHOS 适配

固定上游zstd-jni 1.5.7-12、源码提交b1ab612ca2777d6937f418933b5899132517dab3。
真实压缩、解压、stream、direct buffer和字典代码均来自该源码；两份独立OHOS DSO分别
服务原com.github.luben与DH3.3.3的dhcomgithubluben绑定。模组JAR保持原字节。

两套原Java各37类，重定位归一后接口与方法行为一致，但上游JNI有文件静态jfieldID缓存，
因此不能用同一映像的双前缀别名服务两个类域。每份库拥有不同文件名和SONAME，核心
ZSTD符号隐藏；JNI符号、FindClass包路径、版本脚本前缀一起重定位。Native类自己调用
System.load获得加载器归属，启动器不预加载、不assumeLoaded，也不绕过第二ClassLoader拒绝。

OHOS SDK没有qsort_r；仅字典训练cover.c改调qsort_context适配。适配器用线程私有栈帧
给系统qsort传递比较上下文，支持嵌套恢复，不使用单个全局ctx；比较器不能longjmp或抛异常。
该符号只在本库内部可见。两个目标只依赖OHOS libc.so，没有GLIBC版本或libc.so.6依赖。

## 身份和运行选择

- build-inputs.json固定源归档、目标JNI头和原JNI导出集合；artifacts.json固定实际候选字节、
  编译配方及适配源身份。licenses保留上游BSD声明。
- verified-bindings.json记录完整37类SHA。zstdBindingResource生成启动JAR资源并进入缓存身份。
- ZstdNativeBootstrap只读所选classpath、实例mods及当前加载器声明的嵌套JAR；双加载器
  归档只消费当前Fabric或Forge侧声明，ZIP项使用安全相对路径，不限定打包器默认目录。原生/模型
  正文不展开、不加载游戏类。只匹配唯一完整已核集合才设置官方ZstdNativePath。
- 用户已有值（含空值）、未知、混合、第二来源、MR替换、预算超限或损坏归档保持原方式并
  记录原因。全局属性不能同时表达std和DH两个选择，因此混合时不自动覆盖。
- amcl.zstd.native.path由当前实际HAP路径冻结；源→SDK暂存→strip→HAP走现有provider
  字节链，导出/依赖另由check-zstd-artifacts核验。跨ClassLoader和任意新shading不获自动资格。

148个导出是上游的精确导出面，不是全部Java native声明都已实现：上游两套绑定均缺
searchLengthMin、searchLengthMax、包可见generateSequences对应JNI入口，另保留四个旧
FastDict导出。本适配保留这个来源边界，不补假实现，不宣称这些入口可用；完整逐项审计
见本轮abi-audit/java-abi.json。新增API或新版本需要独立实现与测试。

## 重建和验收

使用正式SDK、显式仓外输入输出；源归档来自固定提交URL，官方Java原件另核发布者摘要。

```powershell
python -B scripts/build-zstd-jni-ohos.py --archive <固定源码归档> --sdk <OpenHarmony/native> --output <全新仓外输出> --jobs 4
node scripts/check-zstd-artifacts.mjs --readelf <SDK llvm-readelf>
python -B scripts/test-zstd-native-host.py --target-build <上一步输出> --standard-jar <原Maven JAR> --dh-jar <原DH JAR> --javac <宿主javac> --output <全新宿主输出>
python -B scripts/test-zstd-bootstrap.py --output <全新夹具输出> --standard <原Maven JAR> --dh <原DH JAR> --java <宿主java> --javac <宿主javac>
```

宿主测试用同一C输入及原Java执行数组/stream/direct/buffer/dictionary、真实帧进度返回、
并发往返、std/DH交替及第二ClassLoader拒绝。qsort另以ASan/UBSan验证八线程嵌套调用。
宿主通过、OHOS制品通过、真实JVM调用、完整Aged世界/保存/退出/冷重载分开记录。
运行证据写工作区外置任务目录，不由本锁文件声明正式发行或跨设备资格。
