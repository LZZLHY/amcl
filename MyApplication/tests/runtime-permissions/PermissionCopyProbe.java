/* PERM-01 Java8兼容测量：在调用方给定根下独占建立小型ZIP，观察普通文件与
 * createTempFile完整mode/对象/存储身份，再执行真实zipfs写回。同时直接调用Java
 * POSIX权限API，与VM加载前宿主libc矩阵对照，检出重定位层吞错；不会修改既有用户文件。
 */
import java.io.OutputStream;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileStore;
import java.nio.file.FileSystem;
import java.nio.file.FileSystems;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermission;
import java.util.Collections;
import java.util.EnumSet;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

public final class PermissionCopyProbe {
    private static FileChannel report;
    /** 独占报告文件与编译器stdout分离；完整UTF-8写入并同步，不能从交错日志拼造JSON。 */
    private static void record(String text) throws Exception {
        if (report == null) throw new IllegalStateException("permission report is not open");
        ByteBuffer bytes = ByteBuffer.wrap((text + "\n").getBytes(StandardCharsets.UTF_8));
        while (bytes.hasRemaining()) if (report.write(bytes) <= 0) throw new java.io.IOException("permission report write stalled");
        report.force(true);
        System.out.println(text);
    }
    /** 九位POSIX权限顺序固定，与真实unix:mode逐位对应；特殊位只观察，不私自丢失。 */
    private static Set<PosixFilePermission> permissions(int mode) {
        PosixFilePermission[] bits = { PosixFilePermission.OTHERS_EXECUTE, PosixFilePermission.OTHERS_WRITE,
            PosixFilePermission.OTHERS_READ, PosixFilePermission.GROUP_EXECUTE, PosixFilePermission.GROUP_WRITE,
            PosixFilePermission.GROUP_READ, PosixFilePermission.OWNER_EXECUTE, PosixFilePermission.OWNER_WRITE,
            PosixFilePermission.OWNER_READ };
        Set<PosixFilePermission> result = EnumSet.noneOf(PosixFilePermission.class);
        for (int bit = 0; bit < bits.length; bit++) if ((mode & (1 << bit)) != 0) result.add(bits[bit]);
        return result;
    }
    /** 每项独占一个样本。成功必须真实改变完整mode，拒绝必须保留原对象和mode；
     * 所需返回语义还由宿主与本次native报告交叉核对，不以文件系统名称猜豁免。
     */
    private static void directPermissions(Path root) throws Exception {
        String[] names = {"same", "toggle-owner-exec", "owner-only", "remove-owner-write", "zero"};
        for (int selected = 0; selected < names.length; selected++) {
            Path file = root.resolve("java-mode-" + names[selected]);
            Files.write(file, new byte[] {65}, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
            Map<String, Object> before = Files.readAttributes(file, "unix:mode,dev,ino", LinkOption.NOFOLLOW_LINKS);
            int initial = ((Integer)before.get("mode")) & 07777;
            if ((initial & 07000) != 0) throw new AssertionError("unexpected special bits on owned fixture");
            int requested = selected == 0 ? initial : selected == 1 ? initial ^ 0100 :
                selected == 2 ? 0600 : selected == 3 ? initial & ~0200 : 0;
            String error = "";
            try { Files.setPosixFilePermissions(file, permissions(requested)); }
            catch (java.io.IOException rejected) { error = rejected.toString(); }
            Map<String, Object> after = Files.readAttributes(file, "unix:mode,dev,ino", LinkOption.NOFOLLOW_LINKS);
            int actual = ((Integer)after.get("mode")) & 07777;
            boolean same = before.get("dev").equals(after.get("dev")) && before.get("ino").equals(after.get("ino"));
            boolean success = error.isEmpty();
            record("PERM_JAVA_DIRECT {\"case\":" + quote(names[selected]) +
                ",\"root\":" + quote(root.getParent().toString()) +
                ",\"beforeOctal\":" + quote(Integer.toOctalString(initial)) +
                ",\"requestedOctal\":" + quote(Integer.toOctalString(requested)) +
                ",\"afterOctal\":" + quote(Integer.toOctalString(actual)) +
                ",\"sameObject\":" + same + ",\"success\":" + success + ",\"error\":" + quote(error) + "}");
            if (!same || actual != (success ? requested : initial))
                throw new AssertionError("permission result disagrees with actual object/mode: " + names[selected]);
        }
    }
    private static String quote(String value) {
        StringBuilder out = new StringBuilder("\"");
        for (char c : value.toCharArray()) {
            if (c == '\\' || c == '"') out.append('\\').append(c);
            else if (c < 32) out.append(String.format("\\u%04x", (int)c));
            else out.append(c);
        }
        return out.append('"').toString();
    }
    /** unix:mode包含特殊位，不能只比较PosixFilePermission的九位便宣称完整无变化。 */
    private static void describe(String role, Path path) throws Exception {
        Map<String, Object> values = Files.readAttributes(path, "unix:mode,dev,ino,uid,gid,nlink", LinkOption.NOFOLLOW_LINKS);
        FileStore store = Files.getFileStore(path);
        record("PERM_JAVA {\"role\":" + quote(role) + ",\"path\":" + quote(path.toString()) +
            ",\"modeOctal\":" + quote(Integer.toOctalString(((Integer)values.get("mode")) & 07777)) +
            ",\"dev\":" + quote(values.get("dev").toString()) + ",\"ino\":" + quote(values.get("ino").toString()) +
            ",\"uid\":" + quote(values.get("uid").toString()) + ",\"gid\":" + quote(values.get("gid").toString()) +
            ",\"fileStoreName\":" + quote(store.name()) + ",\"fileStoreType\":" + quote(store.type()) + "}");
    }
    /** 从已关闭且重新打开的ZIP独立读取完整正文；条目存在本身不能证明更新字节正确。 */
    private static void verifyEntry(ZipFile zip, String name, String expected) throws Exception {
        ZipEntry entry = zip.getEntry(name);
        if (entry == null) throw new AssertionError("ZIP payload entry missing: " + name);
        byte[] bytes = expected.getBytes(StandardCharsets.UTF_8);
        try (InputStream input = zip.getInputStream(entry)) {
            for (byte value : bytes) if (input.read() != (value & 255))
                throw new AssertionError("ZIP payload changed: " + name);
            if (input.read() != -1) throw new AssertionError("ZIP payload has extra bytes: " + name);
        }
    }
    public static void main(String[] args) throws Exception {
        if (args.length != 3 || !Paths.get(args[0]).isAbsolute() || !args[1].matches("[A-Za-z0-9-]{1,48}") ||
                !Paths.get(args[2]).isAbsolute())
            throw new IllegalArgumentException("absolute owned root, fresh nonce and exclusive report path required");
        try (FileChannel output = FileChannel.open(Paths.get(args[2]), StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
            report = output;
            try { execute(args); } finally { report = null; }
        }
    }
    /** 一次调用只测一个已核根；每根样本与报告均独占，失败不覆盖上轮证据。 */
    private static void execute(String[] args) throws Exception {
        Path root = Files.createDirectory(Paths.get(args[0]).resolve(".amcl-zip-perm-" + args[1]));
        directPermissions(root);
        Path jar = root.resolve("original.zip");
        try (OutputStream output = Files.newOutputStream(jar, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
             ZipOutputStream zip = new ZipOutputStream(output)) {
            zip.putNextEntry(new ZipEntry("before.txt")); zip.write("before".getBytes(StandardCharsets.UTF_8)); zip.closeEntry();
        }
        Path temporary = Files.createTempFile(root, "zipfstmp", ".tmp");
        describe("source", jar); describe("same-directory-temp", temporary);
        record("PERM_JAVA {\"posixPermissionSetsEqual\":" +
            Files.getPosixFilePermissions(jar).equals(Files.getPosixFilePermissions(temporary)) + "}");
        boolean succeeded = false;
        try (FileSystem zipfs = FileSystems.newFileSystem(java.net.URI.create("jar:" + jar.toUri()), Collections.<String, Object>emptyMap())) {
            Files.write(zipfs.getPath("/after.txt"), "after".getBytes(StandardCharsets.UTF_8), StandardOpenOption.CREATE_NEW);
            succeeded = true;
        } catch (Exception error) {
            succeeded = false;
            record("PERM_JAVA {\"zipfsError\":" + quote(error.toString()) + "}");
            error.printStackTrace(System.out);
        }
        record("PERM_JAVA {\"zipfsClosed\":" + succeeded + ",\"originalStillExists\":" + Files.exists(jar) +
            ",\"nativePermissionResultKnown\":false}");
        if (succeeded) {
            describe("after-zipfs", jar);
            try (ZipFile zip = new ZipFile(jar.toFile())) {
                verifyEntry(zip, "before.txt", "before");
                verifyEntry(zip, "after.txt", "after");
            }
            record("PERM_JAVA {\"zipPayloadBytesVerified\":true,\"root\":" + quote(args[0]) + "}");
        } else throw new AssertionError("ZIPFS writeback failed; preserved observations are not qualification");
    }
}
