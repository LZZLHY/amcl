package com.amcl.cpu;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;

/** 验证坏协议、重复编号、非目标及未知 ABI 不会触发部分变换，测试不提供任何 OSHI 替身。 */
public final class CpuAgentPolicyTest {
    private CpuAgentPolicyTest() { }

    /** 每个负控均调用生产解析或变换器；同一进程不以旧的成功事实掩盖非法参数。 */
    public static void main(String[] arguments) throws Exception {
        System.setProperty("amcl.cpu.schema", "1"); System.setProperty("amcl.cpu.online", "0,2");
        System.setProperty("amcl.cpu.model", "KirinT92"); System.setProperty("amcl.cpu.topology", "");
        CpuAgent.Facts facts = CpuAgent.Facts.read();
        CpuAgent.CpuTransformer transformer = new CpuAgent.CpuTransformer(facts);
        InputStream stream = CpuAgentPolicyTest.class.getResourceAsStream("CpuAgentPolicyTest.class");
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        try { byte[] chunk = new byte[4096]; int count; while ((count = stream.read(chunk)) != -1) buffer.write(chunk, 0, count); }
        finally { stream.close(); }
        byte[] bytes = buffer.toByteArray();
        if (transformer.transform(null, "net/minecraft/Unrelated", null, null, bytes) != null) throw new AssertionError("Non-target mutated");
        if (transformer.transform(null, "oshi/hardware/platform/linux/LinuxCentralProcessor", null, null, bytes) != null) throw new AssertionError("Unknown ABI mutated");
        if (transformer.transform(null, "oshi/hardware/common/AbstractCentralProcessor", String.class, null, bytes) != null) throw new AssertionError("Redefinition allowed");
        rejects("amcl.cpu.schema", "2"); rejects("amcl.cpu.online", "0,0"); rejects("amcl.cpu.online", "-1");
        rejects("amcl.cpu.online", "65536"); rejects("amcl.cpu.topology", "0,0,0"); rejects("amcl.cpu.model", "bad\nname");
        System.out.println("CPU_POLICY_PASS");
    }

    /** 错误必须明确拒绝，不能被降成一份看似正常的部分 CPU 快照。 */
    private static void rejects(String key, String value) {
        String old = System.getProperty(key); System.setProperty(key, value);
        try {
            try { CpuAgent.Facts.read(); throw new AssertionError("Invalid value accepted: " + key); }
            catch (IllegalArgumentException expected) { /* 正确拒绝。 */ }
        } finally { if (old == null) System.clearProperty(key); else System.setProperty(key, old); }
    }
}
