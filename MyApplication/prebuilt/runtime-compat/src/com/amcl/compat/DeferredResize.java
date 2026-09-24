package com.amcl.compat;

/** Per-client lifecycle, accessed only on the Minecraft render thread. */
public final class DeferredResize {
    private boolean ready;
    private boolean applying;
    private boolean draining;
    private boolean pending;
    private boolean closed;
    private long deferred;
    private long applied;

    public boolean begin() {
        if (closed) return false;
        if (!ready || applying) {
            pending = true;
            deferred++;
            return false;
        }
        applying = true;
        return true;
    }
    public void completed() { applying = false; applied++; }
    public void initialized() { ready = true; }
    public void close() { closed = true; pending = false; }
    public boolean beginDrain() {
        if (!ready || applying || draining || !pending) return false;
        draining = true;
        return true;
    }
    public boolean takePending() {
        if (!pending) return false;
        pending = false;
        return true;
    }
    public void endDrain() { draining = false; }
    public long deferredCount() { return deferred; }
    public long appliedCount() { return applied; }
}
