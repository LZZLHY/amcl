import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import com.google.gson.JsonObject;
import com.google.gson.Gson;

/** 真实 Java HAP 读取器的正反例；只写调用方指定的外置构建目录，不读取任何签名材料。 */
public final class ManualPackageInspectionTest {
    private static void entry(ZipOutputStream zip, String name, String body) throws Exception {
        zip.putNextEntry(new ZipEntry(name)); zip.write(body.getBytes(StandardCharsets.UTF_8)); zip.closeEntry();
    }
    private static void run(Path root, String name, boolean diagnostic, boolean oversized, boolean library, boolean expected) throws Exception {
        Path input = root.resolve(name + ".hap"), output = root.resolve(name + ".json");
        try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(input))) {
            String metadata = "{\"app\":{\"bundleName\":\"com.amcl.launcher\",\"versionName\":\"2.0.0-beta.1\",\"versionCode\":20,\"minAPIVersion\":60000020},\"module\":{\"type\":\"entry\",\"deviceTypes\":[\"phone\"]}}";
            entry(zip,"module.json",oversized ? metadata + " ".repeat(65537) : metadata);
            entry(zip,"resources/rawfile/product-profile.json","{\"name\":\"sideload\",\"publishable\":true,\"developerDiagnostics\":" + diagnostic + "}");
            if (library) entry(zip,"libs/arm64-v8a/libentry.so","fixture");
        }
        AmclSigningRunner.main(new String[]{"--inspect-hap",input.toString(),output.toString()});
        JsonObject result = new Gson().fromJson(Files.readString(output),JsonObject.class);
        if (result.get("inspected").getAsBoolean() != expected) throw new AssertionError(name);
        if (expected && (result.get("versionCode").getAsInt() != 20 || !result.get("product").getAsString().equals("sideload"))) throw new AssertionError("metadata binding");
    }
    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("External output directory required");
        Path root=Path.of(args[0]); Files.createDirectories(root);
        run(root,"valid",false,false,true,true);
        run(root,"diagnostic",true,false,true,false);
        run(root,"oversized",false,true,true,false);
        run(root,"missing-native",false,false,false,false);
        System.out.println("ManualPackageInspectionTest: real ZIP metadata, diagnostic, oversize and missing native cases passed");
    }
}
