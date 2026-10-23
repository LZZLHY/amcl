package com.amcl.compat.test;

import com.amcl.compat.CompatMixinPlugin;
import com.amcl.compat.CreateFlyThreadingProfile;
import java.lang.reflect.Field;
import java.util.List;
import java.util.Set;
import org.objectweb.asm.tree.ClassNode;
import org.spongepowered.asm.mixin.extensibility.IMixinConfigPlugin;
import org.spongepowered.asm.mixin.extensibility.IMixinInfo;

/**
 * 只替换宿主不存在的 Fabric ModContainer 发现阶段；原 profile 单独对真实输入完整核对。
 * shouldApply/preApply/postApply 全部委派生产插件，所以这里没有复制生产形状检查逻辑。
 * 真正 Fabric/Knot/class tweaker 链仍由单独设备与 Loader 集成门验证。
 */
public final class ThreadingTestPlugin implements IMixinConfigPlugin {
    private static volatile RejectedPostApply capturedRejection;
    private final CompatMixinPlugin delegate = new CompatMixinPlugin();

    /**
     * 只描述真实生产postApply拒绝的这一步；ClassNode内部保存深拷贝，外部每次取得另一个
     * 深拷贝，避免参与断言或复验意外改写原始现场。保留原异常实例用于校验Mixin包装链身份，
     * 不能仅凭相似message就把任意IllegalStateException算作已证明的策略拒绝。
     */
    public static final class RejectedPostApply {
        private final String target;
        private final String mixin;
        private final ClassNode capturedNode;
        private final IllegalStateException failure;
        private RejectedPostApply(String target, String mixin, ClassNode node, IllegalStateException failure) {
            this.target = target; this.mixin = mixin; this.failure = failure;
            capturedNode = new ClassNode(); node.accept(capturedNode);
        }
        public String target() { return target; }
        public String mixin() { return mixin; }
        public IllegalStateException failure() { return failure; }
        /** 快照只供宿主证据读取，绝不回写正在变换的生产ClassNode。 */
        public ClassNode snapshot() { ClassNode copy = new ClassNode(); capturedNode.accept(copy); return copy; }
    }

    /** 每次待测目标变换前显式清空，禁止沿用上一目标或上一配置的拒绝证据。 */
    public static void clearCapturedRejection() { capturedRejection = null; }
    public static RejectedPostApply capturedRejection() { return capturedRejection; }
    public void onLoad(String name) {
        try {
            Field profile = CompatMixinPlugin.class.getDeclaredField("threadingProfile"); profile.setAccessible(true);
            profile.set(delegate, new CreateFlyThreadingProfile());
            Field enabled = CompatMixinPlugin.class.getDeclaredField("threadingVerified"); enabled.setAccessible(true);
            enabled.setBoolean(delegate, true);
        } catch (ReflectiveOperationException error) { throw new IllegalStateException("Test host policy bridge unavailable", error); }
    }
    public List<String> getMixins() { return delegate.getMixins(); }
    public boolean shouldApplyMixin(String target, String mixin) { return delegate.shouldApplyMixin(target, mixin); }
    public String getRefMapperConfig() { return null; }
    public void acceptTargets(Set<String> mine, Set<String> others) { delegate.acceptTargets(mine, others); }
    public void preApply(String name, ClassNode node, String mixin, IMixinInfo info) { delegate.preApply(name, node, mixin, info); }
    public void postApply(String name, ClassNode node, String mixin, IMixinInfo info) {
        try {
            delegate.postApply(name, node, mixin, info);
        } catch (IllegalStateException rejected) {
            capturedRejection = new RejectedPostApply(name, mixin, node, rejected);
            throw rejected;
        }
    }
}
