import java.awt.Color;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.GraphicsEnvironment;
import java.awt.font.GlyphVector;
import java.awt.image.BufferedImage;
import java.io.IOException;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.management.CompilationMXBean;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import javax.imageio.ImageIO;

/**
 * 四代 HotSpot 共用的真实 Java 资格夹具；仅使用 Java 8 API 并编译成 class 52。
 * 产物位于 native 提供的独立目录，不读取或修改用户的游戏/JDK 槽。失败立即抛异常，
 * native 仍须调用 DestroyJavaVM；成功不能由 main 返回独自证明，必须同时回读非 daemon
 * 工作与 shutdown hook 的产物。网络、子进程、音频与 GUI 输入另有专项，不由本类代替。
 */
public final class RuntimeQualification {
    private static final String TEXT = "AMCL 中文 \ud83d\ude00";
    private static final Map<String, String> RESULTS = new LinkedHashMap<String, String>();
    private static volatile long blackhole;
    private static volatile byte[] allocation;
    private static Path evidenceRoot;

    private RuntimeQualification() {}

    /** 每项断言失败都保留具体阶段，不把缺失 provider 或原生异常当作可忽略能力。 */
    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    /** 固定 UTF-8、独占新文件并强制落盘，避免复用前次成功文件或仅命中进程内缓存。 */
    private static void save(Path path, String value) throws IOException {
        byte[] data = value.getBytes(StandardCharsets.UTF_8);
        try (FileChannel channel = FileChannel.open(path, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)) {
            ByteBuffer buffer = ByteBuffer.wrap(data);
            while (buffer.hasRemaining()) channel.write(buffer);
            channel.force(true);
        }
    }

    /** 逐项打印并更新唯一结果表；末尾文件中的 passed 只能在全部同步检查完成后写入。 */
    private static void result(String key, Object value) {
        RESULTS.put(key, String.valueOf(value));
        String line = key + "=" + String.valueOf(value).replace("\r", "\\r").replace("\n", "\\n") + "\n";
        System.out.print("QUALIFICATION " + line);
        // 结果不能只在 main 最后落盘：Font 初始化本身可能失败，必须保留失败前的
        // os.name、强制属性、提供者类及已完成的检查。写入均在性能采样区间之外。
        if (evidenceRoot != null) {
            try (FileChannel channel = FileChannel.open(evidenceRoot.resolve("fixture-progress.txt"),
                    StandardOpenOption.WRITE, StandardOpenOption.APPEND)) {
                ByteBuffer bytes = ByteBuffer.wrap(line.getBytes(StandardCharsets.UTF_8));
                while (bytes.hasRemaining()) channel.write(bytes);
                channel.force(true);
            } catch (IOException error) {
                throw new IllegalStateException("cannot persist qualification progress", error);
            }
        }
    }

    /** 反射目标含真实构造、正常调用和目标异常，不能只以成功查到 Class 作为通过。 */
    public static final class ReflectTarget {
        public ReflectTarget() {}
        public String echo(String value) { return value + ":反射"; }
        public void fail() { throw new IllegalStateException("反射异常"); }
    }

    private static void reflectionAndExceptions(Path root) throws Exception {
        Class<?> type = Class.forName("RuntimeQualification$ReflectTarget");
        Object instance = type.getConstructor().newInstance();
        Method echo = type.getMethod("echo", String.class);
        require((TEXT + ":反射").equals(echo.invoke(instance, TEXT)), "reflection result mismatch");
        int caught = 0;
        int completed = 0;
        try {
            type.getMethod("fail").invoke(instance);
        } catch (InvocationTargetException error) {
            require(error.getCause() instanceof IllegalStateException, "reflection cause type");
            require("反射异常".equals(error.getCause().getMessage()), "reflection cause text");
            ++caught;
            StringWriter trace = new StringWriter();
            error.printStackTrace(new PrintWriter(trace));
            require(trace.toString().contains("RuntimeQualification$ReflectTarget.fail"), "exception trace missing frame");
            save(root.resolve("exception.txt"), trace.toString());
        } finally {
            ++completed;
        }
        require(caught == 1 && completed == 1, "exception/finally not delivered exactly once");
        result("reflectionCalls", 2);
        result("exceptionsCaught", caught);
        result("finallyCount", completed);
    }

    /** 八个真实 Java 线程各自多次读写 ThreadLocal，所有线程 join 后验证计数和异常。 */
    private static void threads() throws InterruptedException {
        final ThreadLocal<Integer> local = new ThreadLocal<Integer>();
        final AtomicInteger completed = new AtomicInteger();
        final AtomicReference<Throwable> failed = new AtomicReference<Throwable>();
        Thread[] threads = new Thread[8];
        for (int i = 0; i < threads.length; ++i) {
            final int identity = i;
            threads[i] = new Thread(new Runnable() {
                @Override public void run() {
                    try {
                        require(local.get() == null, "ThreadLocal inherited unrelated value");
                        for (int repeat = 0; repeat < 4096; ++repeat) {
                            int value = identity * 4096 + repeat;
                            local.set(Integer.valueOf(value));
                            if ((repeat & 127) == 0) Thread.yield();
                            require(local.get().intValue() == value, "ThreadLocal crossed thread boundary");
                            completed.incrementAndGet();
                        }
                        local.remove();
                        require(local.get() == null, "ThreadLocal remove did not clear value");
                    } catch (Throwable error) { failed.compareAndSet(null, error); }
                }
            }, "资格线程-" + i);
            threads[i].start();
        }
        for (Thread thread : threads) thread.join();
        if (failed.get() != null) throw new AssertionError("worker failed", failed.get());
        require(completed.get() == 32768 && local.get() == null, "thread operation count mismatch");
        result("threadCount", threads.length);
        result("threadLocalOperations", completed.get());
    }

    /** 方法保持普通优化资格；循环结果流向 volatile，不关闭 C2 或依靠不可观察的空循环。 */
    public static long hotLoop(long seed) {
        long value = seed;
        for (int i = 0; i < 256; ++i) {
            value = value * 2862933555777941757L + 3037000493L;
            value ^= value >>> 21;
        }
        return value;
    }

    private static long gcCount() {
        long count = 0;
        for (GarbageCollectorMXBean collector : ManagementFactory.getGarbageCollectorMXBeans()) {
            long observed = collector.getCollectionCount();
            if (observed >= 0) count += observed;
        }
        return count;
    }

    /** 记录编译器与实测编译耗时，额外 PrintCompilation 原始日志供宿主核验目标方法 C2。 */
    private static void jitAndGc() {
        String info = System.getProperty("java.vm.info", "");
        require(info.contains("mixed mode"), "VM is not in ordinary mixed JIT mode: " + info);
        for (String argument : ManagementFactory.getRuntimeMXBean().getInputArguments()) {
            require(!argument.equals("-Xint") && !argument.startsWith("-XX:TieredStopAtLevel="),
                    "restricted compilation profile: " + argument);
        }
        CompilationMXBean compiler = ManagementFactory.getCompilationMXBean();
        require(compiler != null && compiler.isCompilationTimeMonitoringSupported(), "compilation monitoring unavailable");
        long compileBefore = compiler.getTotalCompilationTime();
        long begin = System.nanoTime();
        long checksum = 0;
        for (int i = 1; i <= 60000; ++i) checksum ^= hotLoop(i);
        blackhole = checksum;
        require(checksum == 678318003988397421L, "JIT checksum mismatch: " + checksum);
        long compileAfter = compiler.getTotalCompilationTime();
        require(compileAfter > 0 && compileAfter >= compileBefore, "compiler did not report executed work");
        long gcBefore = gcCount();
        byte[][] ring = new byte[12][];
        for (int i = 0; i < 192; ++i) {
            byte[] block = new byte[1024 * 1024];
            block[0] = (byte) i;
            block[block.length - 1] = (byte) (i ^ 0x55);
            ring[i % ring.length] = block;
            allocation = block;
        }
        require(ring[11][0] == (byte) 191, "allocated data corruption");
        ring = null;
        allocation = null;
        System.gc();
        long gcAfter = gcCount();
        require(gcAfter > gcBefore, "no completed GC observed");
        result("jitCompiler", compiler.getName());
        result("jitCompileMillisBefore", compileBefore);
        result("jitCompileMillisAfter", compileAfter);
        result("jitLoopCalls", 60000);
        result("jitChecksum", blackhole);
        result("jitAndGcMillis", (System.nanoTime() - begin) / 1000000L);
        result("gcCountBefore", gcBefore);
        result("gcCountAfter", gcAfter);
        result("allocatedBytes", 192L * 1024L * 1024L);
    }

    /** UTF-8 文件名、实际 FileChannel 与目录遍历都经过目标 NIO/native 文件系统实现。 */
    private static void nio(Path root) throws Exception {
        Path name = root.resolve("中文 空格 \ud83d\ude00.txt");
        save(name, TEXT + "\n");
        byte[] expected = (TEXT + "\n").getBytes(StandardCharsets.UTF_8);
        require(Arrays.equals(expected, Files.readAllBytes(name)), "NIO UTF-8 payload mismatch");
        Path renamed = root.resolve("重命名 \ud83d\ude00.txt");
        Files.move(name, renamed);
        require(!Files.exists(name) && Arrays.equals(expected, Files.readAllBytes(renamed)), "NIO rename mismatch");
        boolean found = false;
        try (java.nio.file.DirectoryStream<Path> entries = Files.newDirectoryStream(root)) {
            for (Path item : entries) if (item.getFileName().equals(renamed.getFileName())) found = true;
        }
        require(found, "NIO enumeration lost Unicode name");
        result("nioUtf8Bytes", expected.length);
        result("nioRenameAndEnumerate", true);
    }

    /**
     * 内部类只用于诊断，不提供替代字体实现。目标启动参数已按既有契约开放 sun.font；
     * 非目标宿主若没有模块访问权限，保留明确的诊断失败，普通 public Font 检查仍照常执行。
     */
    private static long fontConfigurationDiagnostics() throws Exception {
        result("fontProperty", System.getProperty("sun.awt.fontconfig", "<unset>"));
        result("fontOsName", System.getProperty("os.name"));
        result("fontUserHome", System.getProperty("user.home"));
        result("fontConfigEnvironment", System.getenv("FONTCONFIG_FILE"));
        String configuration = "<unavailable>";
        long initializationNanos = -1;
        try {
            long begin = System.nanoTime();
            Class<?> factory = Class.forName("sun.font.FontManagerFactory");
            Object manager = factory.getMethod("getInstance").invoke(null);
            initializationNanos = System.nanoTime() - begin;
            result("fontManagerClass", manager.getClass().getName());
            Object config = manager.getClass().getMethod("getFontConfiguration").invoke(manager);
            configuration = config == null ? "<null>" : config.getClass().getName();
            result("fontConfigurationClass", configuration);
        } catch (ReflectiveOperationException error) {
            Throwable cause = error instanceof InvocationTargetException && error.getCause() != null
                    ? error.getCause() : error;
            result("fontConfigurationDiagnosticError", cause.toString());
        }
        // 这条资格通道的 OHOS JDK8 应使用已提供的完整 Fontconfig 回退链，不能在仅中文
        // 样本通过时忽略仍在消费旧 Latin-only properties 的事实。
        if ("1.8".equals(System.getProperty("java.specification.version")) &&
                Boolean.getBoolean("amcl.platform.ohos")) {
            require(System.getProperty("sun.awt.fontconfig") == null, "JDK8 still forces the legacy font properties");
            require("sun.font.FcFontConfiguration".equals(configuration), "JDK8 did not use dynamic Fontconfig: " + configuration);
        }
        return initializationNanos;
    }

    /** 只查看已用过的首 slot，避免为了诊断提前加载全部后备字体而污染冷/热耗时。 */
    private static void primaryFontDiagnostics(Font font) {
        try {
            Class<?> utilities = Class.forName("sun.font.FontUtilities");
            Object composite = utilities.getMethod("getFont2D", Font.class).invoke(null, font);
            result("font2DClass", composite.getClass().getName());
            result("fontFallbackSlots", composite.getClass().getMethod("getNumSlots").invoke(composite));
            Object first = composite.getClass().getMethod("getSlotFont", int.class).invoke(composite, Integer.valueOf(0));
            Class<?> font2D = Class.forName("sun.font.Font2D");
            result("fontPrimaryFamily", font2D.getMethod("getFamilyName", Locale.class).invoke(first, Locale.ROOT));
            result("fontPrimaryName", font2D.getMethod("getFontName", Locale.class).invoke(first, Locale.ROOT));
        } catch (ReflectiveOperationException error) {
            result("fontPrimaryDiagnosticError", error.toString());
        }
    }

    /** 只为资格诊断沿继承链取字段；不改字体对象，也不向产品代码增加反射入口。 */
    private static Object fontField(Object value, String name) throws ReflectiveOperationException {
        for (Class<?> type = value.getClass(); type != null; type = type.getSuperclass()) {
            try {
                Field field = type.getDeclaredField(name);
                field.setAccessible(true);
                return field.get(value);
            } catch (NoSuchFieldException missing) { /* 继续查真正声明该字段的父类。 */ }
        }
        throw new NoSuchFieldException(name);
    }

    /**
     * 冷/热计时后检查粗体两种样式的延迟 slot，保留 Fontconfig 传入的名称/文件与实际
     * 加载结果。字体实例名不被 Java 识别时，默认物理字体替换原脚本字体的现象必须可见。
     * 快照先于 getSlotFont；每个 slot 只初始化一次，不改配置/断言，诊断异常另行留证。
     */
    private static void fallbackSlotDiagnostics() {
        try {
            Class<?> utilities = Class.forName("sun.font.FontUtilities");
            Class<?> font2D = Class.forName("sun.font.Font2D");
            Method fontName = font2D.getMethod("getFontName", Locale.class);
            Method canDisplay = font2D.getMethod("canDisplay", int.class);
            for (int style : new int[] {Font.BOLD, Font.BOLD | Font.ITALIC}) {
                Object composite = utilities.getMethod("getFont2D", Font.class)
                        .invoke(null, new Font(Font.SANS_SERIF, style, 28));
                String[] names = ((String[]) fontField(composite, "componentNames")).clone();
                String[] files = ((String[]) fontField(composite, "componentFileNames")).clone();
                Method slotFont = composite.getClass().getMethod("getSlotFont", int.class);
                int count = ((Integer) composite.getClass().getMethod("getNumSlots").invoke(composite)).intValue();
                int mismatches = 0;
                for (int slot = 0; slot < count; ++slot) {
                    Object loaded = slotFont.invoke(composite, Integer.valueOf(slot));
                    String afterName = String.valueOf(fontName.invoke(loaded, Locale.ROOT));
                    String afterFile = String.valueOf(fontField(loaded, "platName"));
                    boolean differentFile = files[slot] != null && !files[slot].equals(afterFile);
                    if (differentFile) ++mismatches;
                    String descriptor = (String.valueOf(names[slot]) + " " + String.valueOf(files[slot]))
                            .toLowerCase(Locale.ROOT);
                    if (slot == 0 || differentFile || descriptor.contains("hebrew") ||
                            descriptor.contains("devanagari") || descriptor.contains("thai") ||
                            descriptor.contains("arabic") || descriptor.contains("roboto")) {
                        StringBuilder coverage = new StringBuilder();
                        for (int codepoint : new int[] {0x03ac, 0x0629, 0x05e2, 0x0939, 0x0e20}) {
                            coverage.append(" U+").append(Integer.toHexString(codepoint)).append(':')
                                    .append(canDisplay.invoke(loaded, Integer.valueOf(codepoint)));
                        }
                        result("fontSlot." + style + "." + slot, "beforeName=" + names[slot] +
                                "|beforeFile=" + files[slot] + "|afterName=" + afterName +
                                "|afterFile=" + afterFile + "|coverage=" + coverage);
                    }
                }
                result("fontSlotChangedFileCount." + style, mismatches);
            }
            // 系统字体文件名不能代替真实 family。独立读取少量已在设备清单中的文件，
            // 仅记录元数据；缺文件的其它设备明确记录缺席，不影响原覆盖硬断言。
            for (String file : new String[] {"HarmonyOS_Sans.ttf", "Roboto-Regular.ttf", "NotoSerif[wdth,wght].ttf",
                    "NotoSansMono[wdth,wght].ttf", "NotoSansHebrew[wdth,wght].ttf", "NotoSansDevanagariUI-Bold.ttf", "FTToken.ttf"}) {
                Path path = Paths.get("/system/fonts", file);
                if (!Files.isRegularFile(path)) { result("fontFile." + file, "<absent>"); continue; }
                try {
                    Font physical = Font.createFont(Font.TRUETYPE_FONT, path.toFile());
                    result("fontFile." + file, "family=" + physical.getFamily(Locale.ROOT) +
                            "|name=" + physical.getFontName(Locale.ROOT));
                } catch (Exception error) { result("fontFile." + file, error.toString()); }
            }
        } catch (ReflectiveOperationException | RuntimeException error) {
            result("fontSlotDiagnosticError", error.toString());
        }
    }

    /**
     * 对照设备实际枚举的物理字体覆盖能力，检查所有逻辑 face 的回退没有丢失可用脚本。
     * 系统自身未提供的 codepoint 单独计数，不编造“所有语言已通过”；中文仍有独立硬断言。
     * getAllFonts/跨脚本枚举放在冷/热基础采样之后，只影响资格测试，不进入产品热路径。
     */
    private static void logicalFontCoverage() {
        String[] names = {Font.SERIF, Font.SANS_SERIF, Font.MONOSPACED, Font.DIALOG, Font.DIALOG_INPUT};
        Font[] logical = new Font[20];
        int face = 0;
        for (String name : names) {
            for (int style = 0; style < 4; ++style) {
                Font value = new Font(name, style, 28);
                require(value.canDisplayUpTo("AMCL Latin 0123 中文测试") == -1,
                        "logical face lacks Latin/Chinese: " + name + "/" + style);
                logical[face++] = value;
            }
        }
        result("logicalFontFacesChecked", face);
        Font[] physical = GraphicsEnvironment.getLocalGraphicsEnvironment().getAllFonts();
        result("enumeratedFontFaces", physical.length);
        String[] labels = {"latin", "greek", "cyrillic", "arabic", "hebrew", "devanagari", "thai", "japanese", "korean", "chinese", "emoji"};
        String[] texts = {"Àéß", "Ελληνικά", "Привет", "العربية", "עברית", "हिन्दी", "ภาษาไทย", "日本語かなカナ", "한글", "中文測試", "\ud83d\ude00"};
        int compared = 0, missing = 0;
        for (int script = 0; script < texts.length; ++script) {
            int available = 0, absent = 0, scriptMissing = 0;
            StringBuilder missingFaces = new StringBuilder();
            for (int offset = 0; offset < texts[script].length();) {
                int codepoint = texts[script].codePointAt(offset);
                offset += Character.charCount(codepoint);
                boolean supported = false;
                for (Font candidate : physical) {
                    boolean isLogical = false;
                    for (String name : names)
                        if (name.equalsIgnoreCase(candidate.getName()) || name.equalsIgnoreCase(candidate.getFamily(Locale.ROOT)))
                            isLogical = true;
                    if (!isLogical && candidate.canDisplay(codepoint)) { supported = true; break; }
                }
                if (!supported) { ++absent; continue; }
                ++available;
                for (Font value : logical) {
                    if (!value.canDisplay(codepoint)) {
                        ++scriptMissing;
                        missingFaces.append("U+").append(Integer.toHexString(codepoint)).append(' ')
                                .append(value.getName()).append('/').append(value.getStyle()).append(';');
                    }
                    ++compared;
                }
            }
            missing += scriptMissing;
            result("fontCoverage." + labels[script], "physicalAvailable=" + available + ",systemUnavailable=" + absent +
                    ",logicalMissing=" + scriptMissing);
            if (scriptMissing > 0) result("fontMissing." + labels[script], missingFaces);
        }
        require(compared > 0, "physical font comparison did not run");
        result("fontFallbackGlyphComparisons", compared);
        result("fontFallbackMissingGlyphs", missing);
        require(missing == 0, "available physical glyphs missing from logical fallback: " + missing +
                "; see persisted fontMissing.* details");
    }

    /** 使用 JDK 的 Font/字体 fallback、真实字形和 ImageIO 编解码；不是 native FcMatch 的替代品。 */
    private static void fontAndImage(Path root) throws Exception {
        long managerNanos = fontConfigurationDiagnostics();
        long coldStart = System.nanoTime();
        String chinese = "中文测试";
        Font font = new Font(Font.SANS_SERIF, Font.PLAIN, 28);
        require(font.canDisplayUpTo(chinese) == -1, "Java Font cannot display Chinese");
        long coldNanos = System.nanoTime() - coldStart;
        long hotStart = System.nanoTime();
        int hotChecks = 0;
        for (int i = 0; i < 10000; ++i) {
            require(font.canDisplayUpTo("AMCL 中文测试") == -1, "warm logical font lost glyph coverage");
            ++hotChecks;
        }
        long hotNanos = System.nanoTime() - hotStart;
        result("fontManagerInitializationNanos", managerNanos);
        result("fontFirstGlyphLookupNanos", coldNanos);
        result("fontWarmLookupCount", hotChecks);
        result("fontWarmLookupNanos", hotNanos);
        primaryFontDiagnostics(font);
        fallbackSlotDiagnostics();
        logicalFontCoverage();
        BufferedImage image = new BufferedImage(224, 80, BufferedImage.TYPE_INT_ARGB);
        Graphics2D graphics = image.createGraphics();
        int glyphCount;
        try {
            graphics.setColor(Color.WHITE);
            graphics.fillRect(0, 0, image.getWidth(), image.getHeight());
            graphics.setColor(Color.BLACK);
            graphics.setFont(font);
            GlyphVector glyphs = font.createGlyphVector(graphics.getFontRenderContext(), chinese);
            glyphCount = glyphs.getNumGlyphs();
            require(glyphCount == chinese.length(), "Chinese glyph count mismatch");
            for (int i = 0; i < glyphCount; ++i)
                require(glyphs.getGlyphCode(i) != font.getMissingGlyphCode(), "missing Chinese glyph");
            graphics.drawGlyphVector(glyphs, 8, 44);
        } finally { graphics.dispose(); }
        int colored = 0;
        for (int y = 0; y < image.getHeight(); ++y)
            for (int x = 0; x < image.getWidth(); ++x) if (image.getRGB(x, y) != Color.WHITE.getRGB()) ++colored;
        require(colored > 100, "Chinese rendering produced no meaningful pixels");
        Path png = root.resolve("中文图像.png");
        require(!Files.exists(png), "PNG must be a new artifact");
        require(ImageIO.write(image, "png", png.toFile()), "PNG writer unavailable");
        BufferedImage decoded = ImageIO.read(png.toFile());
        require(decoded != null && decoded.getWidth() == image.getWidth() && decoded.getHeight() == image.getHeight(),
                "PNG dimensions mismatch");
        for (int y = 0; y < image.getHeight(); ++y)
            for (int x = 0; x < image.getWidth(); ++x)
                require(decoded.getRGB(x, y) == image.getRGB(x, y), "PNG roundtrip changed pixels");
        result("fontFamily", font.getFamily());
        result("chineseGlyphs", glyphCount);
        result("renderedPixels", colored);
        result("pngBytes", Files.size(png));
        result("pngRoundtripPixels", image.getWidth() * image.getHeight());
    }

    /**
     * main 返回时该非 daemon 线程仍等待 native 专属 gate。只有 native 准备进入 Destroy
     * 才创建 gate；hook 又必须看见 worker 的完整文件，三者共同证明顺序与生命周期。
     */
    private static void completion(final Path root, final String token) {
        final Thread originalMain = Thread.currentThread();
        result("mainThreadJoinRequired", true);
        final Thread worker = new Thread(new Runnable() {
            @Override public void run() {
                try {
                    while (!Files.exists(root.resolve("destroy-started.txt"))) Thread.sleep(5);
                    // 真正等待执行main的Java线程结束，不能仅以native创建文件代替线程生命周期。
                    // launcher须先Detach再Destroy；旧顺序会被父侧期限拒绝而非伪造完成。
                    originalMain.join();
                    require(!originalMain.isAlive(), "original main identity did not end");
                    save(root.resolve("main-thread-ended.txt"), token);
                    save(root.resolve("non-daemon.txt"), token);
                } catch (Throwable error) { error.printStackTrace(); }
            }
        }, "qualification-non-daemon");
        worker.setDaemon(false);
        Runtime.getRuntime().addShutdownHook(new Thread(new Runnable() {
            @Override public void run() {
                try {
                    require(token.equals(new String(Files.readAllBytes(root.resolve("non-daemon.txt")),
                            StandardCharsets.UTF_8)), "shutdown hook ran before non-daemon completed");
                    save(root.resolve("shutdown-hook.txt"), token);
                } catch (Throwable error) { error.printStackTrace(); }
            }
        }, "qualification-shutdown-hook"));
        worker.start();
    }

    /** Native 传入：结果目录、预期 major、经过 UTF-8→MUTF-8 JNI 的原始字符串。 */
    public static void main(String[] args) throws Exception {
        require(args.length == 3, "expected output directory, major, Unicode argument");
        Path root = Paths.get(args[0]);
        require(root.isAbsolute() && Files.isDirectory(root), "invalid dedicated output root");
        save(root.resolve("fixture-progress.txt"), "schema=2\n");
        evidenceRoot = root;
        require(TEXT.equals(args[2]), "JNI Unicode argument mismatch");
        String specification = System.getProperty("java.specification.version");
        String major = specification.startsWith("1.") ? specification.substring(2) : specification;
        require(args[1].equals(major), "wrong candidate VM: expected=" + args[1] + " actual=" + specification);
        result("specificationVersion", specification);
        result("runtimeVersion", System.getProperty("java.runtime.version"));
        result("vmName", System.getProperty("java.vm.name"));
        result("vmInfo", System.getProperty("java.vm.info"));
        result("javaHome", System.getProperty("java.home"));
        result("vmArguments", ManagementFactory.getRuntimeMXBean().getInputArguments());
        result("unicode", args[2]);
        reflectionAndExceptions(root);
        threads();
        nio(root);
        jitAndGc();
        fontAndImage(root);
        String token = "AMCL-JAVA-QUALIFICATION:1:" + major + "\n";
        completion(root, token);
        result("synchronousChecksPassed", true);
        StringBuilder values = new StringBuilder();
        for (Map.Entry<String, String> entry : RESULTS.entrySet())
            values.append(entry.getKey()).append('=').append(entry.getValue()).append('\n');
        save(root.resolve("fixture-results.txt"), values.toString());
        save(root.resolve("fixture-pass.txt"), token);
    }
}
