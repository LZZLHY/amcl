package com.amcl.compat;

import java.io.InputStream;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.TypeInsnNode;
import org.spongepowered.asm.mixin.extensibility.IMixinConfigPlugin;
import org.spongepowered.asm.mixin.extensibility.IMixinInfo;

/**
 * 按实际类文件决定兼容补丁，不通过模组显示名或文件名猜测实现版本。
 * 旧版窗口补丁只在 intermediary Minecraft 类存在时登记；Create Fly 只接受已审查的
 * StagingBuffer及LevelUniforms相关类的字节指纹。线程规则另由实际模组容器完整判定，
 * 与旧容量/scatter规则独立；缺失或未知实现保持原样，避免未来模组升级误套旧补丁。
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
    private CreateFlyThreadingProfile threadingProfile;
    private boolean threadingVerified;

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
        threadingProfile = new CreateFlyThreadingProfile();
        threadingVerified = threadingProfile.enableForLoadedMods();
    }

    /** 配置面向客户端；仅返回实际存在且已验证的目标，普通 Fabric 不额外要求 Create。 */
    @Override public List<String> getMixins() {
        List<String> mixins = new ArrayList<>();
        if (resizePresent) mixins.add("MinecraftResizeMixin");
        if (createVerified) mixins.add("CreateFlyStagingBufferMixin");
        if (levelVerified) mixins.add("CreateFlyLevelUniformsMixin");
        if (threadingVerified) {
            mixins.add("CreateFlyClientPacketThreadingMixin");
            mixins.add("CreateFlyServerPacketThreadingMixin");
        }
        return mixins;
    }
    @Override public boolean shouldApplyMixin(String targetClassName, String mixinClassName) {
        if (mixinClassName.endsWith(".CreateFlyStagingBufferMixin")) return createVerified && CREATE_TARGET.equals(targetClassName);
        if (mixinClassName.endsWith(".CreateFlyLevelUniformsMixin")) return levelVerified && LEVEL_TARGET.equals(targetClassName);
        if (mixinClassName.endsWith(".CreateFlyClientPacketThreadingMixin")) {
            return threadingVerified && threadingProfile.targets("client").contains(targetClassName);
        }
        if (mixinClassName.endsWith(".CreateFlyServerPacketThreadingMixin")) {
            return threadingVerified && threadingProfile.targets("server").contains(targetClassName);
        }
        return resizePresent && "net.minecraft.class_310".equals(targetClassName);
    }
    /** 不增加映射、额外目标或二次字节码重写；实际变换由带 require=1 的声明式注入完成。 */
    @Override public String getRefMapperConfig() { return null; }
    @Override public void acceptTargets(Set<String> mine, Set<String> others) {}
    /**
     * 已接受 profile 后，对实际定义阶段再次检查 typed/bridge 契约，不能缺目标时半套继续。
     * 不强制预载晚加载类；此处失败由 required Mixin 终止当前游戏会话并保存原始异常。
     */
    @Override public void preApply(String name, ClassNode node, String mixin, IMixinInfo info) {
        String side = threadingSide(mixin);
        if (side == null) return;
        if (!threadingVerified || !threadingProfile.targets(side).contains(name)) {
            throw new IllegalStateException("Unregistered Create threading transform: " + name);
        }
        String descriptor = threadingProfile.descriptor(side).substring("handle".length());
        MethodNode typed = findMethod(node, "handle", descriptor);
        MethodNode bridge = findMethod(node, "handle", "(Lnet/minecraft/network/PacketListener;)V");
        if (typed == null || bridge == null || (typed.access & (Opcodes.ACC_STATIC | Opcodes.ACC_ABSTRACT)) != 0) {
            throw new IllegalStateException("Create threading typed/bridge contract missing: " + name);
        }
        long delegates = 0;
        for (AbstractInsnNode instruction : bridge.instructions) {
            if (instruction instanceof MethodInsnNode call && call.owner.equals(node.name)
                && call.name.equals("handle") && call.desc.equals(descriptor)) delegates++;
        }
        if (delegates != 1) throw new IllegalStateException("Create threading bridge dispatch changed: " + name);
    }

    /**
     * 记录已实际变换的目标，同时检查本方 typed HEAD 到 guard 的控制流前缀。
     * 这是当前 Mixin 步骤的局部证据，完整加载器最终组合仍须集成测试核对；不能据此声称
     * 所有晚加载目标已定义或未知第三方后续注入天然安全。发现本阶段已有提前业务则致命失败。
     */
    @Override public void postApply(String name, ClassNode node, String mixin, IMixinInfo info) {
        String side = threadingSide(mixin);
        if (side == null) return;
        verifyGuardPrefix(node, side, threadingProfile.descriptor(side).substring("handle".length()));
        System.out.println("[AMCL-CREATE-THREAD] schema=1 rule=create-fly-play-threading stage=transform profile="
            + threadingProfile.id() + " side=" + side + " target=" + name + " status=verified-current-mixin-step");
    }

    /** 仅从本方两个专用 Mixin 名识别逻辑侧，不触发 26.2 helper 的类解析。 */
    private static String threadingSide(String mixin) {
        if (mixin.endsWith(".CreateFlyClientPacketThreadingMixin")) return "client";
        if (mixin.endsWith(".CreateFlyServerPacketThreadingMixin")) return "server";
        return null;
    }

    /** 按名称和完整描述符取声明方法，不误选 bridge 或其他同名重载。 */
    private static MethodNode findMethod(ClassNode node, String name, String descriptor) {
        for (MethodNode method : node.methods) {
            if (method.name.equals(name) && method.desc.equals(descriptor)) return method;
        }
        return null;
    }

    /**
     * HEAD 注入前缀只允许构造 CallbackInfo 或传入未使用参数的 null，首个实际回调必须是本方 guard。
     * 不只检查“存在一个 guard”，否则其他较早 HEAD 访问游戏状态时仍可能竞态。
     * 此方法只验证不重写字节码；不认识的组合明确失败，供集成验证继续取证。
     */
    private static void verifyGuardPrefix(ClassNode node, String side, String descriptor) {
        MethodNode typed = findMethod(node, "handle", descriptor);
        String marker = "amcl$guard" + ("client".equals(side) ? "Client" : "Server") + "Thread";
        MethodNode handler = null;
        for (MethodNode method : node.methods) {
            if (method.name.contains(marker)) {
                if (handler != null) throw new IllegalStateException("Duplicate Create threading guard: " + node.name);
                handler = method;
            }
        }
        if (typed == null || handler == null) throw new IllegalStateException("Missing Create threading guard: " + node.name);
        int helperCalls = 0;
        for (AbstractInsnNode instruction : handler.instructions) {
            if (instruction instanceof MethodInsnNode call && call.owner.equals("com/amcl/compat/CreateFlyPacketThreading26")
                && call.name.equals(side) && call.getOpcode() == Opcodes.INVOKESTATIC) helperCalls++;
        }
        if (helperCalls != 1) throw new IllegalStateException("Invalid Create threading helper dispatch: " + node.name);
        boolean reached = false;
        for (AbstractInsnNode instruction : typed.instructions) {
            int opcode = instruction.getOpcode();
            if (opcode < 0) continue;
            if (instruction instanceof MethodInsnNode call) {
                if (call.owner.equals(node.name) && call.name.equals(handler.name) && call.desc.equals(handler.desc)) {
                    reached = true;
                    break;
                }
                if (call.owner.equals("org/spongepowered/asm/mixin/injection/callback/CallbackInfo")
                    && call.name.equals("<init>")) continue;
                throw new IllegalStateException("Call before Create threading guard: " + node.name + " " + call.owner + "." + call.name);
            }
            // 锁定的 Fabric Mixin 0.17.3 / 0.8.7 在 usesCallbackInfo=false 时，
            // loadOrCreateCallbackInfo 生成 ACONST_NULL，而不是分配 CallbackInfo。
            // 本方回调没有读取 callback 参数，null 仅用于其末尾实参，不能视为业务访问。
            // 只允许这一无副作用栈常量；字段、分支、普通调用及其他 opcode 继续拒绝。
            if (opcode == Opcodes.ALOAD || opcode == Opcodes.ASTORE || opcode == Opcodes.DUP
                || opcode == Opcodes.LDC || opcode == Opcodes.ICONST_0 || opcode == Opcodes.ACONST_NULL) continue;
            if (instruction instanceof TypeInsnNode type && opcode == Opcodes.NEW
                && type.desc.equals("org/spongepowered/asm/mixin/injection/callback/CallbackInfo")) continue;
            throw new IllegalStateException("Instruction before Create threading guard: " + node.name + " opcode=" + opcode);
        }
        if (!reached) throw new IllegalStateException("Unreachable Create threading guard: " + node.name);
    }
}
