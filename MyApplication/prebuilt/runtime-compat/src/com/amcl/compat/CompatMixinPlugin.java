package com.amcl.compat;

import java.io.InputStream;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import org.objectweb.asm.tree.ClassNode;
import org.spongepowered.asm.mixin.extensibility.IMixinConfigPlugin;
import org.spongepowered.asm.mixin.extensibility.IMixinInfo;

/**
 * 按实际类文件决定兼容补丁，不通过模组显示名或文件名猜测实现版本。
 * 旧版窗口补丁只在 intermediary Minecraft 类存在时登记；Create Fly 只接受已审查的
 * StagingBuffer及LevelUniforms相关类的字节指纹。缺失或未知实现保持原样，避免未来模组升级误套旧补丁。
 */
public final class CompatMixinPlugin implements IMixinConfigPlugin {
    public static final String CREATE_TARGET =
        "com.zurrtum.create.client.flywheel.backend.engine.indirect.StagingBuffer";
    private static final String CREATE_SHA256 =
        "8df71d54f7d6275aaefa33e00d1640dc7d99117dc05e414ccaa02329cba5d141";
    public static final String LEVEL_TARGET = "com.zurrtum.create.client.flywheel.backend.engine.uniform.LevelUniforms";
    public static final String WRITER_TARGET = "com.zurrtum.create.client.flywheel.backend.engine.uniform.UniformWriter";
    public static final String BUFFER_TARGET = "com.zurrtum.create.client.flywheel.backend.engine.uniform.UniformBuffer";
    private boolean resizePresent;
    private boolean createVerified;
    private boolean levelVerified;

    /** 读取类资源而不加载/初始化目标类，避免在 Mixin 注册期间提前初始化游戏或 GL。 */
    private byte[] readClass(String name) {
        try (InputStream input = getClass().getClassLoader().getResourceAsStream(name.replace('.', '/') + ".class")) {
            return input == null ? null : input.readAllBytes();
        } catch (Exception error) {
            System.out.println("[AMCL-COMPAT] class-resource-unavailable target=" + name);
            return null;
        }
    }

    /** 生产门与宿主负例共用的精确指纹判据；读取失败、变更一个字节或未知版本都不应用。 */
    public static boolean matchesCreateFly(byte[] bytes) {
        return matches(bytes, CREATE_SHA256);
    }

    /** 容量修复依赖真实写入宽度和分配器契约，三者必须同时匹配，不能只看显示版本。 */
    public static boolean matchesLevelUniforms(byte[] level, byte[] writer, byte[] buffer) {
        return matches(level, "ed0263e27f4bec336b7673901c42aacd5395a59ac2e6f249a93754805174f1cb")
            && matches(writer, "98c1201182ecb50eda44a940385e6c51e3bd06ac9b8647ba30742b9fa6b580ba")
            && matches(buffer, "4da38b189b8f75b392568665ec92ae2939f80dae308b956d17936cbf65cdc9f4");
    }

    private static boolean matches(byte[] bytes, String expected) {
        if (bytes == null) return false;
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
            StringBuilder result = new StringBuilder();
            for (byte value : digest) result.append(String.format("%02x", value & 255));
            return expected.equals(result.toString());
        } catch (Exception error) { return false; }
    }

    /** 每个 Mixin 配置加载一次，固定本轮目标身份并留下实际命中证据。 */
    @Override public void onLoad(String mixinPackage) {
        resizePresent = readClass("net.minecraft.class_310") != null;
        byte[] create = readClass(CREATE_TARGET);
        createVerified = matchesCreateFly(create);
        if (create != null) System.out.println("[AMCL-FLYWHEEL] schema=1 stage=gate status="
            + (createVerified ? "enabled" : "unknown-class-skipped") + " expected=" + CREATE_SHA256);
        byte[] level = readClass(LEVEL_TARGET);
        levelVerified = matchesLevelUniforms(level, readClass(WRITER_TARGET), readClass(BUFFER_TARGET));
        if (level != null) System.out.println("[AMCL-FLYWHEEL] schema=1 stage=level-gate status="
            + (levelVerified ? "enabled" : "unknown-class-skipped"));
    }

    /** 配置面向客户端；仅返回实际存在且已验证的目标，普通 Fabric 不额外要求 Create。 */
    @Override public List<String> getMixins() {
        List<String> mixins = new ArrayList<>();
        if (resizePresent) mixins.add("MinecraftResizeMixin");
        if (createVerified) mixins.add("CreateFlyStagingBufferMixin");
        if (levelVerified) mixins.add("CreateFlyLevelUniformsMixin");
        return mixins;
    }
    @Override public boolean shouldApplyMixin(String targetClassName, String mixinClassName) {
        if (mixinClassName.endsWith(".CreateFlyStagingBufferMixin")) return createVerified && CREATE_TARGET.equals(targetClassName);
        if (mixinClassName.endsWith(".CreateFlyLevelUniformsMixin")) return levelVerified && LEVEL_TARGET.equals(targetClassName);
        return resizePresent && "net.minecraft.class_310".equals(targetClassName);
    }
    /** 不增加映射、额外目标或二次字节码重写；实际变换由带 require=1 的声明式注入完成。 */
    @Override public String getRefMapperConfig() { return null; }
    @Override public void acceptTargets(Set<String> mine, Set<String> others) {}
    @Override public void preApply(String name, ClassNode node, String mixin, IMixinInfo info) {}
    @Override public void postApply(String name, ClassNode node, String mixin, IMixinInfo info) {}
}
