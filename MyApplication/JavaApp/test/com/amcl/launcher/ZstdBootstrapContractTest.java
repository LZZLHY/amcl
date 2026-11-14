package com.amcl.launcher;
import java.io.File;

/** 生产resolver读取原发布者类和畸形归档；native占位文件仅用于路径选择，绝不加载。 */
public final class ZstdBootstrapContractTest {
    private static int checks;
    private static String metadataLoader = "fabric";
    private static void check(boolean value, String reason) { checks++; if (!value) throw new AssertionError(reason); }
    private static ZstdNativeBootstrap.Result run(String nativeDir, String gameDir, String... jars) {
        System.clearProperty("ZstdNativePath"); System.setProperty("amcl.zstd.native.path", nativeDir);
        return ZstdNativeBootstrap.configure(jars, gameDir, metadataLoader);
    }
    public static void main(String[] args) throws Exception {
        String input = args[0], standard = args[1], dh = args[2];
        String nativeDir = new File(input, "native").getCanonicalPath();
        ZstdNativeBootstrap.Result result = run(nativeDir, null, standard);
        check(result.status.equals("configured") && result.profile.equals("luben-1.5.7-12"), "original standard classes");
        check(System.getProperty("ZstdNativePath").endsWith("libamcl_zstdjni_std.so"), "standard provider");
        result = run(nativeDir, null, dh);
        check(result.status.equals("configured") && result.profile.equals("dh-3.3.3-zstd-1.5.7-12"), "original DH classes");
        check(System.getProperty("ZstdNativePath").endsWith("libamcl_zstdjni_dh.so"), "DH independent provider");
        check(run(nativeDir, new File(input, "game").getPath()).status.equals("configured"), "selected instance only");
        check(run(nativeDir, null, standard, standard).status.equals("configured"), "same canonical path deduplicated");
        check(run(nativeDir, null, standard, dh).status.equals("multiple-bindings"), "shared property cannot select mixed namespaces");
        check(run(nativeDir, null, standard, new File(input, "copy.jar").getPath()).status.equals("multiple-bindings"), "second source not silently merged");
        check(run(nativeDir, null, new File(input, "without-extension").getPath()).status.equals("configured"), "explicit classpath accepts non-jar suffix");
        check(run(nativeDir, null, standard, new File(input, "class-directory").getPath()).status.equals("unknown-or-mixed-binding"), "directory shadow deferred");
        for (String name : new String[]{"changed", "missing", "extra", "mr", "unknown-shading"}) {
            result = run(nativeDir, null, new File(input, name + ".jar").getPath());
            check(result.status.equals("unknown-or-mixed-binding") && System.getProperty("ZstdNativePath") == null, name);
        }
        for (String name : new String[]{"forge", "fabric", "fabric-no-jars", "forge-two-level", "forge-jars-path"}) {
            metadataLoader = name.startsWith("forge") ? "forge" : "fabric";
            check(run(nativeDir, null, new File(input, name + ".jar").getPath()).status.equals("configured"), name);
        }
        metadataLoader = "fabric";
        check(run(nativeDir, null, new File(input, "dual-loader.jar").getPath()).status.equals("configured"), "inactive Forge binding ignored on Fabric");
        metadataLoader = "forge";
        check(run(nativeDir, null, new File(input, "dual-loader.jar").getPath()).status.equals("unknown-or-mixed-binding"), "active Forge binding actually inspected");
        for (String loader : new String[]{"fabric", "forge"}) {
            metadataLoader = loader;
            check(run(nativeDir, null, new File(input, "dual-same.jar").getPath()).status.equals("configured"), "one entry in two loader declarations is one active dependency");
        }
        check(run(nativeDir, null, new File(input, "undeclared.jar").getPath()).status.equals("no-known-binding"), "undeclared nested jars ignored");
        for (String name : new String[]{"duplicate", "metadata-duplicate", "metadata-traversal", "fabric-absolute", "fabric-shape", "too-deep", "truncated"}) {
            metadataLoader = name.startsWith("fabric") ? "fabric" : "forge";
            result = run(nativeDir, null, new File(input, name + ".jar").getPath());
            check(result.status.startsWith("deferred-") && System.getProperty("ZstdNativePath") == null, name);
        }
        check(run(new File(input, "absent").getPath(), null, standard).status.equals("native-artifacts-unavailable"), "missing native path");
        System.setProperty("ZstdNativePath", "user-value");
        check(ZstdNativeBootstrap.configure(new String[]{"missing.jar"}, null, "fabric").status.equals("user-path-preserved"), "explicit user path");
        check("user-value".equals(System.getProperty("ZstdNativePath")), "user value unchanged");
        System.setProperty("ZstdNativePath", "");
        check(ZstdNativeBootstrap.configure(new String[]{"missing.jar"}, null, "fabric").status.equals("user-path-preserved"), "explicit empty user path");
        System.clearProperty("ZstdNativePath");
        check(ZstdNativeBootstrap.configure(new String[]{standard}, null, "ambiguous").status.equals("deferred-loader-unsupported"), "ambiguous loader not guessed");
        if (args.length > 3) {
            for (String loader : new String[]{"fabric", "forge"}) {
                metadataLoader = loader;
                check(run(nativeDir, null, standard, args[3]).status.equals("configured"), "actual AsyncParticles dual metadata " + loader);
            }
        }
        System.out.println("PASS zstd bootstrap checks=" + checks + "; original classes never executed");
    }
}
