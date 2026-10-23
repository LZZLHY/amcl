/*
 * 手机内HAP重签的最小执行入口：由AMCL现有独立JVM processor运行。
 * 私有配置从受保护文件读取，密码不出现在processor参数、日志或结果JSON中。
 * SDK工具的stdout/stderr在内存丢弃，仅导出签名/验签布尔值、包摘要与异常类型。
 */
import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.ohos.hapsigntool.HapSignTool;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.KeyStore;
import java.security.PublicKey;
import java.util.Arrays;
import java.util.Base64;
import java.security.SecureRandom;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.io.ByteArrayInputStream;
import java.util.zip.ZipFile;
import java.nio.file.attribute.PosixFilePermissions;
import org.bouncycastle.asn1.x509.SubjectPublicKeyInfo;

public final class AmclSigningRunner {
    /**
     * 系统appId编码的是实际公钥bits，不是Java PublicKey.getEncoded()的整个SPKI。
     * OpenHarmony security_appverify 的GetPublickeyBase64调用i2d_PublicKey：EC对应
     * X9.62公钥点，RSA对应PKCS#1 RSAPublicKey DER，二者均为SPKI的subjectPublicKey。
     * 使用固定签名器已有的ASN.1解析器按结构提取BIT STRING，不能靠截断固定91/65长度
     * 或放宽appId字符串匹配；曲线、RSA长度和DER长度编码均可能变化。非EC/RSA算法、
     * 空公钥及非整字节BIT STRING失败关闭，不向“仅identifier匹配”的导入材料授信。
     * 依据官方commit821f4dd1f531f59d8f6f07f63340379aff1f318a：
     * interfaces/innerkits/appverify/src/util/hap_cert_verify_openssl_utils.cpp:140-167。
     */
    static byte[] platformPublicKeyBits(byte[] encodedSpki) {
        try {
            SubjectPublicKeyInfo info = SubjectPublicKeyInfo.getInstance(encodedSpki);
            String oid = info.getAlgorithm().getAlgorithm().getId();
            if (!oid.equals("1.2.840.10045.2.1") && !oid.equals("1.2.840.113549.1.1.1")) {
                throw new SecurityException("Signing public key encoding unsupported");
            }
            if (info.getPublicKeyData().getPadBits() != 0) {
                throw new SecurityException("Signing public key encoding unsupported");
            }
            byte[] bits = info.getPublicKeyData().getOctets();
            if (bits.length == 0) throw new SecurityException("Signing public key encoding unsupported");
            return bits;
        } catch (RuntimeException error) {
            // 第三方ASN.1错误消息可能含任意输入，只导出固定原因而不回显原异常。
            throw new SecurityException("Signing public key encoding unsupported");
        }
    }

    /** 已核实实际叶证书公钥后才调用，继续精确比较包名与公钥，不接受任意旧appId后缀。 */
    static String platformAppId(String bundleName, PublicKey key) {
        return bundleName + "_" + Base64.getEncoder().encodeToString(platformPublicKeyBits(key.getEncoded()));
    }

    /** 官方覆盖身份规则：只接受非空且精确相等的appId或appIdentifier，不做大小写/前缀匹配。 */
    static boolean matchesIdentity(String currentAppId, String currentIdentifier, String nextAppId, String nextIdentifier) {
        return (!currentAppId.isEmpty() && currentAppId.equals(nextAppId)) ||
                (!currentIdentifier.isEmpty() && currentIdentifier.equals(nextIdentifier));
    }

    /**
     * 将官方身份规则与材料来源证明分开：原公钥可由已装appId独立证明；
     * 公钥轮换只凭appIdentifier时，必须有Vault内部建立的云端应用/材料绑定，
     * 用户导入Profile自带的root或自称origin不能成为这种证明。
     */
    static String identityMode(String currentAppId, String currentIdentifier, String nextAppId,
            String nextIdentifier, boolean cloudBindingVerified) {
        if (!currentAppId.isEmpty() && currentAppId.equals(nextAppId)) return "app-id";
        if (cloudBindingVerified && !currentIdentifier.isEmpty() && currentIdentifier.equals(nextIdentifier)) {
            return "cloud-identifier";
        }
        return "";
    }

    /** 小型公有元数据的固定UTF-8摘要；与ArkTS Vault的材料revision编码完全一致。 */
    private static String textSha256(String text) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8));
        StringBuilder result = new StringBuilder();
        for (byte value : digest) result.append(String.format("%02x", value & 255));
        return result.toString();
    }

    /** 缺少旧配置可选字段时给空值；仅用于来源证明降级，不放宽包名/版本等核心身份。 */
    private static String optionalString(JsonObject object, String name) {
        return object.has(name) && object.get(name).isJsonPrimitive() ? object.get(name).getAsString() : "";
    }
    /**
     * 在手机独立JVM中创建新密钥和CSR，供有权管理同一AGC应用的用户获取新证书。
     * 输出只存入私有临时目录，上层立刻HUKS加密；工具stdout/stderr不落盘，原安装私钥不会被替换。
     */
    private static void generateKey(Path root, Path resultPath) throws Exception {
        Files.createDirectories(root);
        Files.setPosixFilePermissions(root, PosixFilePermissions.fromString("rwx------"));
        PrintStream out = System.out, err = System.err;
        PrintStream quiet = new PrintStream(OutputStream.nullOutputStream(), true, StandardCharsets.UTF_8);
        Path key = root.resolve("new.p12"), csr = root.resolve("new.csr");
        try {
            System.setOut(quiet); System.setErr(quiet);
            byte[] random = new byte[32]; new SecureRandom().nextBytes(random);
            String password = Base64.getUrlEncoder().withoutPadding().encodeToString(random);
            boolean made = HapSignTool.processCmd(new String[]{"generate-keypair", "-keyAlias", "amclUpdate",
                "-keyAlg", "ECC", "-keySize", "NIST-P-256", "-keystoreFile", key.toString(),
                "-keystorePwd", password, "-keyPwd", password});
            if (!made || !HapSignTool.processCmd(new String[]{"generate-csr", "-keyAlias", "amclUpdate",
                "-subject", "CN=AMCL Update", "-signAlg", "SHA256withECDSA", "-keystoreFile", key.toString(),
                "-keystorePwd", password, "-keyPwd", password, "-outFile", csr.toString()})) {
                throw new IllegalStateException("Key generation failed");
            }
            JsonObject result = new JsonObject();
            result.addProperty("keyAlias", "amclUpdate"); result.addProperty("keyPassword", password);
            result.addProperty("storePassword", password); result.addProperty("signAlg", "SHA256withECDSA");
            result.addProperty("p12Base64", Base64.getEncoder().encodeToString(Files.readAllBytes(key)));
            result.addProperty("csr", Files.readString(csr));
            Files.writeString(resultPath, new Gson().toJson(result), StandardCharsets.UTF_8);
            Files.setPosixFilePermissions(resultPath, PosixFilePermissions.fromString("rw-------"));
        } finally {
            Files.deleteIfExists(key); Files.deleteIfExists(csr);
            System.setOut(out); System.setErr(err); quiet.close();
        }
    }
    /** 流式计算真实输出SHA-256，避免把文件存在误写为签名验收通过。 */
    private static String sha256(Path path) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (java.io.InputStream stream = Files.newInputStream(path)) {
            byte[] buffer = new byte[65536];
            for (int size; (size = stream.read(buffer)) >= 0;) if (size != 0) digest.update(buffer, 0, size);
        }
        StringBuilder text = new StringBuilder();
        for (byte value : digest.digest()) text.append(String.format("%02x", value & 255));
        return text.toString();
    }

    /** 固定私有材料文件名，不允许配置把输出引到任意目录或把秘密用于日志内容。 */
    public static void main(String[] args) throws Exception {
        // 手动导入只读元数据，不接触私钥。限制每个条目的解压字节数，避免恶意 ZIP
        // 占满内存；官方原始包 SHA-256 由调用方验证，元数据本身不构成发布证明。
        if (args.length == 3 && args[0].equals("--inspect-hap")) {
            JsonObject inspected = new JsonObject();
            try (ZipFile zip = new ZipFile(Path.of(args[1]).toFile())) {
                String[] required = {"module.json", "resources/rawfile/product-profile.json"};
                JsonObject[] values = new JsonObject[2];
                for (int i = 0; i < required.length; i++) {
                    final String entryName = required[i];
                    if (zip.stream().filter(entry -> entry.getName().equals(entryName)).count() != 1) throw new SecurityException("Ambiguous metadata");
                    try (java.io.InputStream stream = zip.getInputStream(zip.getEntry(entryName))) {
                        byte[] data = stream.readNBytes(65537);
                        if (data.length > 65536) throw new SecurityException("Metadata too large");
                        values[i] = new Gson().fromJson(new String(data, StandardCharsets.UTF_8), JsonObject.class);
                    }
                }
                JsonObject app = values[0].getAsJsonObject("app"), module = values[0].getAsJsonObject("module");
                if (!"entry".equals(module.get("type").getAsString()) || zip.getEntry("libs/arm64-v8a/libentry.so") == null) throw new SecurityException("Unsupported package");
                if (!values[1].get("publishable").getAsBoolean() || values[1].get("developerDiagnostics").getAsBoolean()) throw new SecurityException("Diagnostic package");
                inspected.addProperty("bundleName", app.get("bundleName").getAsString());
                inspected.addProperty("versionName", app.get("versionName").getAsString());
                inspected.addProperty("versionCode", app.get("versionCode").getAsInt());
                inspected.addProperty("product", values[1].get("name").getAsString());
                inspected.addProperty("minApi", app.get("minAPIVersion").getAsInt() % 1000);
                inspected.add("deviceTypes", module.get("deviceTypes"));
                inspected.addProperty("inspected", true);
            } catch (Throwable error) {
                inspected = new JsonObject(); inspected.addProperty("inspected", false);
            }
            Files.writeString(Path.of(args[2]), inspected.toString(), StandardCharsets.UTF_8);
            return;
        }
        if (args.length == 3 && args[0].equals("--generate-key")) {
            try { generateKey(Path.of(args[1]), Path.of(args[2])); }
            catch (Throwable error) {
                // 第三方异常可能包含工具参数，绝不让默认异常打印泄露随机口令。
                Files.writeString(Path.of(args[2]), "{\"error\":\"KEY_GENERATION_FAILED\"}", StandardCharsets.UTF_8);
            }
            return;
        }
        if (args.length != 5) throw new IllegalArgumentException("Expected config,input,output,result,job paths");
        Path config = Path.of(args[0]).toAbsolutePath().normalize();
        Path root = config.getParent();
        Path input = Path.of(args[1]).toAbsolutePath().normalize();
        Path output = Path.of(args[2]).toAbsolutePath().normalize();
        Path resultPath = Path.of(args[3]).toAbsolutePath().normalize();
        JsonObject result = new JsonObject();
        String architecture = System.getProperty("os.arch", "");
        result.addProperty("executedOnPhone", (architecture.equals("aarch64") || architecture.equals("arm64")) && Files.isDirectory(Path.of("/system")));
        result.addProperty("osName", System.getProperty("os.name"));
        result.addProperty("osArch", architecture);
        result.addProperty("processId", ProcessHandle.current().pid());
        result.addProperty("javaVersion", System.getProperty("java.version"));
        result.addProperty("signed", false);
        result.addProperty("verified", false);
        // 丢弃签名工具的所有直接输出，原始异常消息可能回显命令参数，不能落入普通日志。
        PrintStream originalOut = System.out;
        PrintStream originalErr = System.err;
        PrintStream quiet = new PrintStream(OutputStream.nullOutputStream(), true, StandardCharsets.UTF_8);
        try {
            System.setOut(quiet);
            System.setErr(quiet);
            // 沙箱是第一层边界，临时材料额外只允许当前UID访问；权限收紧失败即停止。
            Files.setPosixFilePermissions(root, PosixFilePermissions.fromString("rwx------"));
            for (String name : new String[]{"config.json", "material.p12", "material.cer", "material.p7b"}) {
                Files.setPosixFilePermissions(root.resolve(name), PosixFilePermissions.fromString("rw-------"));
            }
            // 发布来源与原始摘要先验证，尚未通过时不能用用户私钥给任意文件签名。
            JsonObject job = new Gson().fromJson(Files.readString(Path.of(args[4])), JsonObject.class);
            String inputHash = sha256(input);
            result.addProperty("inputSha256", inputHash);
            if (!inputHash.equalsIgnoreCase(job.get("sha256").getAsString())) throw new SecurityException("Input digest mismatch");
            try (ZipFile zip = new ZipFile(input.toFile())) {
                JsonObject metadata = new Gson().fromJson(new String(zip.getInputStream(zip.getEntry("module.json")).readAllBytes(), StandardCharsets.UTF_8), JsonObject.class);
                JsonObject app = metadata.getAsJsonObject("app");
                JsonObject module = metadata.getAsJsonObject("module");
                if (!app.get("bundleName").getAsString().equals(job.get("bundleName").getAsString()) ||
                    app.get("versionCode").getAsInt() != job.get("versionCode").getAsInt() ||
                    // 同 code 的多个预览包必须逐一核对版本名，不能让发布清单冒认别的发行。
                    !app.get("versionName").getAsString().equals(job.get("versionName").getAsString()) ||
                    !module.get("type").getAsString().equals("entry")) throw new SecurityException("HAP identity mismatch");
                // HAP采用系统版本+API打包值（如60000020），设备返回单独API级别；低三位才是API。
                int minimum = app.get("minAPIVersion").getAsInt() % 1000;
                if (minimum <= 0 || minimum > job.get("apiVersion").getAsInt()) throw new SecurityException("HAP API incompatible");
                // 正式入口传当前系统设备类型；不能只验证产品标签后把错误deviceTypes的包交给安装。
                if (job.has("deviceType")) {
                    boolean deviceAllowed = false;
                    if (module.has("deviceTypes") && module.get("deviceTypes").isJsonArray()) {
                        for (com.google.gson.JsonElement device : module.getAsJsonArray("deviceTypes")) {
                            if (device.isJsonPrimitive() && device.getAsString().equals(job.get("deviceType").getAsString())) {
                                deviceAllowed = true;
                            }
                        }
                    }
                    if (!deviceAllowed) throw new SecurityException("HAP device incompatible");
                }
                if (zip.getEntry("libs/arm64-v8a/libentry.so") == null) throw new SecurityException("HAP ABI incompatible");
                String profileEntry = "resources/rawfile/product-profile.json";
                if (zip.getEntry(profileEntry) == null) throw new SecurityException("HAP payload identity unavailable");
                JsonObject product = new Gson().fromJson(new String(zip.getInputStream(zip.getEntry(profileEntry)).readAllBytes(), StandardCharsets.UTF_8), JsonObject.class);
                String name = product.get("name").getAsString();
                if (!name.equals(job.get("product").getAsString()) && !(name.equals("default") && job.get("product").getAsString().equals("sideload"))) {
                    throw new SecurityException("HAP product mismatch");
                }
                String identity = product.has("sourceRevision") ? product.get("sourceRevision").getAsString() : "";
                if (!identity.matches("[0-9a-f]{40}")) throw new SecurityException("HAP source revision unavailable");
                result.addProperty("payloadIdentity", identity);
            }
            // .cer是签发证书链，P12的alias可能仍保留CSR生成时的自签名证书。
            // 用alias公钥选择链中真正的签发叶证书，不能要求自签名证书与签发证书DER完全相同。
            JsonObject settings = new Gson().fromJson(Files.readString(config), JsonObject.class);
            String alias = settings.get("keyAlias").getAsString();
            String keyPassword = settings.get("keyPassword").getAsString();
            String storePassword = settings.get("storePassword").getAsString();
            String algorithm = settings.get("signAlg").getAsString();
            KeyStore keyStore = KeyStore.getInstance("PKCS12");
            try (java.io.InputStream stream = Files.newInputStream(root.resolve("material.p12"))) {
                keyStore.load(stream, storePassword.toCharArray());
            }
            X509Certificate aliasCertificate = (X509Certificate) keyStore.getCertificate(alias);
            if (aliasCertificate == null || !keyStore.isKeyEntry(alias)) throw new SecurityException("Signing alias unavailable");
            X509Certificate certificate = null;
            for (java.security.cert.Certificate candidate : CertificateFactory.getInstance("X.509").generateCertificates(
                    new ByteArrayInputStream(Files.readAllBytes(root.resolve("material.cer"))))) {
                if (Arrays.equals(candidate.getPublicKey().getEncoded(), aliasCertificate.getPublicKey().getEncoded())) {
                    if (certificate != null) throw new SecurityException("Ambiguous signing certificate");
                    certificate = (X509Certificate) candidate;
                }
            }
            if (certificate == null) throw new SecurityException("Signing certificate missing from chain");
            // 固定工具只证明CMS与链内部自洽，不能把Profile自带root视为系统可信根。
            // 后续还要用已装appId或独立云端绑定证明身份；系统安装器继续作最终信任裁决。
            Path profileJson = root.resolve("profile-check.json");
            if (!HapSignTool.processCmd(new String[]{"verify-profile", "-inFile", root.resolve("material.p7b").toString(),
                    "-outFile", profileJson.toString()})) throw new SecurityException("Profile verification failed");
            JsonObject verification = new Gson().fromJson(Files.readString(profileJson), JsonObject.class);
            if (!verification.get("verifiedPassed").getAsBoolean()) throw new SecurityException("Profile verification failed");
            JsonObject profile = verification.getAsJsonObject("content");
            JsonObject bundle = profile.getAsJsonObject("bundle-info");
            if (!bundle.get("bundle-name").getAsString().equals(job.get("bundleName").getAsString())) throw new SecurityException("Profile bundle mismatch");
            String installedIdentifier = job.get("appIdentifier").getAsString();
            // 来源证据与实际提取材料匹配，防止陈旧证明套到新Profile或导入材料上。
            String certificateHash = sha256(root.resolve("material.cer"));
            String profileHash = sha256(root.resolve("material.p7b"));
            String origin = optionalString(settings, "materialOrigin");
            if (!origin.equals("cloud-bound")) origin = "imported";
            String cloudIdentifier = origin.equals("cloud-bound") ? optionalString(settings, "cloudAppIdentifier") : "";
            // 随机存储修订覆盖同证书/Profile但私钥库、别名、算法或口令更换；口令不做公开哈希。
            String materialRecordId = optionalString(settings, "materialRecordId");
            if (!materialRecordId.isEmpty() && !materialRecordId.matches("[0-9a-f]{32}")) {
                throw new SecurityException("Signature material proof mismatch");
            }
            String materialRevision = textSha256(origin + "|" + certificateHash + "|" + profileHash + "|" + cloudIdentifier +
                    (materialRecordId.isEmpty() ? "" : "|" + materialRecordId));
            String expectedRevision = optionalString(settings, "materialRevision");
            if (!expectedRevision.isEmpty() && !expectedRevision.equals(materialRevision)) {
                throw new SecurityException("Signature material proof mismatch");
            }
            long verifiedAt = settings.has("cloudVerifiedAt") ? settings.get("cloudVerifiedAt").getAsLong() : 0;
            boolean cloudBound = origin.equals("cloud-bound") && !installedIdentifier.isEmpty()
                    && cloudIdentifier.equals(installedIdentifier)
                    && optionalString(settings, "cloudBundleName").equals(job.get("bundleName").getAsString())
                    && optionalString(settings, "cloudCertificateSha256").equals(certificateHash)
                    && optionalString(settings, "cloudProfileSha256").equals(profileHash)
                    && verifiedAt > 0 && verifiedAt <= System.currentTimeMillis();
            String targetAppId = platformAppId(job.get("bundleName").getAsString(), certificate.getPublicKey());
            if (!matchesIdentity(job.has("appId") ? job.get("appId").getAsString() : "", installedIdentifier,
                    targetAppId, bundle.has("app-identifier") ? bundle.get("app-identifier").getAsString() : "")) {
                throw new SecurityException("Profile identifier mismatch");
            }
            String mode = identityMode(job.has("appId") ? job.get("appId").getAsString() : "", installedIdentifier,
                    targetAppId, bundle.has("app-identifier") ? bundle.get("app-identifier").getAsString() : "", cloudBound);
            if (mode.isEmpty()) throw new SecurityException("Profile identifier trust unavailable");
            result.addProperty("identityMode", mode);
            result.addProperty("profileTrust", cloudBound ? "cloud-bound" : "system-installation-required");
            result.addProperty("materialRevision", materialRevision);
            // 已验签Profile必须绑定当前实际使用的叶证书，不能借另一个合法Profile的appIdentifier过关。
            String certificateField = profile.get("type").getAsString().equals("debug") ? "development-certificate" : "distribution-certificate";
            X509Certificate profileCertificate = (X509Certificate) CertificateFactory.getInstance("X.509").generateCertificate(
                    new ByteArrayInputStream(bundle.get(certificateField).getAsString().getBytes(StandardCharsets.UTF_8)));
            if (!Arrays.equals(certificate.getEncoded(), profileCertificate.getEncoded())) throw new SecurityException("Profile certificate mismatch");
            JsonObject acls = profile.getAsJsonObject("acls");
            boolean jitAllowed = false;
            if (acls != null && acls.has("allowed-acls")) {
                for (com.google.gson.JsonElement acl : acls.getAsJsonArray("allowed-acls")) {
                    if (acl.isJsonPrimitive() && acl.getAsString().equals("ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY")) jitAllowed = true;
                }
            }
            if (!jitAllowed) throw new SecurityException("Profile JIT permission missing");
            if (profile.get("type").getAsString().equals("debug") && job.has("deviceUdid")) {
                boolean includesDevice = false;
                JsonObject debugInfo = profile.getAsJsonObject("debug-info");
                if (debugInfo != null && debugInfo.has("device-ids")) {
                    for (com.google.gson.JsonElement device : debugInfo.getAsJsonArray("device-ids")) {
                        if (device.getAsString().equalsIgnoreCase(job.get("deviceUdid").getAsString())) includesDevice = true;
                    }
                }
                if (!includesDevice) throw new SecurityException("Profile device missing");
            }
            long now = System.currentTimeMillis() / 1000;
            JsonObject validity = profile.getAsJsonObject("validity");
            if (now < validity.get("not-before").getAsLong() || now >= validity.get("not-after").getAsLong()) throw new SecurityException("Profile expired");
            certificate.checkValidity();
            // 热Ready的安装准入必须消费这组真实期限，不能用账号有效替代证书/Profile有效。
            long validFrom = Math.max(certificate.getNotBefore().getTime(), validity.get("not-before").getAsLong() * 1000L);
            long validUntil = Math.min(certificate.getNotAfter().getTime(), validity.get("not-after").getAsLong() * 1000L);
            result.addProperty("signatureValidFrom", validFrom);
            result.addProperty("signatureValidUntil", validUntil);
            result.addProperty("signatureVerifiedAt", System.currentTimeMillis());
            String[] signArgs = {"sign-app", "-mode", "localSign", "-keyAlias", alias,
                "-appCertFile", root.resolve("material.cer").toString(),
                "-profileFile", root.resolve("material.p7b").toString(),
                "-keystoreFile", root.resolve("material.p12").toString(),
                "-keyPwd", keyPassword, "-keystorePwd", storePassword,
                "-signAlg", algorithm, "-signCode", "1",
                "-inFile", input.toString(), "-outFile", output.toString()};
            System.setOut(quiet);
            System.setErr(quiet);
            boolean signed = HapSignTool.processCmd(signArgs);
            result.addProperty("signed", signed);
            if (signed && Files.isRegularFile(output)) {
                result.addProperty("sha256", sha256(output));
                result.addProperty("bytes", Files.size(output));
                // SDK验签要求显式证书链/Profile输出，而且证书输出必须是.cer，不能省略或写.pem。
                boolean verified = HapSignTool.processCmd(new String[]{"verify-app", "-inForm", "zip",
                    "-inFile", output.toString(), "-outCertChain", root.resolve("verified.cer").toString(),
                    "-outProfile", root.resolve("verified.p7b").toString()});
                result.addProperty("verified", verified);
            }
        } catch (Throwable error) {
            result.addProperty("errorClass", error.getClass().getName());
            // 仅允许我们定义的固定原因码进入结果，第三方原始消息可能含秘密或命令参数。
            for (String reason : new String[]{"Signing alias unavailable", "Ambiguous signing certificate",
                    "Signing certificate missing from chain", "Signing public key encoding unsupported", "Existing certificate required", "Profile verification failed",
                    "Profile bundle mismatch", "Profile identifier mismatch", "Profile identifier trust unavailable", "Signature material proof mismatch",
                    "Profile certificate mismatch", "Profile JIT permission missing", "Profile device missing", "Profile expired", "Input digest mismatch",
                    "HAP identity mismatch", "HAP API incompatible", "HAP device incompatible", "HAP ABI incompatible", "HAP product mismatch"}) {
                if (reason.equals(error.getMessage())) result.addProperty("failureReason", reason);
            }
            if (error instanceof com.ohos.hapsigntool.error.CustomException) {
                result.addProperty("errorCode", ((com.ohos.hapsigntool.error.CustomException) error).getError().getErrorCode());
            }
        } finally {
            System.setOut(originalOut);
            System.setErr(originalErr);
            quiet.close();
            Files.writeString(resultPath, new Gson().toJson(result), StandardCharsets.UTF_8);
            // 该明文口令配置是一次性测试输入，原始本机签名材料保留，执行结束删除临时口令文件。
            Files.deleteIfExists(config);
        }
        System.out.println("AMCL_PHONE_SIGNER_RESULT_WRITTEN");
    }
}
