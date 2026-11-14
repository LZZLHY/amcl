package com.amcl.launcher;

import java.io.File;

/** 使用完整官方归档与明确的畸形夹具回放生产 resolver；不会执行任何第三方 class 或加载 SO。 */
public final class SherpaBootstrapContractTest {
    private static int checks;
    private static void check(boolean value, String reason) { checks++; if (!value) throw new AssertionError(reason); }
    private static SherpaNativeBootstrap.Result run(String nativeDir, String gameDir, String... jars) {
        System.clearProperty("sherpa_onnx.native.path"); System.setProperty("amcl.sherpa.native.path", nativeDir);
        return SherpaNativeBootstrap.configure(jars, gameDir);
    }
    public static void main(String[] args) throws Exception {
        String input = args[0], official5 = args[1], official6 = args[2];
        String nativeDir = new File(input, "native").getCanonicalPath();
        String game = new File(input, "game").getCanonicalPath();
        SherpaNativeBootstrap.Result result = run(nativeDir, null, official5);
        check(result.status.equals("configured") && result.profile.equals("verity-5.7.3"), "official5 all 235 direct classes");
        check(nativeDir.equals(System.getProperty("sherpa_onnx.native.path")), "configured native directory");
        result = run(nativeDir, null, official6);
        check(result.status.equals("configured") && result.profile.equals("verity-6.0.0"), "official6 real JarJar core and full class set");
        check(run(nativeDir, game).status.equals("configured"), "only selected instance mods is inspected");
        check(run(nativeDir, null, official5, official5).status.equals("configured"), "canonical duplicate path is one input");
        check(run(nativeDir, null, new File(input, "without-extension").getPath()).status.equals("configured"), "explicit classpath archives need no filename suffix");
        check(run(nativeDir, null, official5, new File(input, "class-directory").getPath()).status.equals("unknown-or-mixed-binding"), "directory classes cannot silently shadow frozen archive binding");
        check(run(nativeDir, null, official5, official6).status.equals("multiple-bindings"), "two known candidates do not pick an arbitrary native");
        for (String name : new String[]{"changed", "missing", "extra", "mixed", "mr"}) {
            result = run(nativeDir, null, new File(input, name + ".jar").getPath());
            check(result.status.equals("unknown-or-mixed-binding") && System.getProperty("sherpa_onnx.native.path") == null, name + " keeps original loader behavior");
        }
        check(run(nativeDir, null, new File(input, "undeclared.jar").getPath()).status.equals("no-known-binding"), "undeclared nested archive not treated as loaded core");
        check(run(nativeDir, null, new File(input, "declared.jar").getPath()).status.equals("configured"), "declared exact nested core is known");
        for (String name : new String[]{"duplicate", "metadata-duplicate", "metadata-traversal", "truncated"}) {
            result = run(nativeDir, null, new File(input, name + ".jar").getPath());
            check(result.status.startsWith("deferred-") && System.getProperty("sherpa_onnx.native.path") == null, name + " is bounded deferred");
        }
        check(run(new File(input, "absent").getPath(), null, official5).status.equals("native-artifacts-unavailable"), "native directory requires both artifacts");
        System.setProperty("sherpa_onnx.native.path", "user-value");
        result = SherpaNativeBootstrap.configure(new String[]{"unreadable.jar"}, game);
        check(result.status.equals("user-path-preserved") && "user-value".equals(System.getProperty("sherpa_onnx.native.path")), "user property never overwritten");
        System.out.println("PASS Sherpa bootstrap checks=" + checks + " runtime=" + System.getProperty("java.version"));
    }
}
