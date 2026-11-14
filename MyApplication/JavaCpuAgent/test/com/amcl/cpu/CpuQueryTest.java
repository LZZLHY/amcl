package com.amcl.cpu;

import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.io.File;

/**
 * 直接查询真实 OSHI 制品的宿主验收程序，不复制任何处理器实现。
 * 每次 JVM 带生产 Agent，OSHI 由无启动器父类的独立加载器定义，验证 helper 零依赖。
 */
public final class CpuQueryTest {
    private CpuQueryTest() { }

    /** 参数：期望型号、期望逻辑数、期望物理数、期望封装数，然后为真实依赖 JAR。 */
    public static void main(String[] arguments) throws Exception {
        URL[] urls = new URL[arguments.length - 4];
        for (int i = 0; i < urls.length; i++) urls[i] = new File(arguments[i + 4]).toURI().toURL();
        // 重复创建互相隔离的加载器，模拟 Forge/Fabric 各自定义同名 OSHI，而不是借父类结果。
        for (int round = 0; round < 2; round++) {
            try (URLClassLoader loader = new URLClassLoader(urls, null)) {
                verify(loader, arguments[0], "runtime".equals(arguments[1]) ? Runtime.getRuntime().availableProcessors() : Integer.parseInt(arguments[1]),
                        Integer.parseInt(arguments[2]), Integer.parseInt(arguments[3]));
            }
        }
        if (!"installed".equals(System.getProperty("amcl.cpu.agent.status"))) throw new AssertionError("Agent not installed");
        if (Integer.parseInt(System.getProperty("amcl.cpu.agent.adapted", "0")) < 2) throw new AssertionError("No real transformations");
        System.out.println("CPU_QUERY_PASS model=" + arguments[0] + " logical=" + arguments[1]
                + " adapted=" + System.getProperty("amcl.cpu.agent.adapted"));
    }

    /** 同时验证名称、数量、位数、标准对象和类所有权；不读取或修改 F3 文案。 */
    public static void verify(ClassLoader loader, String model, int logical, int physical, int packages) throws Exception {
        Class<?> halType;
        boolean legacy;
        try { halType = loader.loadClass("oshi.hardware.platform.linux.LinuxHardwareAbstractionLayer"); legacy = false; }
        catch (ClassNotFoundException absent) { halType = loader.loadClass("oshi.software.os.linux.LinuxHardwareAbstractionLayer"); legacy = true; }
        Object hal = halType.getConstructor().newInstance();
        if (legacy) {
            Object[] processors = (Object[]) halType.getMethod("getProcessors").invoke(hal);
            equal(logical, processors.length, "legacy logical");
            Class<?> api = loader.loadClass("oshi.hardware.Processor");
            for (Object processor : processors) {
                equal(model, api.getMethod("getName").invoke(processor), "legacy name");
                equal(Boolean.TRUE, api.getMethod("isCpu64bit").invoke(processor), "legacy 64bit");
                if (processor.getClass().getClassLoader() != loader) throw new AssertionError("legacy parent ownership");
            }
        } else {
            Object processor = halType.getMethod("getProcessor").invoke(hal);
            Class<?> api = loader.loadClass("oshi.hardware.CentralProcessor");
            equal(logical, api.getMethod("getLogicalProcessorCount").invoke(processor), "logical");
            equal(physical, api.getMethod("getPhysicalProcessorCount").invoke(processor), "physical");
            equal(packages, api.getMethod("getPhysicalPackageCount").invoke(processor), "packages");
            Object identifier = api.getMethod("getProcessorIdentifier").invoke(processor);
            equal(model, identifier.getClass().getMethod("getName").invoke(identifier), "name");
            equal(Boolean.TRUE, identifier.getClass().getMethod("isCpu64bit").invoke(identifier), "64bit");
            // 系统报告还会调用以下标准字段；空值可接受，异常或伪造非空数值不可接受。
            for (String method : new String[]{"getVendor", "getFamily", "getModel", "getStepping", "getIdentifier", "getMicroarchitecture"}) {
                Object value = identifier.getClass().getMethod(method).invoke(identifier);
                if (value == null) throw new AssertionError("Null CPU field: " + method);
            }
            equal(logical, ((java.util.List<?>) api.getMethod("getLogicalProcessors").invoke(processor)).size(), "logical list");
            if (processor.getClass().getClassLoader() != loader) throw new AssertionError("modern parent ownership");
        }
    }

    /** 断言包含实际/期望值，保证不同 ABI 失败时能从外部日志定位。 */
    private static void equal(Object expected, Object actual, String label) {
        if (!expected.equals(actual)) throw new AssertionError(label + ": expected=" + expected + " actual=" + actual);
    }
}
