package com.amcl.qa;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.util.Arrays;

/**
 * 游戏默认临时目录的Java8真机回归：使用没有目录参数的两种createTempFile API，
 * 将真实内容移动到实例目录，再由shutdown hook重复一次。它不改变文件系统权限，
 * 不把私有→公共显式COPY_ATTRIBUTES的失败当成应消除的问题。
 */
public final class GameTempMoveProbe {
    private static final byte[] DATA = "AMCL-default-temp-中文-0123456789".getBytes(StandardCharsets.UTF_8);

    /** 输出仅包含本次参数、身份与断言结果；手工escape保证独立JSON行可完整读回。 */
    private static String quote(String value) {
        return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"")
            .replace("\r", "\\r").replace("\n", "\\n") + "\"";
    }
    private static void require(boolean condition, String detail) {
        if (!condition) throw new AssertionError(detail);
    }
    /** 摘要以真实读回字节计算，不能只看文件存在或move返回。 */
    private static String hash(byte[] bytes) throws Exception {
        StringBuilder value = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(bytes)) value.append(String.format("%02x", b & 255));
        return value.toString();
    }
    /** 调用方保证dest目录为本轮独占；source由系统默认temp API新建，不复制旧样本。 */
    private static void transfer(String kind, Path source, Path expectedTemp, Path output) throws Exception {
        require(Files.isSameFile(source.getParent(), expectedTemp), "default temp did not use the selected game root: " + source);
        Files.write(source, DATA, StandardOpenOption.TRUNCATE_EXISTING);
        String before = hash(Files.readAllBytes(source));
        Path target = output.resolve(kind + ".bin");
        Files.move(source, target);
        byte[] actual = Files.readAllBytes(target);
        require(Arrays.equals(actual, DATA) && hash(actual).equals(before), "move changed payload: " + kind);
        require(!Files.exists(source), "move left source behind: " + kind);
        System.out.println("{\"event\":\"moved\",\"kind\":" + quote(kind) + ",\"sha256\":" + quote(before) +
            ",\"sourceGone\":true,\"defaultParent\":" + quote(source.getParent().toString()) + "}");
        System.out.flush();
    }
    /**
     * 参数为已核gameDir、真实app filesDir、唯一nonce；只额外接纳启动器固定的窗口尾参。
     * main成功并不算hook通过，调用方必须回收complete.json及明确的shutdown日志。
     */
    public static void main(String[] args) throws Exception {
        require(args.length == 3 || args.length == 7, "gameDir appFilesDir nonce [--width n --height n]");
        require(args[2].matches("[a-z0-9-]{1,48}"), "unsafe nonce");
        if (args.length == 7) {
            require(args[3].equals("--width") && args[5].equals("--height"), "unknown launcher tail");
            require(Integer.parseInt(args[4]) > 0 && Integer.parseInt(args[6]) > 0, "invalid window dimensions");
        }
        final Path game = Paths.get(args[0]).toRealPath();
        final Path privateRoot = Paths.get(args[1]).toRealPath();
        final Path temp = Paths.get(System.getProperty("java.io.tmpdir")).toRealPath();
        final String nativeValue = System.getenv("TMPDIR");
        require(nativeValue != null && !nativeValue.isEmpty(), "native TMPDIR missing");
        final Path nativeTemp = Paths.get(nativeValue).toRealPath();
        System.out.println("{\"event\":\"begin\",\"javaVersion\":" + quote(System.getProperty("java.version")) +
            ",\"javaTmp\":" + quote(temp.toString()) + ",\"nativeTmp\":" + quote(nativeTemp.toString()) + "}");
        require(temp.startsWith(game) && !temp.equals(game), "Java temp is not inside the instance");
        require(Files.isSameFile(temp, game.resolve(".amcl/java-tmp")), "Java temp default path differs");
        require(nativeTemp.startsWith(privateRoot) && !nativeTemp.equals(privateRoot), "native TMPDIR left private root");
        require(!Files.isSameFile(temp, nativeTemp), "Java temp and native TMPDIR must remain independent");
        final Path output = game.resolve(".amcl/temp-regression-" + args[2]);
        Files.createDirectory(output);
        transfer("nio", Files.createTempFile("amcl-nio-", ".tmp"), temp, output);
        transfer("io", File.createTempFile("amcl-io-", ".tmp").toPath(), temp, output);
        final Path pending = Files.createTempFile("amcl-hook-", ".tmp");
        Files.write(pending, DATA, StandardOpenOption.TRUNCATE_EXISTING);
        Runtime.getRuntime().addShutdownHook(new Thread(new Runnable() {
            public void run() {
                try {
                    require(Arrays.equals(Files.readAllBytes(pending), DATA), "host removed temp before shutdown hook");
                    transfer("shutdown", pending, temp, output);
                    String complete = "{\"protocol\":\"AMCL_GAME_JAVA_TEMP_V1\",\"passed\":true,\"operations\":3,\"nativeTmpPrivate\":true}\n";
                    Files.write(output.resolve("complete.json"), complete.getBytes(StandardCharsets.UTF_8), StandardOpenOption.CREATE_NEW);
                    System.out.println(complete.trim()); System.out.flush();
                } catch (Throwable failure) {
                    failure.printStackTrace(); System.out.println("AMCL_GAME_JAVA_TEMP_HOOK_FAILED"); System.out.flush();
                }
            }
        }, "amcl-temp-shutdown-probe"));
        // 真实System.exit触发Java hook，再交给既有VM退出协议；不用宿主force-stop模拟完成。
        System.exit(0);
    }
}
