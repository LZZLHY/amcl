import java.io.File;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.SortedSet;
import java.util.TreeSet;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.zip.ZipFile;

/**
 * 使用标准 JarFile 的指定版本查找规则，比较原始 MR-JAR 与裁剪副本的有效内容。
 * 只读取类和资源字节，不定义类、不加载 LWJGL native、不启动 Minecraft。
 * 指定 feature 25 的元数据读取不等于在真实 JDK 25 中运行或验证 FFM。
 */
public final class JarEffectiveViewProbe {
    /**
     * 列出指定 feature 下可能出现的逻辑资源名；未来层与目录项不参与有效视图。
     * INDEX.LIST 是裁剪后按实际目录更新的索引元数据，允许改变，其余有效文件必须相同。
     */
    private static SortedSet<String> logicalNames(JarFile jar, int feature) {
        SortedSet<String> names = new TreeSet<>();
        jar.stream().filter(entry -> !entry.isDirectory()).forEach(entry -> {
            String name = entry.getName();
            if (name.equals("META-INF/INDEX.LIST")) return;
            String prefix = "META-INF/versions/";
            if (name.startsWith(prefix)) {
                int split = name.indexOf('/', prefix.length());
                if (split < 0) throw new IllegalArgumentException("非法版本项：" + name);
                int layer = Integer.parseInt(name.substring(prefix.length(), split));
                if (layer < 9 || layer > feature) return;
                name = name.substring(split + 1);
                if (name.startsWith("META-INF/")) {
                    throw new IllegalArgumentException("META-INF 服务等资源不能版本化：" + name);
                }
            }
            names.add(name);
        });
        return names;
    }

    /**
     * 输入为原始 JAR、裁剪副本、目标 Java feature；逻辑集合或任一有效文件不同即失败。
     * 核对 JarFile 实际接受的 feature，防止宿主工具默默使用另一版本造成假通过。
     */
    public static void main(String[] args) throws Exception {
        int feature = Integer.parseInt(args[2]);
        Runtime.Version version = Runtime.Version.parse(args[2]);
        try (JarFile source = new JarFile(new File(args[0]), true, ZipFile.OPEN_READ, version);
             JarFile derived = new JarFile(new File(args[1]), true, ZipFile.OPEN_READ, version)) {
            if (source.getVersion().feature() != feature || derived.getVersion().feature() != feature) {
                throw new IllegalStateException("JarFile 未采用请求的版本");
            }
            SortedSet<String> names = logicalNames(source, feature);
            if (!names.equals(logicalNames(derived, feature))) {
                throw new IllegalStateException("逻辑类/资源集合不一致");
            }
            int classes = 0;
            for (String name : names) {
                JarEntry before = source.getJarEntry(name);
                JarEntry after = derived.getJarEntry(name);
                if (before == null || after == null) throw new IllegalStateException("有效项缺失：" + name);
                try (var left = source.getInputStream(before); var right = derived.getInputStream(after)) {
                    if (!Arrays.equals(left.readAllBytes(), right.readAllBytes())) {
                        throw new IllegalStateException("有效内容改变：" + name);
                    }
                }
                if (name.endsWith(".class")) classes++;
            }
            System.out.println("EFFECTIVE_VIEW_EQUAL host=" + Runtime.version().feature()
                + " targetFeature=" + feature + " files=" + names.size() + " classes=" + classes);
            JarEntry backend = derived.getJarEntry("org/lwjgl/system/MemoryBackend.class");
            System.out.println("MemoryBackend.origin=" + (backend == null ? "absent" : backend.getRealName()));
        }
    }
}
