package com.amcl.launcher;
import java.io.File;

/** 读取真实DH绑定和独立负控归档；只验证目录策略，不在宿主执行ARM库。 */
public final class SqliteBootstrapContractTest {
    private static int checks;
    private static String files, temp;
    private static void check(boolean ok, String why) { checks++; if (!ok) throw new AssertionError(why); }
    private static void reset() {
        for (String key : new String[]{"dh_sqlite.tmpdir", "dh_sqlite.lib.path", "dh_sqlite.lib.name"}) System.clearProperty(key);
    }
    private static String run(String... jars) {
        reset(); return SqliteNativeTempBootstrap.configure(jars, null, files, "fabric", temp);
    }
    public static void main(String[] args) throws Exception {
        File out = new File(args[0]); String dh = args[1]; files = new File(out, "files").getCanonicalPath(); temp = new File(files, "tmp").getCanonicalPath();
        System.setProperty("amcl.platform.ohos", "true");
        check(run(dh).startsWith("status=configured"), "original complete binding");
        check(temp.equals(System.getProperty("dh_sqlite.tmpdir")), "actual private root");
        check(run(dh, dh).startsWith("status=configured"), "canonical duplicate path");
        check(run(dh, new File(out, "copy.jar").getPath()).equals("status=unknown-or-mixed-binding"), "second resource/class source");
        for (String name : new String[]{"changed-class", "missing-class", "extra-class", "changed-native", "missing-native", "mr"}) {
            check(run(new File(out, name + ".jar").getPath()).equals("status=unknown-or-mixed-binding"), name);
            check(System.getProperty("dh_sqlite.tmpdir") == null, name + " no mutation");
        }
        for (String name : new String[]{"shadow.jar", "resource-dir", "class-dir"})
            check(run(dh, new File(out, name).getPath()).equals("status=unknown-or-mixed-binding"), name);
        check(run(new File(out, "nested.jar").getPath()).startsWith("status=configured"), "active fabric dependency");
        reset();
        check(SqliteNativeTempBootstrap.configure(new String[]{new File(out, "nested.jar").getPath()}, null, files, "none", temp).equals("status=no-known-binding"), "inactive metadata");
        for (String key : new String[]{"dh_sqlite.tmpdir", "dh_sqlite.lib.path", "dh_sqlite.lib.name"}) for (String value : new String[]{"explicit", ""}) {
            reset(); System.setProperty(key, value);
            check(SqliteNativeTempBootstrap.configure(new String[]{"missing.jar"}, null, files, "fabric", temp).equals("status=user-path-preserved"), "preserve " + key);
            check(value.equals(System.getProperty(key)), "unchanged explicit value");
        }
        reset(); System.setProperty("org.sqlite.tmpdir", "unrelated-standard-binding");
        check(SqliteNativeTempBootstrap.configure(new String[]{dh}, null, files, "fabric", temp).startsWith("status=configured"), "independent shaded property");
        check("unrelated-standard-binding".equals(System.getProperty("org.sqlite.tmpdir")), "standard property unchanged");
        for (String invalid : new String[]{"", "relative/tmp", new File(out, "public").getPath(), new File(files, "missing").getPath()}) {
            reset(); check(SqliteNativeTempBootstrap.configure(new String[]{dh}, null, files, "fabric", invalid).equals("status=private-temp-unavailable"), "invalid native root");
        }
        reset(); check(SqliteNativeTempBootstrap.configure(new String[]{dh}, null, files, "ambiguous", temp).equals("status=deferred-loader-unsupported"), "loader ambiguity");
        reset(); System.clearProperty("amcl.platform.ohos"); check(SqliteNativeTempBootstrap.configure(new String[]{dh}, null, files, "fabric", temp).equals("status=not-ohos"), "desktop unchanged");
        System.out.println("PASS SQLite bootstrap checks=" + checks + "; no native code executed");
    }
}
