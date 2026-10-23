/** 使用实际签名器入口的身份判据，覆盖证书轮换、保留公钥与拒绝未知身份的边界。 */
import java.security.KeyFactory;
import java.security.spec.X509EncodedKeySpec;
import java.util.Arrays;
import java.util.Base64;
import org.bouncycastle.asn1.ASN1ObjectIdentifier;
import org.bouncycastle.asn1.DERBitString;
import org.bouncycastle.asn1.x509.AlgorithmIdentifier;
import org.bouncycastle.asn1.x509.SubjectPublicKeyInfo;

public final class SigningIdentityTest {
    /** API26真机系统appId与已验签baseline的同一公有EC key；不包含UDID/私钥/口令。 */
    private static final String PHONE_EC_SPKI = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE6MgXNqzPP9kj1PTf7E6z6Dx8Y9bW1DE6FpBu1XIL8W2c1ZI0oF6hUUH8GMbGxPQjzj8nRiRxoDlPhshMRyvm9A==";
    private static final String PHONE_EC_BITS = "BOjIFzaszz/ZI9T03+xOs+g8fGPW1tQxOhaQbtVyC/FtnNWSNKBeoVFB/BjGxsT0I84/J0YkcaA5T4bITEcr5vQ=";
    /** 固定公有RSA算术向量，由独立Node/OpenSSL导出SPKI与PKCS#1；没有生成/保存私钥。 */
    private static final String RSA_SPKI = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDHpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWluQIDAQAB";
    private static final String RSA_BITS = "MIGJAoGBAMelpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaW5AgMBAAE=";

    public static void main(String[] args) throws Exception {
        check(true, "bundle_key1", "app1", "bundle_key1", "app2");
        check(true, "bundle_key1", "app1", "bundle_key2", "app1");
        check(true, "bundle_key1", "app1", "bundle_key1", "app1");
        check(true, "bundle_key1", "", "bundle_key1", "");
        check(false, "bundle_key1", "app1", "bundle_key2", "app2");
        check(false, "", "", "", "");
        check(false, "", "app1", "", "app2");
        check(false, "bundle_key1", "APP1", "bundle_key2", "app1");
        check(false, "bundle_key1", "app1", "bundle_key1_extra", "app1_extra");
        // 直接执行新的可信身份分支：原公钥不需要自称云端来源；轮换公钥需要独立证明。
        checkMode("app-id", "bundle_key1", "app1", "bundle_key1", "app2", false);
        checkMode("cloud-identifier", "bundle_key1", "app1", "bundle_key2", "app1", true);
        checkMode("", "bundle_key1", "app1", "bundle_key2", "app1", false);
        checkMode("", "bundle_key1", "app1", "bundle_key2", "app2", true);
        checkMode("", "", "", "", "", true);
        checkEncoding("EC", PHONE_EC_SPKI, PHONE_EC_BITS, 65);
        checkEncoding("RSA", RSA_SPKI, RSA_BITS, 140);
        // 坏DER、截断、尾随字节、未知算法、非整字节和空bits不能产出身份。
        byte[] ec = Base64.getDecoder().decode(PHONE_EC_SPKI);
        rejectEncoding(new byte[0]);
        rejectEncoding(Arrays.copyOf(ec, ec.length - 1));
        rejectEncoding(Arrays.copyOf(ec, ec.length + 1));
        rejectEncoding(new SubjectPublicKeyInfo(new AlgorithmIdentifier(new ASN1ObjectIdentifier("1.3.101.112")), new byte[]{2}).getEncoded());
        AlgorithmIdentifier rsa = new AlgorithmIdentifier(new ASN1ObjectIdentifier("1.2.840.113549.1.1.1"));
        rejectEncoding(new SubjectPublicKeyInfo(rsa, new DERBitString(new byte[]{2}, 1)).getEncoded());
        rejectEncoding(new SubjectPublicKeyInfo(rsa, new byte[0]).getEncoded());
        System.out.println("Signing identity: 22 cases passed (9 official-policy, 5 material-trust, 2 independent EC/RSA vectors, 6 malformed/unsupported DER rejection)");
    }
    private static void check(boolean expected, String appId, String identifier, String nextAppId, String nextIdentifier) {
        if (AmclSigningRunner.matchesIdentity(appId, identifier, nextAppId, nextIdentifier) != expected) {
            throw new AssertionError("Signing identity contract failed");
        }
    }

    /** 来源证明改变时直接验证实际runner，不在测试中重写身份选择算法。 */
    private static void checkMode(String expected, String appId, String identifier, String nextAppId,
            String nextIdentifier, boolean cloudBound) {
        if (!AmclSigningRunner.identityMode(appId, identifier, nextAppId, nextIdentifier, cloudBound).equals(expected)) {
            throw new AssertionError("Signing material trust contract failed");
        }
    }

    /** 期望bits来自真机或独立OpenSSL，而实际转换调用正式runner，不能在测试镜像重写它。 */
    private static void checkEncoding(String algorithm, String spki, String bits, int length) throws Exception {
        byte[] encoded = Base64.getDecoder().decode(spki), expected = Base64.getDecoder().decode(bits);
        byte[] actual = AmclSigningRunner.platformPublicKeyBits(encoded);
        if (actual.length != length || !Arrays.equals(expected, actual) || Arrays.equals(encoded, actual)) {
            throw new AssertionError("Platform public key encoding does not match independent vector");
        }
        String appId = AmclSigningRunner.platformAppId("com.amcl.launcher",
                KeyFactory.getInstance(algorithm).generatePublic(new X509EncodedKeySpec(encoded)));
        if (!appId.equals("com.amcl.launcher_" + bits) ||
                !AmclSigningRunner.identityMode(appId, "same-identifier", appId, "another-identifier", false).equals("app-id") ||
                !AmclSigningRunner.identityMode(appId, "same-identifier", "another-public-key", "same-identifier", false).isEmpty()) {
            throw new AssertionError("Original key identity or identifier-only rejection changed");
        }
    }

    /** 不接受错误格式的来源证明；固定异常只意味着拒绝，不把第三方文字打印成材料信息。 */
    private static void rejectEncoding(byte[] encoded) {
        try { AmclSigningRunner.platformPublicKeyBits(encoded); }
        catch (SecurityException expected) { return; }
        throw new AssertionError("Malformed/unsupported public key DER accepted");
    }
}
