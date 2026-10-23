package com.amcl.compat.test;

import java.util.concurrent.CountDownLatch;

/**
 * 仅 Python suite runner 的故意挂起负控。此 JVM 内唯一工作线程故意设为 non-daemon，
 * 主线程离开后它仍阻止 JVM 退出；外层必须在 deadline 内回收自己创建的整个进程。
 */
public final class HangingRunnerControl {
    public static void main(String[] args) throws Exception {
        CountDownLatch started = new CountDownLatch(1);
        Thread blocked = new Thread(() -> {
            started.countDown();
            try { new CountDownLatch(1).await(); }
            catch (InterruptedException expected) { Thread.currentThread().interrupt(); }
        }, "Deliberate-Non-Daemon-Runner-Control");
        blocked.start(); started.await();
        System.out.println("[runner-negative-control] worker-started non-daemon=true");
        System.out.flush();
    }
}
