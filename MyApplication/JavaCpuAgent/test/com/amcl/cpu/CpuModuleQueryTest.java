package com.amcl.cpu;

import java.lang.module.Configuration;
import java.lang.module.ModuleFinder;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/** 用真实 OSHI 模块建立独立层，验证变换后不依赖 Agent 所在 unnamed module 的辅助类型。 */
public final class CpuModuleQueryTest {
    /** 参数为 OSHI/JNA/SLF4J 真实 JAR；只开放测试反射入口，不改变被测模块间依赖。 */
    public static void main(String[] arguments) throws Exception {
        Path[] paths = new Path[arguments.length];
        for (int i = 0; i < paths.length; i++) paths[i] = Paths.get(arguments[i]);
        ModuleFinder finder = ModuleFinder.of(paths);
        String root = finder.findAll().stream().map(ref -> ref.descriptor().name())
                .filter(name -> name.contains("oshi")).findFirst().orElseThrow();
        // OSHI 把日志接口声明为静态可选依赖；实际加载器会交付它，测试层也显式纳入该根。
        Set<String> roots = new HashSet<String>();
        finder.findAll().forEach(ref -> roots.add(ref.descriptor().name()));
        Configuration config = ModuleLayer.boot().configuration().resolve(finder, ModuleFinder.of(), roots);
        ModuleLayer.Controller controller = ModuleLayer.defineModulesWithOneLoader(config,
                Collections.singletonList(ModuleLayer.boot()), ClassLoader.getPlatformClassLoader());
        Module module = controller.layer().findModule(root).orElseThrow();
        for (String name : module.getPackages()) controller.addExports(module, name, CpuModuleQueryTest.class.getModule());
        CpuQueryTest.verify(controller.layer().findLoader(root), "KirinT92", 3, 0, 0);
        System.out.println("CPU_MODULE_PASS module=" + root + " adapted=" + System.getProperty("amcl.cpu.agent.adapted"));
    }
}
