package com.amcl.launcher;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.jar.JarFile;
import java.util.zip.*;

/**
 * 模组首次初始化前的 Sherpa ABI 选择。只读已选 classpath/实例 mods 的 ZIP 中央目录和已知 Java 字节，
 * 不加载类、不解包模型、不改 mod。此入口位于 launcher.prepare，明确不覆盖 premain 已提前消费的情况。
 */
public final class SherpaNativeBootstrap {
    private static final String PREFIX = "com/k2fsa/sherpa/onnx/";
    private static final String RESOURCE = "sherpa-bindings.properties";
    private static final int CLASS_LIMIT = 1024 * 1024, NESTED_LIMIT = 16 * 1024 * 1024;
    private static final int DIRECTORY_LIMIT = 8 * 1024 * 1024, METADATA_LIMIT = 256 * 1024;
    private SherpaNativeBootstrap() { }
    /** 结果不含模型、密钥或文件正文，可由换流后的 launcher 日志复述。 */
    public static final class Result {
        public final String status, profile;
        public final int candidates;
        Result(String status, String profile, int candidates) { this.status = status; this.profile = profile; this.candidates = candidates; }
        public String toString() { return "status=" + status + " profile=" + profile + " candidates=" + candidates; }
    }
    /** 用户已提供官方属性时原样保留；只有唯一完整已核 ABI 和真实 native 文件同时存在才配置。 */
    public static Result configure(String[] classpath, String gameDir) {
        if (System.getProperty("sherpa_onnx.native.path") != null) return new Result("user-path-preserved", "none", 0);
        String path = System.getProperty("amcl.sherpa.native.path", "");
        File directory = new File(path);
        if (path.length() == 0 || !directory.isAbsolute() || !directory.isDirectory()
            || !artifact(directory, "libsherpa-onnx-jni.so") || !artifact(directory, "libonnxruntime.so"))
            return new Result("native-artifacts-unavailable", "none", 0);
        try {
            Scan scan = new Scan(loadProfiles());
            LinkedHashMap<String, File> paths = new LinkedHashMap<String, File>();
            if (classpath != null) {
                if (classpath.length > 2048) throw new IOException("classpath-limit");
                for (String value : classpath) if (value != null && value.length() != 0) {
                    File file = new File(value);
                    if (file.isDirectory()) {
                        // 开发目录中的同名类可遮蔽 JAR；尚无冻结目录身份时保留原加载方式。
                        if (new File(file, PREFIX).exists()) scan.unknown = true;
                    } else add(paths, file);
                }
            }
            if (gameDir != null && gameDir.length() != 0) {
                File mods = new File(gameDir, "mods"); File[] files = mods.listFiles();
                if (mods.exists() && files == null) throw new IOException("mods-unreadable");
                if (files != null) {
                    if (files.length > 2048) throw new IOException("mods-limit");
                    Arrays.sort(files);
                    for (File file : files) if (file.isFile() && file.getName().toLowerCase(Locale.ROOT).endsWith(".jar")) add(paths, file);
                }
            }
            if (paths.size() > 2048) throw new IOException("jar-count-limit");
            for (File file : paths.values()) scan.file(file);
            if (scan.unknown) return new Result("unknown-or-mixed-binding", "none", scan.matches.size());
            if (scan.matches.size() != 1) return new Result(scan.matches.isEmpty() ? "no-known-binding" : "multiple-bindings", "none", scan.matches.size());
            // 保留扫描期间出现的用户配置，不能覆盖迟到但明确的消费者选择。
            synchronized (System.getProperties()) {
                if (System.getProperty("sherpa_onnx.native.path") != null) return new Result("user-path-preserved", "none", scan.matches.size());
                System.setProperty("sherpa_onnx.native.path", directory.getCanonicalPath());
            }
            return new Result("configured", scan.matches.get(0), 1);
        } catch (IOException invalid) { return new Result("deferred-" + safeReason(invalid.getMessage()), "none", 0); }
        catch (RuntimeException invalid) { return new Result("deferred-input-error", "none", 0); }
    }
    private static boolean artifact(File directory, String name) { File file = new File(directory, name); return file.isFile() && file.length() > 0; }
    private static String safeReason(String reason) {
        return reason != null && reason.matches("[a-z0-9-]{1,64}") ? reason : "invalid-archive";
    }
    private static void add(Map<String, File> result, File file) throws IOException {
        if (!file.isFile()) throw new IOException("jar-unavailable");
        String canonical = file.getCanonicalPath(); result.put(canonical, file);
    }
    private static final class Profile {
        String id, kind, entry, nestedSha;
        final Map<String, String> classes = new HashMap<String, String>();
    }
    /** 构建器从权威 JSON 生成 properties；运行时不再维护第二份手写 class 摘要表。 */
    private static List<Profile> loadProfiles() throws IOException {
        InputStream input = SherpaNativeBootstrap.class.getResourceAsStream(RESOURCE);
        if (input == null) throw new IOException("binding-resource-missing");
        Properties props = new Properties();
        try { props.load(new ByteArrayInputStream(read(input, 512 * 1024))); } finally { input.close(); }
        if (!"1".equals(props.getProperty("schema")) || !PREFIX.equals(props.getProperty("classPrefix"))) throw new IOException("binding-resource-schema");
        int count = number(props, "profile.count", 1, 16); List<Profile> result = new ArrayList<Profile>();
        Set<String> ids = new HashSet<String>();
        for (int i = 0; i < count; i++) {
            String key = "profile." + i + "."; Profile profile = new Profile();
            profile.id = props.getProperty(key + "id", ""); profile.kind = props.getProperty(key + "kind", "");
            profile.entry = props.getProperty(key + "entry", ""); profile.nestedSha = props.getProperty(key + "sha256", "");
            if (!profile.id.matches("[a-zA-Z0-9.-]{1,80}") || !ids.add(profile.id)) throw new IOException("binding-resource-profile");
            int classes = number(props, key + "class.count", 235, 235);
            for (int c = 0; c < classes; c++) {
                String name = props.getProperty(key + "class." + c + ".path", "");
                String sha = props.getProperty(key + "class." + c + ".sha256", "");
                if (!name.startsWith(PREFIX) || !name.endsWith(".class") || !sha.matches("[0-9a-f]{64}")
                    || profile.classes.put(name, sha) != null) throw new IOException("binding-resource-class");
            }
            result.add(profile);
        }
        return result;
    }
    private static int number(Properties props, String key, int min, int max) throws IOException {
        try { int value = Integer.parseInt(props.getProperty(key, "")); if (value < min || value > max) throw new NumberFormatException(); return value; }
        catch (NumberFormatException invalid) { throw new IOException("binding-resource-count"); }
    }
    private static final class Scan {
        final List<Profile> profiles; final List<String> matches = new ArrayList<String>();
        boolean unknown; long nestedBytes, classBytes, directoryBytes;
        Scan(List<Profile> profiles) { this.profiles = profiles; }
        void file(File file) throws IOException {
            try (FileZip zip = new FileZip(file)) {
                directoryBytes += zip.directoryBytes;
                if (directoryBytes > 64L * 1024 * 1024) throw new IOException("directory-budget");
                visit(zip, null, null, 0);
            }
        }
        /** 声明的嵌套依赖最多两层；不能漏掉另一层中可能遮蔽已知核心的同名类。 */
        void visit(ZipView zip, String container, String digest, int depth) throws IOException {
            classes(zip, container, digest);
            if (!zip.names().contains("META-INF/jarjar/metadata.json")) return;
            byte[] metadata = zip.required("META-INF/jarjar/metadata.json", METADATA_LIMIT);
            List<String> paths = JarJarMetadata.paths(new String(metadata, StandardCharsets.UTF_8));
            if (!paths.isEmpty() && depth >= 2) throw new IOException("nested-depth-limit");
            for (String entry : paths) {
                byte[] bytes = zip.required(entry, NESTED_LIMIT); nestedBytes += bytes.length;
                if (nestedBytes > 128L * 1024 * 1024) throw new IOException("nested-budget");
                // 只索引嵌套中央目录；native/model 资源正文不会被解压。
                visit(new MemoryZip(bytes), entry, sha(bytes), depth + 1);
            }
        }
        void classes(ZipView zip, String nestedEntry, String nestedSha) throws IOException {
            Map<String, String> classes = new HashMap<String, String>();
            for (String name : zip.names()) {
                if (name.startsWith("META-INF/versions/") && name.contains("/" + PREFIX)) { unknown = true; continue; }
                if (!name.startsWith(PREFIX) || !name.endsWith(".class")) continue;
                byte[] value = zip.required(name, CLASS_LIMIT); classBytes += value.length;
                if (classBytes > 32L * 1024 * 1024) throw new IOException("class-budget");
                classes.put(name, sha(value));
            }
            if (classes.isEmpty()) return;
            String match = null;
            for (Profile profile : profiles) {
                if (!classes.equals(profile.classes)) continue;
                if (nestedEntry != null && (!"jarjar".equals(profile.kind) || !nestedEntry.equals(profile.entry) || !nestedSha.equals(profile.nestedSha))) continue;
                if (match != null) { unknown = true; return; } match = profile.id;
            }
            if (match == null) unknown = true; else matches.add(match);
        }
    }
    private interface ZipView {
        Set<String> names();
        byte[] required(String name, int max) throws IOException;
    }
    /** 在 JarFile 建立索引前检查 EOCD 的数量/目录界限，避免把无界 ZIP 当可信输入。 */
    private static final class Directory {
        final int offset, size, count;
        Directory(byte[] bytes, long total, long base) throws IOException {
            int end = -1;
            for (int i = bytes.length - 22; i >= 0; i--) if (u32(bytes, i) == 0x06054b50L && i + 22 + u16(bytes, i + 20) == bytes.length) { end = i; break; }
            if (end < 0 || u16(bytes, end + 4) != 0 || u16(bytes, end + 6) != 0 || u16(bytes, end + 8) != u16(bytes, end + 10)) throw new IOException("zip-directory-invalid");
            long off = u32(bytes, end + 16), length = u32(bytes, end + 12); int entries = u16(bytes, end + 10);
            if (entries == 65535 || entries > 50000 || length > DIRECTORY_LIMIT || off + length > base + end || off > Integer.MAX_VALUE || total > 512L * 1024 * 1024) throw new IOException("zip-directory-limit");
            offset = (int) off; size = (int) length; count = entries;
        }
    }
    private static final class FileZip implements ZipView, Closeable {
        final JarFile jar; final int directoryBytes; final Set<String> names = new LinkedHashSet<String>();
        FileZip(File file) throws IOException {
            Directory directory;
            try (RandomAccessFile input = new RandomAccessFile(file, "r")) {
                int size = (int) Math.min(input.length(), 65557); byte[] tail = new byte[size]; input.seek(input.length() - size); input.readFully(tail);
                directory = new Directory(tail, input.length(), input.length() - size);
            }
            directoryBytes = directory.size; jar = new JarFile(file, false);
            try {
                Enumeration<? extends ZipEntry> entries = jar.entries(); int count = 0;
                while (entries.hasMoreElements()) {
                    ZipEntry entry = entries.nextElement();
                    if (++count > 50000 || entry.getName().length() > 1024 || !names.add(entry.getName())) throw new IOException("zip-duplicate-or-limit");
                }
                if (count != directory.count) throw new IOException("zip-directory-count");
            } catch (IOException failure) { jar.close(); throw failure; }
            catch (RuntimeException failure) { jar.close(); throw failure; }
        }
        public Set<String> names() { return names; }
        byte[] optional(String name, int max) throws IOException { return names.contains(name) ? required(name, max) : null; }
        public byte[] required(String name, int max) throws IOException {
            ZipEntry entry = jar.getJarEntry(name);
            if (entry == null || entry.isDirectory() || entry.getSize() < 0 || entry.getSize() > max) throw new IOException("zip-entry-limit");
            try (InputStream input = jar.getInputStream(entry)) { return checked(input, entry.getSize(), entry.getCrc(), max); }
        }
        public void close() throws IOException { jar.close(); }
    }
    /** 小型嵌套 JAR 的内存索引；只解压明确选中的 Sherpa Java class，不遍历/展开其余二进制。 */
    private static final class MemoryZip implements ZipView {
        final byte[] bytes; final Map<String, Item> items = new LinkedHashMap<String, Item>();
        MemoryZip(byte[] bytes) throws IOException {
            this.bytes = bytes; Directory d = new Directory(bytes, bytes.length, 0); int at = d.offset;
            for (int i = 0; i < d.count; i++) {
                if (at < 0 || at > bytes.length - 46 || u32(bytes, at) != 0x02014b50L) throw new IOException("nested-directory-invalid");
                int nameLength = u16(bytes, at + 28), extra = u16(bytes, at + 30), comment = u16(bytes, at + 32);
                if (nameLength > 1024 || at + 46L + nameLength + extra + comment > d.offset + d.size) throw new IOException("nested-name-limit");
                String name = new String(bytes, at + 46, nameLength, StandardCharsets.UTF_8);
                Item item = new Item(u16(bytes, at + 10), u32(bytes, at + 16), u32(bytes, at + 20), u32(bytes, at + 24), u32(bytes, at + 42));
                if (items.put(name, item) != null || (u16(bytes, at + 8) & 1) != 0) throw new IOException("nested-duplicate-or-encrypted");
                at += 46 + nameLength + extra + comment;
            }
            if (at != d.offset + d.size) throw new IOException("nested-directory-size");
        }
        public Set<String> names() { return items.keySet(); }
        public byte[] required(String name, int max) throws IOException {
            Item item = items.get(name);
            if (item == null || item.size > max || item.offset > bytes.length - 30 || u32(bytes, (int) item.offset) != 0x04034b50L) throw new IOException("nested-entry-limit");
            int at = (int) item.offset;
            int nameLength = u16(bytes, at + 26); int data = at + 30 + nameLength + u16(bytes, at + 28);
            if (data < at || data + item.compressed > bytes.length || !name.equals(new String(bytes, at + 30, nameLength, StandardCharsets.UTF_8))
                || u16(bytes, at + 8) != item.method || (u16(bytes, at + 6) & 1) != 0) throw new IOException("nested-local-mismatch");
            InputStream raw = new ByteArrayInputStream(bytes, data, (int) item.compressed);
            if (item.method == 0) return checked(raw, item.size, item.crc, max);
            if (item.method != 8) throw new IOException("nested-compression-unsupported");
            Inflater inflater = new Inflater(true);
            try { return checked(new InflaterInputStream(raw, inflater), item.size, item.crc, max); } finally { inflater.end(); }
        }
    }
    private static final class Item {
        final int method; final long crc, compressed, size, offset;
        Item(int method, long crc, long compressed, long size, long offset) { this.method = method; this.crc = crc; this.compressed = compressed; this.size = size; this.offset = offset; }
    }
    private static byte[] checked(InputStream input, long size, long crc, int max) throws IOException {
        byte[] bytes = read(input, max); CRC32 check = new CRC32(); check.update(bytes);
        if (bytes.length != size || check.getValue() != crc) throw new IOException("zip-entry-integrity"); return bytes;
    }
    private static byte[] read(InputStream input, int max) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream(); byte[] block = new byte[8192]; int count;
        while ((count = input.read(block)) != -1) { if (count == 0 || output.size() > max - count) throw new IOException("read-budget"); output.write(block, 0, count); }
        return output.toByteArray();
    }
    private static int u16(byte[] bytes, int at) { return (bytes[at] & 255) | ((bytes[at + 1] & 255) << 8); }
    private static long u32(byte[] bytes, int at) { return (u16(bytes, at) & 65535L) | ((long) u16(bytes, at + 2) << 16); }
    private static String sha(byte[] bytes) {
        try { byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes); StringBuilder text = new StringBuilder(); for (byte value : digest) text.append(String.format(java.util.Locale.ROOT, "%02x", value & 255)); return text.toString(); }
        catch (java.security.NoSuchAlgorithmException unavailable) { throw new IllegalStateException(unavailable); }
    }
}
