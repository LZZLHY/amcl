package com.amcl.compat.probe.mixin;

import com.amcl.compat.probe.CreateThreadDeviceProbe;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * 仅属于外置 QA 模组的驱动入口。正式兼容组件不会编译或打包本目录。
 * 在真实客户端 tick 尾部发起受控投递，使取证经过已经加载、经过其他模组变换的
 * Create 类和当前游戏自己的 PacketProcessor；不自行 drain 队列或替换处理器。
 */
@Mixin(value = Minecraft.class, remap = false)
public abstract class MinecraftProbeMixin {
    /** 每帧检查一次隔离和启用条件；测试期间不操作 UI、不创建世界、不修改存档。 */
    @Inject(method = "tick()V", at = @At("TAIL"), remap = false)
    private void amcl$probeTick(CallbackInfo info) {
        CreateThreadDeviceProbe.tick(Minecraft.getInstance());
    }

    /**
     * 原版允许一帧处理包后执行零次 tick 直接渲染。这里覆盖这个合法路径；即使
     * worker 超时后晚到 Add，也在渲染器遍历前按 QA UUID + 对象身份撤走并判失败。
     */
    @Inject(method = "renderFrame(Z)V", at = @At("HEAD"), remap = false)
    private void amcl$probeBeforeRender(boolean renderLevel, CallbackInfo info) {
        CreateThreadDeviceProbe.beforeRender();
    }
}
