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
        run(root,name,diagnostic,oversized,library,expected,"2.0.0-beta.1","");
    }
    /** 各负控只改变输入JSON或ZIP边界，实际读取和声明核验仍调用正式runner。 */
    private static JsonObject run(Path root, String name, boolean diagnostic, boolean oversized, boolean library,
                                  boolean expected, String versionName, String extra) throws Exception {
        Path input = root.resolve(name + ".hap"), output = root.resolve(name + ".json");
        try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(input))) {
            String metadata = "{\"app\":{\"bundleName\":\"com.amcl.launcher\",\"versionName\":\""+versionName+"\",\"versionCode\":20,\"minAPIVersion\":60000020},\"module\":{\"type\":\"entry\",\"deviceTypes\":[\"phone\"]}}";
            entry(zip,"module.json",oversized ? metadata + " ".repeat(65537) : metadata);
            entry(zip,"resources/rawfile/product-profile.json","{\"name\":\"sideload\",\"publishable\":true,\"developerDiagnostics\":" + diagnostic + extra + "}");
            if (library) entry(zip,"libs/arm64-v8a/libentry.so","fixture");
        }
        AmclSigningRunner.main(new String[]{"--inspect-hap",input.toString(),output.toString()});
        JsonObject result = new Gson().fromJson(Files.readString(output),JsonObject.class);
        if (result.get("inspected").getAsBoolean() != expected) throw new AssertionError(name);
        if (expected && (result.get("versionCode").getAsInt() != 20 || !result.get("product").getAsString().equals("sideload"))) throw new AssertionError("metadata binding");
        return result;
    }
    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("External output directory required");
        Path root=Path.of(args[0]); Files.createDirectories(root);
        run(root,"valid",false,false,true,true);
        run(root,"diagnostic",true,false,true,false);
        run(root,"oversized",false,true,true,false);
        run(root,"missing-native",false,false,false,false);
        JsonObject legacy=run(root,"legacy-protocol",false,false,true,true,"2.0.0","");
        if (!legacy.get("runtimeHostProtocols").toString().equals("[1]")) throw new AssertionError("legacy host protocol");
        JsonObject developer=run(root,"developer-capabilities",false,false,true,true,"2.0.0-dev1",
            ",\"sourceRevision\":\""+"a".repeat(40)+"\",\"releaseKind\":\"developer\",\"runtimeHostProtocols\":[2,1]");
        if (!developer.get("runtimeHostProtocols").toString().equals("[1,2]") ||
            !developer.get("releaseKind").getAsString().equals("developer") ||
            !developer.get("sourceRevision").getAsString().equals("a".repeat(40))) throw new AssertionError("real developer identity");
        for(String protocols:new String[]{"[]","[1,1]","[0]","[1000]","[1.5]","[\"1\"]","[2147483648]","[1,2,3,4,5,6,7,8,9]","null","false","{}","\"1\""}) {
            run(root,"bad-host-"+Math.abs(protocols.hashCode()),false,false,true,false,"2.0.0-dev1",",\"runtimeHostProtocols\":"+protocols);
        }
        run(root,"wrong-kind",false,false,true,false,"2.0.0-dev1",",\"releaseKind\":\"stable\"");
        run(root,"bad-dev-number",false,false,true,false,"2.0.0-dev0","");
        JsonObject bridge=run(root,"plan-bridge",false,false,true,true,"2.0.0",",\"runtimePlanProtocol\":1");
        if(bridge.get("runtimePlanProtocol").getAsInt()!=1 || legacy.get("runtimePlanProtocol").getAsInt()!=0) throw new AssertionError("actual plan capability");
        JsonObject durable=run(root,"plan-durable-reader",false,false,true,true,"2.0.0",",\"runtimePlanProtocol\":2");
        if(durable.get("runtimePlanProtocol").getAsInt()!=2)throw new AssertionError("actual plan2 capability");
        for(String value:new String[]{"3","-1","1.5","\"1\"","null"}) run(root,"bad-plan-"+Math.abs(value.hashCode()),false,false,true,false,"2.0.0",",\"runtimePlanProtocol\":"+value);
        JsonObject requirements=run(root,"runtime-requirements",false,false,true,true,"2.0.0",
            ",\"runtimeRequiredCapabilities\":[\"zipfs-transaction-v1\"],\"runtimeRequiredMajors\":[8,17,21,25]");
        if(!requirements.get("runtimeRequiredCapabilities").toString().equals("[\"zipfs-transaction-v1\"]") ||
            !requirements.get("runtimeRequiredMajors").toString().equals("[8,17,21,25]")) throw new AssertionError("actual runtime requirements");
        for(String fields:new String[]{",\"runtimeRequiredCapabilities\":null",",\"runtimeRequiredCapabilities\":[\"x\"]",
            ",\"runtimeRequiredCapabilities\":[\"x\",\"x\"],\"runtimeRequiredMajors\":[17]",",\"runtimeRequiredMajors\":[17,17]",
            ",\"runtimeRequiredMajors\":[\"17\"]",",\"runtimeRequiredMajors\":[17.5]"})
            run(root,"bad-requirements-"+Math.abs(fields.hashCode()),false,false,true,false,"2.0.0",fields);
        System.out.println("ManualPackageInspectionTest: real ZIP metadata, legacy protocol1, developer identity/capabilities and malformed declarations passed");
    }
}
