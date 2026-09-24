package com.amcl.compat.mixin;

import com.amcl.compat.DeferredResize;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Fabric 1.21.11 intermediary ABI; no shared state with the launcher class loader. */
@Mixin(targets = "net.minecraft.class_310", remap = false)
public abstract class MinecraftResizeMixin {
    @Unique private DeferredResize amcl$resize;
    @Shadow public abstract void method_15993();

    @Unique private DeferredResize amcl$resizeState() {
        // The first callback can run before mixin field initializers in the constructor.
        if (amcl$resize == null) amcl$resize = new DeferredResize();
        return amcl$resize;
    }

    @Inject(method = "method_15993()V", at = @At("HEAD"), cancellable = true, require = 1)
    private void amcl$beforeResize(CallbackInfo ci) {
        if (!amcl$resizeState().begin()) ci.cancel();
    }

    @Inject(method = "method_15993()V", at = @At("RETURN"), require = 1)
    private void amcl$afterResize(CallbackInfo ci) {
        amcl$resizeState().completed();
        amcl$drainResize();
    }

    @Inject(method = "<init>", at = @At("RETURN"), require = 1)
    private void amcl$initialized(CallbackInfo ci) {
        amcl$resizeState().initialized();
        amcl$drainResize();
        System.out.println("[AMCL-RESIZE] schema=1 phase=client-initialized deferred="
            + amcl$resize.deferredCount() + " applied=" + amcl$resize.appliedCount());
    }

    @Unique private void amcl$drainResize() {
        DeferredResize state = amcl$resizeState();
        if (!state.beginDrain()) return;
        try {
            // Replay the client operation, not Window's already-consumed size callback.
            while (state.takePending()) method_15993();
        } finally {
            state.endDrain();
        }
    }

    @Inject(method = "close()V", at = @At("HEAD"), require = 1)
    private void amcl$closed(CallbackInfo ci) {
        DeferredResize state = amcl$resizeState();
        state.close();
        System.out.println("[AMCL-RESIZE] schema=1 phase=client-closed deferred="
            + state.deferredCount() + " applied=" + state.appliedCount());
    }
}
