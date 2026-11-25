import java.nio.ByteBuffer;
import java.nio.IntBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.HexFormat;
import java.util.concurrent.FutureTask;
import org.lwjgl.nanovg.NSVGImage;
import org.lwjgl.nanovg.NanoSVG;
import org.lwjgl.stb.STBImage;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.system.MemoryUtil.MemoryAllocator;
import org.lwjgl.system.SharedLibrary;
import org.lwjgl.util.spng.SPNG;

/** 在独立 JVM 中运行真实 Java/native 显式内存与图像编解码回调，只访问分配范围。 */
public final class AllocatorDeviceCheck {
    // 1x1 RGBA PNG，解码后应为 11 22 33 FF；同一输入供两个独立库读取。
    private static final byte[] PNG = Base64.getDecoder().decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQVDL+DwACFAFmBODefwAAAABJRU5ErkJggg==");

    private static void check(boolean ok, String detail) {
        if (!ok) throw new AssertionError(detail);
    }

    /** 校验真实加载文件的 SHA 和六个回调。期望 SHA 由宿主从对应的可信 HAP 或原件取得。 */
    private static void verifyAllocator(String[] args) throws Exception {
        MemoryAllocator allocator = MemoryUtil.getAllocator();
        String actual = allocator.getClass().getName();
        System.out.println("allocator=" + actual);
        if (args[0].equals("system")) {
            check(args.length == 1, "system takes no native digest");
            check(actual.equals("org.lwjgl.system.MemoryManage$StdlibAllocator"), "system allocator");
            return;
        }
        check(args.length == 2 && args[0].equals("jemalloc") && args[1].matches("[0-9a-f]{64}"),
            "expected jemalloc and trusted SHA-256");
        check(actual.equals("org.lwjgl.system.jemalloc.JEmalloc$Allocator"), "jemalloc not selected");
        Class<?> binding = Class.forName("org.lwjgl.system.jemalloc.JEmalloc");
        SharedLibrary lib = (SharedLibrary) binding.getMethod("getLibrary").invoke(null);
        String[] names = {"je_malloc", "je_calloc", "je_realloc", "je_free", "je_aligned_alloc", "je_free"};
        long[] functions = {allocator.getMalloc(), allocator.getCalloc(), allocator.getRealloc(), allocator.getFree(),
            allocator.getAlignedAlloc(), allocator.getAlignedFree()};
        for (int i = 0; i < names.length; i++) {
            check(functions[i] != 0 && lib.getFunctionAddress(names[i]) == functions[i], "callback " + names[i]);
        }
        // getPath 查询已装入的 SharedLibrary，不能用 JVM 配置里请求的路径代替实取路径。
        String loaded = lib.getPath();
        check(loaded != null && Path.of(loaded).isAbsolute(), "loaded allocator file path unavailable");
        Path path = Path.of(loaded).toRealPath();
        String sha = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(path)));
        System.out.println("callbackOwner=" + path + " sha256=" + sha + " verified=" + functions.length);
        check(sha.equals(args[1]), "loaded allocator SHA-256 mismatch");
    }

    /** 对齐块使用配对的释放器。交给另一个线程的块只有接收方可以重分配和释放。 */
    private static void checkOwnership() throws Exception {
        long aligned = MemoryUtil.nmemAlignedAllocChecked(64, 256);
        try {
            check((aligned & 63) == 0, "64-byte alignment");
            MemoryUtil.memPutInt(aligned + 252, 0x12345678);
            check(MemoryUtil.memGetInt(aligned + 252) == 0x12345678, "aligned contents");
        } finally {
            MemoryUtil.nmemAlignedFree(aligned);
        }
        long block = MemoryUtil.nmemCallocChecked(8, 16);
        long sum = 0;
        for (int i = 0; i < 128; i++) sum += MemoryUtil.memGetByte(block + i) & 255;
        if (sum != 0) {
            MemoryUtil.nmemFree(block);
            throw new AssertionError("calloc contents");
        }
        MemoryUtil.memPutLong(block, 0x123456789abcdef0L);
        FutureTask<Void> consumer = new FutureTask<>(() -> {
            long owned = block;
            try {
                long resized = MemoryUtil.nmemRealloc(owned, 512);
                check(resized != 0, "cross-thread realloc");
                owned = resized;
                check(MemoryUtil.memGetLong(owned) == 0x123456789abcdef0L, "realloc contents");
                MemoryUtil.memPutInt(owned + 508, 123);
                check(MemoryUtil.memGetInt(owned + 508) == 123, "realloc last int");
            } finally {
                MemoryUtil.nmemFree(owned);
            }
            return null;
        });
        Thread worker = new Thread(consumer, "allocator-check");
        worker.start();
        worker.join();
        consumer.get();
    }

    private static void verifyPixel(ByteBuffer rgba) {
        check(rgba != null && rgba.remaining() == 4 && rgba.get(0) == 17 && rgba.get(1) == 34
            && rgba.get(2) == 51 && (rgba.get(3) & 255) == 255, "decoded RGBA");
    }

    /** STB 自己释放输出，SPNG 自己释放 context。调用方只释放自己提供的输入/输出。 */
    private static void checkDecoders() {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            ByteBuffer png = stack.malloc(PNG.length).put(PNG).flip();
            IntBuffer x = stack.mallocInt(1), y = stack.mallocInt(1), channels = stack.mallocInt(1);
            ByteBuffer pixels = STBImage.stbi_load_from_memory(png, x, y, channels, 4);
            try {
                verifyPixel(pixels);
                check(x.get(0) == 1 && y.get(0) == 1 && channels.get(0) == 4, "STB dimensions");
            } finally {
                if (pixels != null) STBImage.stbi_image_free(pixels);
            }
            long ctx = SPNG.spng_ctx_new(0);
            check(ctx != 0, "SPNG context");
            try {
                check(SPNG.spng_set_png_buffer(ctx, png) == 0, "SPNG input");
                ByteBuffer out = stack.malloc(4);
                check(SPNG.spng_decode_image(ctx, out, SPNG.SPNG_FMT_RGBA8, 0) == 0, "SPNG decode");
                verifyPixel(out);
            } finally {
                SPNG.spng_ctx_free(ctx);
            }
        }
    }

    /** NanoSVG 属于实际交付的 NanoVG JNI，栅格化不要求窗口或 GL 上下文。 */
    private static void checkSvg() {
        String svg = "<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'>" +
            "<rect width='8' height='8' fill='#112233'/></svg>";
        NSVGImage image = NanoSVG.nsvgParse(svg, "px", 96f);
        check(image != null, "NanoSVG parse");
        try {
            long raster = NanoSVG.nsvgCreateRasterizer();
            check(raster != 0, "NanoSVG rasterizer");
            try (MemoryStack stack = MemoryStack.stackPush()) {
                ByteBuffer out = stack.malloc(8 * 8 * 4);
                NanoSVG.nsvgRasterize(raster, image, 0f, 0f, 1f, out, 8, 8, 8 * 4);
                int center = 4 * (8 * 4 + 4);
                verifyPixel(out.position(center).limit(center + 4).slice());
            } finally {
                NanoSVG.nsvgDeleteRasterizer(raster);
            }
        } finally {
            NanoSVG.nsvgDelete(image);
        }
    }

    public static void main(String[] args) throws Exception {
        check(args.length >= 1, "expected allocator mode");
        verifyAllocator(args);
        checkOwnership();
        checkDecoders();
        checkSvg();
        System.out.println("PASS ownership alignment reallocation STB SPNG NanoSVG");
    }
}
