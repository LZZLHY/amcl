import java.nio.file.Path;
import java.nio.file.Paths;
import net.fabricmc.tinyremapper.TinyRemapper;

/**
 * 使用固定版本的真实 TinyRemapper 读取完整 classpath，复现 Fabric 首次反混淆的扫描。
 * 只分析归档类字节，不定义游戏类、不加载 LWJGL native。扫描失败返回 2 并保留完整原因链。
 * TinyRemapper/ASM 由测试参数提供且先核对固定摘要，不编入应用或替换整合包依赖。
 */
public final class RemapperClasspathProbe {
    /** 每个参数是一个要扫描的归档路径；全部 readClassPath 完成后才报告 SCAN_OK。 */
    public static void main(String[] args) {
        if (args.length == 0) throw new IllegalArgumentException("需要至少一个 JAR");
        TinyRemapper remapper = TinyRemapper.newRemapper().build();
        int result = 0;
        try {
            Path[] paths = new Path[args.length];
            for (int i = 0; i < args.length; i++) paths[i] = Paths.get(args[i]);
            remapper.readClassPath(paths);
            System.out.println("SCAN_OK host=" + Runtime.version().feature() + " jars=" + paths.length);
        } catch (Throwable error) {
            result = 2;
            error.printStackTrace(System.out);
        } finally {
            remapper.finish();
        }
        System.exit(result);
    }
}
