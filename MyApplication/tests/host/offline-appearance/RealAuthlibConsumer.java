/*
 * 真实Authlib消费者夹具：编译时只依赖JDK，运行时反射调用Minecraft指定的原版Authlib。
 * 不仿写profile解析、签名状态或纹理模型逻辑；这些判断由真实Authlib/官方agent执行。
 * 反射仅隔离不同版本的方法链接，便于以现有JDK21编译、在JDK25执行新Authlib字节码。
 */
import java.lang.reflect.Method;
import java.net.Proxy;
import java.net.URI;
import java.security.KeyFactory;
import java.security.MessageDigest;
import java.security.PublicKey;
import java.security.spec.X509EncodedKeySpec;
import java.util.Base64;
import java.util.HexFormat;
import java.util.UUID;

public final class RealAuthlibConsumer {
    /** 任一断言失败直接令Java进程非零，禁止把服务已监听误认为真实消费成功。 */
    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    /** 从真实纹理对象取得URL并下载PNG，核对原始资产SHA256，避免仅检查profile元数据。 */
    private static void checkTexture(Object texture, String expectedHash, String model) throws Exception {
        require((texture != null) == !expectedHash.isEmpty(), "texture presence differs: " + expectedHash);
        if (texture == null) return;
        Class<?> type = Class.forName("com.mojang.authlib.minecraft.MinecraftProfileTexture");
        String url = (String) type.getMethod("getUrl").invoke(texture);
        require(url.startsWith("http://127.0.0.1:"), "texture escaped loopback: " + url);
        if (model != null) {
            String actual = (String) type.getMethod("getMetadata", String.class).invoke(texture, "model");
            require(model.equals(actual == null ? "default" : actual), "model mismatch: " + actual);
        }
        byte[] bytes;
        try (var stream = URI.create(url).toURL().openStream()) { bytes = stream.readAllBytes(); }
        String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        require(digest.equals(expectedHash), "PNG digest mismatch: " + digest);
        System.out.println("TEXTURE sha256=" + digest + " bytes=" + bytes.length + " model=" + model);
    }

    /** 依次验证unsigned默认查询与secure查询；不调用join/hasJoined以伪造服务器资格。 */
    public static void main(String[] args) throws Exception {
        UUID uuid = UUID.fromString(args[0]);
        String name = args[1], model = args[2], skinHash = args[3], capeHash = args[4];
        PublicKey publicKey = KeyFactory.getInstance("RSA").generatePublic(new X509EncodedKeySpec(Base64.getDecoder().decode(args[5])));
        Class<?> serviceClass = Class.forName("com.mojang.authlib.yggdrasil.YggdrasilAuthenticationService");
        Object auth = serviceClass.getConstructor(Proxy.class).newInstance(Proxy.NO_PROXY);
        Object session = serviceClass.getMethod("createMinecraftSessionService").invoke(auth);
        Class<?> sessionClass = Class.forName("com.mojang.authlib.minecraft.MinecraftSessionService");
        Class<?> profileClass = Class.forName("com.mojang.authlib.GameProfile");
        Class<?> propertyClass = Class.forName("com.mojang.authlib.properties.Property");
        Method fetch = sessionClass.getMethod("fetchProfile", UUID.class, boolean.class);
        Method getPacked = sessionClass.getMethod("getPackedTextures", profileClass);
        Method unpack = sessionClass.getMethod("unpackTextures", propertyClass);
        for (boolean secure : new boolean[] { false, true }) {
            Object result = fetch.invoke(session, uuid, secure);
            require(result != null, "fetchProfile returned null, secure=" + secure);
            Object profile = result.getClass().getMethod("profile").invoke(result);
            require(uuid.equals(profileClass.getMethod("id").invoke(profile)), "profile UUID changed");
            require(name.equals(profileClass.getMethod("name").invoke(profile)), "profile name changed");
            Object property = getPacked.invoke(session, profile);
            require(property != null, "packed textures missing");
            boolean hasSignature = (boolean) propertyClass.getMethod("hasSignature").invoke(property);
            require(hasSignature == secure, "unsigned query/signature contract differs, secure=" + secure);
            if (secure) {
                require((boolean) propertyClass.getMethod("isSignatureValid", PublicKey.class).invoke(property, publicKey), "Authlib rejected property signature");
                String value = (String) propertyClass.getMethod("value").invoke(property);
                require(value.equals(sessionClass.getMethod("getSecurePropertyValue", propertyClass).invoke(session, property)), "Authlib secure property validation differs");
            }
            Object textures = unpack.invoke(session, property);
            String signature = textures.getClass().getMethod("signatureState").invoke(textures).toString();
            require(signature.equals(secure ? "SIGNED" : "UNSIGNED"), "Authlib signature state=" + signature);
            checkTexture(textures.getClass().getMethod("skin").invoke(textures), skinHash, skinHash.isEmpty() ? null : model);
            checkTexture(textures.getClass().getMethod("cape").invoke(textures), capeHash, null);
            System.out.println("PROFILE secure=" + secure + " state=" + signature + " id=" + uuid + " name=" + name);
        }
        System.out.println("PASS real Authlib consumer: profile, signed/unsigned properties, model and PNG bytes");
    }
}
