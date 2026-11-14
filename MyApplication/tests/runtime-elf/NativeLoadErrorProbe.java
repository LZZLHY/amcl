package com.amcl.qa;

import java.io.File;
import java.io.FileOutputStream;

/**
 * 真实游戏 JVM 的装载失败诊断回归。只创建本轮唯一的无效库样本，不加载第三方代码，
 * 不修改路径权限或 loader 路由；最后核对调用者得到本次装载错误，而非此前的可选符号探测。
 * Java8/class52，四代运行包可共用。通过不代表外部原生库 ABI 或系统 namespace 获准。
 */
public final class NativeLoadErrorProbe {
    public static void main(String[] args) throws Exception {
        File sample = File.createTempFile("amcl-native-error-", ".so");
        try {
            try (FileOutputStream stream = new FileOutputStream(sample)) {
                stream.write("AMCL deliberate invalid ELF fixture\n".getBytes("UTF-8"));
            }
            String observed = null;
            try {
                System.load(sample.getAbsolutePath());
            } catch (UnsatisfiedLinkError error) {
                observed = error.getMessage();
            }
            if (observed == null || !observed.contains(sample.getName()) || observed.contains("JNI_OnLoad_")) {
                throw new IllegalStateException("current native load failure was lost: " + observed);
            }
            System.out.println("AMCL_NATIVE_LOAD_ERROR_PROBE passed=true java="
                + System.getProperty("java.version") + " detail=" + observed);
        } finally {
            // 仅删除亲建样本；清理失败不能冒称已闭合，不递归触碰实例临时根。
            if (!sample.delete()) throw new IllegalStateException("failed to remove own native error fixture");
        }
        System.exit(0);
    }
}
