import java.io.BufferedWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import org.openjdk.jcstress.infra.collectors.DiskReadCollector;
import org.openjdk.jcstress.infra.collectors.InProcessCollector;
import org.openjdk.jcstress.infra.collectors.TestResult;
import org.openjdk.jcstress.infra.grading.TestGrading;

/** 只导出原 jcstress 收集器和 grader 的结果，不实现另一套并发断言或允许结果表。
 * API_MISMATCH 保留未运行，不能因为上游退出码为0就把缺少API的测试记成通过。
 * 输入仅为本轮原 harness 写出的二进制记录；输出按测试配置逐条保留，不混淆不同编译臂。
 */
public final class JcstressResultExport {
    private JcstressResultExport() { }

    /** 最小 JSON 字符串编码；控制字符逐字转义，保留完整用例名/诊断正文。 */
    private static String quote(String value) {
        StringBuilder out = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == '"' || c == '\\') out.append('\\').append(c);
            else if (c < 32) out.append(String.format("\\u%04x", (int)c));
            else out.append(c);
        }
        return out.append('"').toString();
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 2) throw new IllegalArgumentException("result.bin.gz output.jsonl");
        InProcessCollector collector = new InProcessCollector();
        DiskReadCollector reader = new DiskReadCollector(args[0], collector);
        try { reader.dump(); } finally { reader.close(); }
        int count = 0;
        try (BufferedWriter output = Files.newBufferedWriter(Paths.get(args[1]), StandardCharsets.UTF_8)) {
            for (TestResult result : collector.getTestResults()) {
                String status = result.status().name();
                String state;
                if ("NORMAL".equals(status)) {
                    TestGrading grading = result.grading();
                    state = grading.isPassed ? "PASS" : "FAIL";
                } else state = "API_MISMATCH".equals(status) ? "NOT_RUN" : "ERROR";
                output.write("{\"test\":" + quote(result.getName()) + ",\"state\":" + quote(state)
                    + ",\"status\":" + quote(status) + ",\"jvmArgs\":" + quote(String.valueOf(result.getConfig().jvmArgs)) + "}\n");
                count++;
            }
        }
        if (count == 0) throw new IllegalStateException("jcstress produced zero results");
    }
}
