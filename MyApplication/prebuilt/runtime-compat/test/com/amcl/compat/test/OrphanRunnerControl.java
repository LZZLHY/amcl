package com.amcl.compat.test;

import java.nio.file.Path;
import java.util.concurrent.CountDownLatch;

/**
 * 真正派生进程负控：root启动继承stdout/stderr的child后立即exit，child继续存活。
 * runner必须靠创建时的job/session所有权回收它，不能依赖root PID还在或EOF自然到达。
 */
public final class OrphanRunnerControl {
    public static void main(String[] args) throws Exception {
        if (args.length == 1 && args[0].equals("child")) {
            System.out.println("[runner-orphan-control] child-started pid=" + ProcessHandle.current().pid());
            System.out.flush(); new CountDownLatch(1).await();
            return;
        }
        String executable = Path.of(System.getProperty("java.home"), "bin",
            System.getProperty("os.name").startsWith("Windows") ? "java.exe" : "java").toString();
        Process child = new ProcessBuilder(executable, "-cp", System.getProperty("java.class.path"),
            OrphanRunnerControl.class.getName(), "child").inheritIO().start();
        System.out.println("[runner-orphan-control] root-exit pid=" + ProcessHandle.current().pid() + " child=" + child.pid());
        System.out.flush(); System.exit(0);
    }
}
