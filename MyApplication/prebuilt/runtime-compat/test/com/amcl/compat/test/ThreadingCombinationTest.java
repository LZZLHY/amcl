package com.amcl.compat.test;

import com.amcl.compat.CompatMixinPlugin;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.spongepowered.asm.launch.MixinBootstrap;
import org.spongepowered.asm.mixin.MixinEnvironment;
import org.spongepowered.asm.mixin.Mixins;
import org.spongepowered.asm.mixin.transformer.IMixinTransformer;

/**
 * 每个组合在独立 JVM 执行，检查真实 Mixin 链的最终字节。安全结果只允许 guard 仍在
 * 所有业务之前，或 required Mixin 明确拒绝组合；不能把“guard 曾出现”当成最终覆盖。
 */
public final class ThreadingCombinationTest {
    /** 只调用生产验证器；不复制或放宽其opcode白名单来适应测试组合。 */
    private static Method productionValidator() throws Exception {
        Method validator = CompatMixinPlugin.class.getDeclaredMethod("verifyGuardPrefix", ClassNode.class, String.class, String.class);
        validator.setAccessible(true); return validator;
    }

    /**
     * 把实际抛出的拒绝与同一postApply现场绑定。先证明包装链含原异常同一实例，且当前
     * 目标/本方Mixin匹配；再证明外来变换已实际参与，并对捕获快照重调生产validator。
     * cancellable回调可能先构造带ICONST_1的CallbackInfo而尚未执行foreign handler，
     * 因而拒绝消息未必包含foreign名字；参与证据必须来自真实节点而非message猜测。
     */
    private static void proveCapturedPolicyRejection(Throwable thrown, String target, String configuration) throws Exception {
        ThreadingTestPlugin.RejectedPostApply captured = ThreadingTestPlugin.capturedRejection();
        if (captured == null || !captured.target().equals(target)
            || !captured.mixin().equals("com.amcl.compat.mixin.CreateFlyClientPacketThreadingMixin"))
            throw new AssertionError("Transformation failure has no matching real postApply rejection snapshot", thrown);
        boolean sameFailure = false;
        for (Throwable cause = thrown; cause != null; cause = cause.getCause())
            if (cause == captured.failure()) { sameFailure = true; break; }
        if (!sameFailure) throw new AssertionError("Transformation failure is not the captured production rejection instance", thrown);
        ClassNode snapshot = captured.snapshot();
        foreignParticipated(snapshot, configuration);
        try {
            productionValidator().invoke(null, snapshot, "client", "(Lnet/minecraft/network/protocol/game/ClientGamePacketListener;)V");
            throw new AssertionError("Captured rejection did not reproduce on the same production node snapshot");
        } catch (InvocationTargetException reproduced) {
            Throwable reason = reproduced.getCause();
            if (reason.getClass() != captured.failure().getClass()
                || !java.util.Objects.equals(reason.getMessage(), captured.failure().getMessage()))
                throw new AssertionError("Captured node reproduced a different policy failure", reason);
        }
        System.out.println("[threading-combination] PASS foreign-participated=true captured-postApply=true exception-identity=true"
            + " reproduced-production-policy=true config=" + configuration + " reason=" + captured.failure().getMessage());
    }

    /**
     * 每项组合必须留下真实 foreign hook 与 typed调用路径；单有本方guard不算组合。
     * 原overwrite没有独立handler，必须直接在typed方法里找到且仅找到一次touch。
     */
    private static void foreignParticipated(ClassNode node, String configuration) {
        String descriptor = "(Lnet/minecraft/network/protocol/game/ClientGamePacketListener;)V";
        boolean overwrite = configuration.contains("Overwrite");
        String marker = configuration.contains("Cancel") ? "foreign$cancel"
            : configuration.contains("High") ? "foreign$headHigh" : "foreign$headLow";
        MethodNode typed = node.methods.stream().filter(method -> method.name.equals("handle") && method.desc.equals(descriptor)).findFirst().orElseThrow();
        int touches = 0, callsFromTyped = 0, cancelCalls = 0;
        for (MethodNode method : node.methods) {
            for (AbstractInsnNode instruction : method.instructions) {
                if (!(instruction instanceof MethodInsnNode call)) continue;
                if (call.owner.equals("com/amcl/compat/test/foreign/ForeignHooks") && call.name.equals("touch")) {
                    if (!(overwrite ? method == typed : method.name.contains(marker)))
                        throw new AssertionError("Foreign hook reached unexpected method " + method.name);
                    touches++;
                }
                if (method == typed && call.owner.equals(node.name) && call.name.contains(marker)) callsFromTyped++;
                if (method.name.contains("foreign$cancel") && call.name.equals("cancel")
                    && call.owner.equals("org/spongepowered/asm/mixin/injection/callback/CallbackInfo")) cancelCalls++;
            }
        }
        if (touches != 1 || (!overwrite && callsFromTyped != 1)
            || (configuration.contains("Cancel") && cancelCalls != 1))
            throw new AssertionError("Specified foreign Mixin did not actually participate: " + configuration
                + " touches=" + touches + " typedHandlerCalls=" + callsFromTyped + " cancelCalls=" + cancelCalls);
    }

    /** 控制配置由脚本给出，每次只有一个已知的第三方变换。 */
    public static void main(String[] args) throws Exception {
        if (args.length < 1 || args.length > 2) throw new AssertionError("usage: combination-config [expect-unmatched]");
        boolean unmatched = args.length == 2 && args[1].equals("expect-unmatched");
        String target = "com.zurrtum.create.infrastructure.packet.s2c.S2CHoldPacket";
        byte[] original;
        try (InputStream stream = ThreadingCombinationTest.class.getClassLoader().getResourceAsStream(target.replace('.', '/') + ".class")) {
            original = stream.readAllBytes();
        }
        MixinBootstrap.init(); MixinEnvironment.getDefaultEnvironment().setSide(MixinEnvironment.Side.CLIENT);
        Mixins.addConfiguration("amcl-threading-test.mixins.json"); Mixins.addConfiguration(args[0]);
        Constructor<?> factory = Class.forName("org.spongepowered.asm.mixin.transformer.MixinTransformer").getDeclaredConstructor();
        factory.setAccessible(true); IMixinTransformer transformer = (IMixinTransformer) factory.newInstance();
        byte[] changed;
        ThreadingTestPlugin.clearCapturedRejection();
        try {
            changed = transformer.transformClassBytes(target, target, original);
        } catch (Throwable rejected) {
            if (unmatched) throw new AssertionError("Unmatched configuration unexpectedly failed transformation", rejected);
            proveCapturedPolicyRejection(rejected, target, args[0]);
            return;
        }
        ClassNode node = new ClassNode(); new ClassReader(changed).accept(node, 0);
        if (unmatched) {
            try {
                foreignParticipated(node, args[0]);
                throw new AssertionError("Unmatched config falsely counted as actual combination");
            } catch (AssertionError negative) {
                if (!negative.getMessage().startsWith("Specified foreign Mixin did not actually participate:")) throw negative;
                System.out.println("[threading-combination-negative] PASS unmatched config explicitly rejected as participation evidence config=" + args[0]);
                return;
            }
        }
        foreignParticipated(node, args[0]);
        Method validator = productionValidator();
        try {
            validator.invoke(null, node, "client", "(Lnet/minecraft/network/protocol/game/ClientGamePacketListener;)V");
        } catch (InvocationTargetException unsafe) {
            throw new AssertionError("Final combination bypassed guard after production postApply: " + args[0], unsafe.getCause());
        }
        System.out.println("[threading-combination] PASS foreign-participated=true exact-hook=1 final-guard-before-business=true config=" + args[0]);
    }
}
