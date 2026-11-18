/** 真实密码学恢复回归：独立EC向量验证私钥/CSR配对、证书轮换以及现有保险库续期。 */
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import java.io.ByteArrayInputStream;
import java.math.BigInteger;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.KeyFactory;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.X509EncodedKeySpec;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.util.Base64;
import java.util.Date;
import org.bouncycastle.asn1.x500.X500Name;
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter;
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;
import org.bouncycastle.pkcs.jcajce.JcaPKCS10CertificationRequestBuilder;
import org.bouncycastle.pkcs.PKCS10CertificationRequest;

public final class OriginalSigningRecoveryTest {
    private static String pem(String type, byte[] bytes) {
        return "-----BEGIN " + type + "-----\n" + Base64.getMimeEncoder(64, new byte[]{10}).encodeToString(bytes) + "\n-----END " + type + "-----\n";
    }
    private static X509Certificate certificate(KeyPair pair, int serial) throws Exception {
        X500Name subject = new X500Name("CN=Only a regression fixture");
        return new JcaX509CertificateConverter().getCertificate(new JcaX509v3CertificateBuilder(subject,
            BigInteger.valueOf(serial), new Date(0), new Date(System.currentTimeMillis() + 60000), subject, pair.getPublic())
            .build(new JcaContentSignerBuilder("SHA256withECDSA").build(pair.getPrivate())));
    }
    private static String fingerprint(X509Certificate cert) throws Exception {
        StringBuilder result = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(cert.getEncoded())) result.append(String.format("%02x", b & 255));
        return result.toString();
    }
    private static String csr(KeyPair pair) throws Exception {
        return pem("CERTIFICATE REQUEST", new JcaPKCS10CertificationRequestBuilder(new X500Name("CN=Fixture"), pair.getPublic())
            .build(new JcaContentSignerBuilder("SHA256withECDSA").build(pair.getPrivate())).getEncoded());
    }
    private static void rejected(JsonObject input) throws Exception {
        try { AmclSigningRunner.restoreOriginalKey(input); }
        catch (Exception expected) { return; }
        throw new AssertionError("Invalid original signing proof was accepted");
    }
    private static void verifyCurve(int bits) throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("EC"); generator.initialize(bits);
        KeyPair original = generator.generateKeyPair(), other = generator.generateKeyPair();
        X509Certificate cert = certificate(original, 1), sameKeyOtherCertificate = certificate(original, 2);
        JsonObject input = new JsonObject(); input.addProperty("bundleName", "com.amcl.launcher");
        input.addProperty("defaultTeamId", "fixture-team");
        String appId = AmclSigningRunner.platformAppId("com.amcl.launcher", original.getPublic());
        input.addProperty("appId", appId); input.addProperty("fingerprint", fingerprint(cert));
        input.addProperty("privatePem", pem("PRIVATE KEY", original.getPrivate().getEncoded())); input.addProperty("csr", csr(original));
        JsonObject candidate = new JsonObject(); candidate.addProperty("teamId", "fixture-team");
        candidate.addProperty("id", "original-certificate"); candidate.addProperty("objectId", "original-object");
        candidate.addProperty("certificateBase64", Base64.getEncoder().encodeToString(cert.getEncoded()));
        JsonArray certificates = new JsonArray(); certificates.add(candidate); input.add("certificates", certificates);
        JsonObject restored = AmclSigningRunner.restoreOriginalKey(input);
        JsonObject keytoolCsr = input.deepCopy(); keytoolCsr.addProperty("csr", input.get("csr").getAsString()
            .replace("BEGIN CERTIFICATE REQUEST", "BEGIN NEW CERTIFICATE REQUEST").replace("END CERTIFICATE REQUEST", "END NEW CERTIFICATE REQUEST"));
        AmclSigningRunner.restoreOriginalKey(keytoolCsr);
        KeyStore store = KeyStore.getInstance("PKCS12"); store.load(new ByteArrayInputStream(Base64.getDecoder().decode(restored.get("p12Base64").getAsString())), restored.get("storePassword").getAsString().toCharArray());
        if (!restored.get("originalAppId").getAsString().equals(appId) || !restored.get("teamId").getAsString().equals("fixture-team") ||
            !store.isKeyEntry(restored.get("keyAlias").getAsString()) || !restored.get("originalCertificateId").getAsString().equals("original-certificate") ||
            restored.get("originalCertificateValidUntil").getAsLong() != cert.getNotAfter().getTime()) throw new AssertionError("Original key restoration failed");
        // 旧证书可以已删除或续期：同公钥新证书、空证书列表都必须能准备草稿。
        JsonObject rotated = input.deepCopy(); rotated.addProperty("fingerprint", "0".repeat(64));
        AmclSigningRunner.restoreOriginalKey(rotated);
        JsonObject missing = input.deepCopy(); missing.add("certificates", new JsonArray());
        JsonObject withoutCertificate = AmclSigningRunner.restoreOriginalKey(missing);
        if (withoutCertificate.has("originalCertificateId") || !withoutCertificate.get("originalAppId").getAsString().equals(appId)) throw new AssertionError("Missing old certificate blocked renewal");
        // 用实际PKCS12模拟已认证保险库导出，确认续期CSR与原私钥配对；不生成新应用公钥。
        Path directory = Files.createTempDirectory(Path.of(System.getProperty("amcl.test.output")), "saved-key-");
        boolean passed = false;
        try {
            Files.write(directory.resolve("material.p12"), Base64.getDecoder().decode(restored.get("p12Base64").getAsString()));
            Files.writeString(directory.resolve("config.json"), restored.toString());
            JsonObject cached = missing.deepCopy(); cached.addProperty("provider", "cached-key"); cached.addProperty("materialDirectory", directory.toString());
            cached.remove("privatePem"); cached.remove("csr");
            JsonObject renewed = AmclSigningRunner.restoreOriginalKey(cached);
            if (!renewed.get("originalAppId").getAsString().equals(appId)) throw new AssertionError("Saved private key changed");
            cached.addProperty("appId", "different-key"); rejected(cached);
            cached.addProperty("allowProfileContinuation", true);
            if (!AmclSigningRunner.restoreOriginalKey(cached).get("originalAppId").getAsString().equals(appId)) throw new AssertionError("Profile continuation rewrote actual key identity");
            passed = true;
        } finally {
            if (passed) { Files.delete(directory.resolve("config.json")); Files.delete(directory.resolve("material.p12")); Files.delete(directory); }
        }
        JsonObject wrong;
        wrong = input.deepCopy(); wrong.getAsJsonArray("certificates").get(0).getAsJsonObject().addProperty("certificateBase64",
            Base64.getEncoder().encodeToString(sameKeyOtherCertificate.getEncoded())); AmclSigningRunner.restoreOriginalKey(wrong);
        wrong = input.deepCopy(); wrong.addProperty("privatePem", pem("PRIVATE KEY", other.getPrivate().getEncoded())); rejected(wrong);
        wrong = input.deepCopy(); wrong.addProperty("csr", csr(other)); rejected(wrong);
        wrong = input.deepCopy(); wrong.addProperty("appId", AmclSigningRunner.platformAppId("com.amcl.launcher", other.getPublic())); rejected(wrong);
        wrong = input.deepCopy(); wrong.addProperty("bundleName", "com.other.app"); rejected(wrong);
        wrong = input.deepCopy(); wrong.getAsJsonArray("certificates").get(0).getAsJsonObject().addProperty("teamId", ""); rejected(wrong);
        System.out.println("PASS signing continuity P" + bits + ": rotated/deleted certificate accepted; wrong key, CSR, appId and bundle rejected");
    }

    /** 只读固定公开APK，在JVM内核对真实解封配方；不执行包或SO，也不把材料正文写入日志。 */
    private static void verifyHokit(Path source, Path output) throws Exception {
        boolean hap = Files.size(source) == 23299388;
        JsonObject material = hap ? AmclSigningRunner.restoreHokitHap(source) : AmclSigningRunner.restoreHokitPackage(source);
        String pemKey = material.get("privatePem").getAsString().replace("-----BEGIN PRIVATE KEY-----", "").replace("-----END PRIVATE KEY-----", "");
        String pemCsr = material.get("csr").getAsString().replace("-----BEGIN CERTIFICATE REQUEST-----", "").replace("-----END CERTIFICATE REQUEST-----", "")
            .replace("-----BEGIN NEW CERTIFICATE REQUEST-----", "").replace("-----END NEW CERTIFICATE REQUEST-----", "");
        PKCS10CertificationRequest request = new PKCS10CertificationRequest(Base64.getMimeDecoder().decode(pemCsr));
        KeyFactory factory = KeyFactory.getInstance("EC");
        KeyPair pair = new KeyPair(factory.generatePublic(new X509EncodedKeySpec(request.getSubjectPublicKeyInfo().getEncoded())),
            factory.generatePrivate(new PKCS8EncodedKeySpec(Base64.getMimeDecoder().decode(pemKey))));
        if (AmclSigningRunner.platformPublicKeyBits(pair.getPublic().getEncoded()).length != 97) throw new AssertionError("P384 public key lost");
        X509Certificate original = certificate(pair, 8);
        String appId = AmclSigningRunner.platformAppId("com.amcl.launcher", pair.getPublic());
        JsonObject publicIdentity = new JsonObject(); publicIdentity.addProperty("appId", appId);
        publicIdentity.addProperty("publicKeyBytes", AmclSigningRunner.platformPublicKeyBits(pair.getPublic().getEncoded()).length);
        Files.createDirectories(output);
        Files.writeString(output.resolve("hokit-public-identity.json"), publicIdentity.toString());
        JsonObject input = new JsonObject(); input.addProperty("bundleName", "com.amcl.launcher"); input.addProperty("appId", appId);
        input.addProperty("defaultTeamId", "synthetic-account-proof"); input.addProperty("provider", "bundled-template");
        input.addProperty("privatePem", material.get("privatePem").getAsString()); input.addProperty("csr", material.get("csr").getAsString());
        JsonObject cert = new JsonObject(); cert.addProperty("teamId", "synthetic-account-proof"); cert.addProperty("certificateBase64", Base64.getEncoder().encodeToString(original.getEncoded()));
        cert.addProperty("id", "synthetic-certificate"); cert.addProperty("objectId", "synthetic-object");
        JsonArray certificates = new JsonArray(); certificates.add(cert); input.add("certificates", certificates);
        JsonObject restored = AmclSigningRunner.restoreOriginalKey(input);
        if (!restored.get("originalAppId").getAsString().equals(appId)) throw new AssertionError("HoKit original identity not preserved");
        // 同目录亲建错误原件用于pin负控，成功后仅删除这一文件，不清共享输入目录。
        Path changed = Files.createTempFile(output, "hokit-pin-negative-", hap ? ".hap" : ".apk");
        boolean passed = false;
        try {
            byte[] bytes = Files.readAllBytes(source); bytes[bytes.length - 1] ^= 1; Files.write(changed, bytes);
            boolean rejected = false;
            try { if (hap) AmclSigningRunner.restoreHokitHap(changed); else AmclSigningRunner.restoreHokitPackage(changed); }
            catch (SecurityException expected) { rejected = true; }
            if (!rejected) throw new AssertionError("Changed public source accepted"); passed = true;
        } finally { if (passed) Files.delete(changed); }
        System.out.println("PASS exact HoKit " + (hap ? "Harmony 1.9.0" : "Android 1.2.2") + ": static extraction, P384 pairing and modified-package rejection");
    }

    public static void main(String[] args) throws Exception {
        verifyCurve(256); verifyCurve(384);
        if (args.length == 2) verifyHokit(Path.of(args[0]), Path.of(args[1]));
    }
}
