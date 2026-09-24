package com.amcl.launcher;

/**
 * Early, Java-only renderer scope shared by compatibility helpers.
 *
 * The native launcher publishes {@code amcl.graphics.profile} before the JVM
 * is created.  Vulkan must never enter compatibility helpers that call
 * LWJGL's OpenGL API: the Vulkan profile deliberately has no current GL
 * context even though libglfw is supplied as LWJGL's bootstrap provider.
 */
final class RendererProfilePolicy {
    private static final String GRAPHICS_PROFILE_PROPERTY = "amcl.graphics.profile";
    // 属性已由native在JVM创建前冻结；规则只解析一次，兼容helper热路径不反复split/编译正则。
    private static final String FROZEN_IMPLEMENTATION = System.getProperty("amcl.graphics.implementation", "");
    private static final String FROZEN_IMPLEMENTATION_REASON = implementationRuleReason(
        FROZEN_IMPLEMENTATION);

    private RendererProfilePolicy() {}

    static String profile() {
        return System.getProperty(GRAPHICS_PROFILE_PROPERTY, "");
    }

    static boolean isVulkanProfile() {
        return "minecraft-vulkan".equals(profile());
    }

    /**
     * MG 专用地形/区块规避只属于 MobileGlues。结构化 profile 已存在时具有唯一权威，
     * 不能被旧 amcl.gl.backend 覆盖；旧调用者未提供 profile 时仅接受空值默认 MG 或明确 MG。
     * 未知后端关闭规避，不能把“不是 nativegl/Vulkan”当作“就是 MG”。
     */
    static boolean usesMobileGluesCompatibility(String profile, String legacyBackend) {
        if (profile != null && !profile.isEmpty()) return "mobileglues".equals(profile);
        return legacyBackend == null || legacyBackend.isEmpty() || "mobileglues".equals(legacyBackend);
    }

    static boolean usesMobileGluesCompatibility() {
        return usesMobileGluesCompatibility(profile(), System.getProperty("amcl.gl.backend", ""))
            && "audited-source".equals(currentImplementationReason());
    }
    /** 只缓存解析，保留属性被后置改写时的防御性拒绝；相同String正常路径无需再次分配。 */
    private static String currentImplementationReason() {
        return FROZEN_IMPLEMENTATION.equals(System.getProperty("amcl.graphics.implementation", ""))
            ? FROZEN_IMPLEMENTATION_REASON : "implementation-property-changed";
    }

    /**
     * 本规则只覆盖已审计的MG源码与干净工作树，游戏端仍逐类验证既有RenderPearl SHA256。
     * options摘要允许Debug/Release/诊断构建，但必须为有效的内容摘要，不能拿语义版本号
     * 代替源码身份。新source/worktree默认停用并输出原因；确认上游修复后删除此条规则，
     * 不能为了让新版本继续命中而无证据扩展范围。MobileGL不会进入本规则。
     */
    static String implementationRuleReason(String identity) {
        if (identity == null || identity.isEmpty()) return "implementation-identity-missing";
        String[] fields = identity.split(":", -1);
        if (fields.length != 5 || !"schema=1".equals(fields[0])) return "implementation-identity-invalid";
        if (!"source=f52379eb660209ba03689afeb46b2e1409212e38".equals(fields[1])) return "implementation-source-not-audited";
        if (!"worktree=ce84dd8c90b93bfe636a1955d686930e68e2fb474b6b877ac9add7cbc2ddbaf0".equals(fields[2])
            || !"state=clean".equals(fields[3])) return "implementation-worktree-not-audited";
        if (!fields[4].matches("options=[0-9a-f]{64}")) return "implementation-options-invalid";
        return "audited-source";
    }

    /** 诊断只报告规则身份与判定，不输出任意JVM参数；类哈希门依旧是最终游戏版本界限。 */
    static String quirkRuleReport() {
        return "rule=mg-renderpearl-f52379-v1 gameGate=exact-class-sha256 reason="
            + (usesMobileGluesCompatibility(profile(), System.getProperty("amcl.gl.backend", ""))
                ? currentImplementationReason() : "backend-out-of-scope")
            + " retirement=source-change-requires-reaudit";
    }
}
