package com.amcl.launcher;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.jar.JarFile;
import java.util.zip.*;

/**
 * 原生绑定只读身份检查器。由zstd、SQLite等策略共享有界ZIP和活动加载器元数据遍历，
 * 不加载Java类、不改变ClassLoader、不解包或执行native；任何歧义由调用策略保持原行为。
 * 每次Scan独占预算，不能跨实例缓存来源集合，也不能以本扫描替代运行时变换后的ABI证明。
 */
final class NativeBindingInspector {
    private static final int CLASS_LIMIT = 1024 * 1024, NESTED_LIMIT = 16 * 1024 * 1024;
    private static final int DIRECTORY_LIMIT = 8 * 1024 * 1024, METADATA_LIMIT = 256 * 1024;
    private NativeBindingInspector() { }
    /** 一个原生绑定的完整类树及必需资源，内容来自构建期审核的身份表。 */
    static final class Profile {
        String id, prefix, filename;
        final Map<String, String> classes = new HashMap<String, String>();
        final Map<String, String> resources = new HashMap<String, String>();
    }
    /** 只枚举实际classpath和实例mods；目录遮蔽、缺失、数量过大均不放宽。 */
    static Collection<File> archives(String[] classpath, String gameDir, Scan scan) throws IOException {
        LinkedHashMap<String, File> paths = new LinkedHashMap<String, File>();
        if (classpath != null) {
            if (classpath.length > 2048) throw new IOException("classpath-limit");
            for (String value : classpath) if (value != null && value.length() != 0) {
                File file = new File(value);
                if (file.isDirectory()) {
                    // 开发目录中的同名类可遮蔽 JAR；尚无冻结目录身份时保留原加载方式。
                    for (String prefix : scan.prefixes) if (new File(file, prefix).exists()) scan.unknown = true;
                    for (Profile profile : scan.profiles) for (String resource : profile.resources.keySet())
                        if (new File(file, resource).exists()) scan.unknown = true;
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
        return paths.values();
    }
    private static void add(Map<String, File> result, File file) throws IOException {
        if (!file.isFile()) throw new IOException("jar-unavailable");
        result.put(file.getCanonicalPath(), file);
    }
    /** 单次选择拥有独立预算与来源列表，扫描失败不会提交任何上游属性。 */
    static final class Scan {
        final List<Profile> profiles; final List<Profile> matches = new ArrayList<Profile>();
        final String metadataLoader; final Set<String> prefixes = new LinkedHashSet<String>();
        final String unknownNativeProperty; final Map<String, Integer> resourceSources = new HashMap<String, Integer>();
        boolean unknown; long nestedBytes, classBytes, directoryBytes, resourceBytes;
        Scan(List<Profile> profiles, String metadataLoader, String unknownNativeProperty) {
            this.profiles = profiles; this.metadataLoader = metadataLoader; this.unknownNativeProperty = unknownNativeProperty;
            for (Profile profile : profiles) prefixes.add(profile.prefix);
        }
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
            List<String> paths = new ArrayList<String>();
            if (metadataLoader.equals("forge") && zip.names().contains("META-INF/jarjar/metadata.json"))
                paths.addAll(JarJarMetadata.paths(new String(zip.required("META-INF/jarjar/metadata.json", METADATA_LIMIT), StandardCharsets.UTF_8)));
            if (metadataLoader.equals("fabric") && zip.names().contains("fabric.mod.json"))
                paths.addAll(JarJarMetadata.fabricPaths(new String(zip.required("fabric.mod.json", METADATA_LIMIT), StandardCharsets.UTF_8)));
            if (new HashSet<String>(paths).size() != paths.size()) throw new IOException("nested-duplicate-declaration");
            if (!paths.isEmpty() && depth >= 2) throw new IOException("nested-depth-limit");
            for (String entry : paths) {
                byte[] bytes = zip.required(entry, NESTED_LIMIT); nestedBytes += bytes.length;
                if (nestedBytes > 128L * 1024 * 1024) throw new IOException("nested-budget");
                // 只索引嵌套中央目录；native/model 资源正文不会被解压。
                visit(new MemoryZip(bytes), entry, sha(bytes), depth + 1);
            }
        }
        /** 完整类集合逐字节匹配；混合包和同一绑定的第二个来源均不做任意选择。 */
        void classes(ZipView zip, String nestedEntry, String nestedSha) throws IOException {
            // 类可来自一个JAR，而资源可能被另一个JAR遮蔽；同路径第二来源也拒绝自动选择。
            Set<String> resourceNames = new HashSet<String>();
            for (Profile profile : profiles) resourceNames.addAll(profile.resources.keySet());
            for (String name : resourceNames) if (zip.names().contains(name)) {
                int count = resourceSources.containsKey(name) ? resourceSources.get(name) + 1 : 1;
                resourceSources.put(name, count); if (count > 1) unknown = true;
            }
            for (String prefix : prefixes) {
                Map<String, String> classes = new HashMap<String, String>();
                for (String name : zip.names()) {
                    if (name.startsWith("META-INF/versions/") && name.contains("/" + prefix)) { unknown = true; continue; }
                    if (!name.startsWith(prefix) || !name.endsWith(".class")) continue;
                    byte[] value = zip.required(name, CLASS_LIMIT); classBytes += value.length;
                    if (classBytes > 32L * 1024 * 1024) throw new IOException("class-budget");
                    classes.put(name, sha(value));
                }
                if (classes.isEmpty()) continue;
                Profile match = null;
                for (Profile profile : profiles) {
                    if (!prefix.equals(profile.prefix) || !classes.equals(profile.classes)) continue;
                    if (match != null) { unknown = true; return; } match = profile;
                }
                if (match == null) unknown = true;
                else {
                    // 只有已核验类树才读取其规定资源；本地native正文只计算摘要，不解包、不执行。
                    boolean resourcesMatch = true;
                    for (Map.Entry<String, String> resource : match.resources.entrySet()) {
                        if (!zip.names().contains(resource.getKey())) { resourcesMatch = false; continue; }
                        byte[] value = zip.required(resource.getKey(), 4 * 1024 * 1024); resourceBytes += value.length;
                        if (resourceBytes > 32L * 1024 * 1024) throw new IOException("resource-budget");
                        if (!sha(value).equals(resource.getValue())) resourcesMatch = false;
                    }
                    if (resourcesMatch) matches.add(match); else unknown = true;
                }
            }
            // 常见的其它shading仍保留Native类名；它们共用上游全局属性，发现后不得影响它们。
            // 不将这项有界检测宣称为任意重命名/任意premain的全生态分析器。
            for (String name : zip.names()) {
                if (unknownNativeProperty == null || !name.endsWith("/Native.class")) continue;
                boolean knownPrefix = false;
                for (String prefix : prefixes) if (name.startsWith(prefix)) knownPrefix = true;
                if (knownPrefix) continue;
                byte[] bytes = zip.required(name, CLASS_LIMIT); classBytes += bytes.length;
                if (classBytes > 32L * 1024 * 1024) throw new IOException("class-budget");
                if (new String(bytes, StandardCharsets.ISO_8859_1).contains(unknownNativeProperty)) unknown = true;
            }
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
    /** 小型嵌套 JAR 的内存索引；只解压明确选中的 已知 Java class 与声明资源，不遍历/展开其余二进制。 */
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
    static byte[] read(InputStream input, int max) throws IOException {
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
