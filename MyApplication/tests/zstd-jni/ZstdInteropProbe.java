package com.amcl.qa;

import com.github.luben.zstd.*;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicReference;

/**
 * 使用原发布者Java类调用真实JNI的class52夹具。构建器仅替换标准/DH导入前缀，测试代码
 * 两边相同。覆盖数组、上下文、stream、两种buffer stream、字典训练/释放和并发往返；
 * 不执行Minecraft，不把通过升级为DH世界或其他版本的资格。
 */
public final class ZstdInteropProbe {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    /** 结构与非重复字节混合，避免全零样本掩盖偏移、长度或错误字典问题。 */
    private static byte[] data(int size, int seed) {
        byte[] bytes = new byte[size]; int state = seed;
        for (int i = 0; i < size; i++) {
            state = state * 1664525 + 1013904223;
            bytes[i] = (byte) ((i % 5 == 0) ? state >>> 24 : (i / 13 + seed) % 47);
        }
        return bytes;
    }
    /** 完整内容比较同时核对长度，不以“native调用未抛异常”作为往返通过。 */
    private static void equal(byte[] wanted, byte[] actual, String label) {
        check(Arrays.equals(wanted, actual), label + " data mismatch");
    }
    /** 取buffer当前有效区，不读取capacity尾部未写入数据。 */
    private static byte[] bytes(ByteBuffer value) {
        byte[] bytes = new byte[value.remaining()]; value.get(bytes); return bytes;
    }
    private static void arraysAndDirect(int seed) {
        byte[] source = data(16384, seed), packed = Zstd.compress(source, 3);
        equal(source, Zstd.decompress(packed, source.length), "array");
        ByteBuffer input = ByteBuffer.allocateDirect(source.length); input.put(source); input.flip();
        ByteBuffer compressed = Zstd.compress(input, 3);
        equal(source, bytes(Zstd.decompress(compressed, source.length)), "direct");
    }
    /** 每次调用独立创建/关闭真实native上下文，返回对象必须属于当前绑定的ClassLoader。 */
    private static void contexts(byte[] source) {
        try (ZstdCompressCtx compress = new ZstdCompressCtx(); ZstdDecompressCtx decompress = new ZstdDecompressCtx()) {
            compress.setLevel(3).setWorkers(2);
            byte[] packed = compress.compress(source);
            equal(source, decompress.decompress(packed, source.length), "context");
            ZstdFrameProgression progress = compress.getFrameProgression();
            check(progress != null && progress.getClass().getClassLoader() == Zstd.class.getClassLoader(), "frame progression class ownership");
        }
    }
    /** 标准流触发srcPos/dstPos字段路径，close必须真实完成压缩和资源释放。 */
    private static void streams(byte[] source) throws Exception {
        ByteArrayOutputStream target = new ByteArrayOutputStream();
        try (ZstdOutputStream stream = new ZstdOutputStream(target, 3)) {
            stream.setWorkers(2); stream.write(source, 0, 7000); stream.write(source, 7000, source.length - 7000);
        }
        ByteArrayOutputStream restored = new ByteArrayOutputStream();
        try (ZstdInputStream stream = new ZstdInputStream(new ByteArrayInputStream(target.toByteArray()))) {
            byte[] block = new byte[997]; int count;
            while ((count = stream.read(block)) != -1) { check(count > 0, "stream progress"); restored.write(block, 0, count); }
        }
        equal(source, restored.toByteArray(), "stream");
    }
    /** direct与heap buffer stream分别触发两套consumed/produced字段缓存。 */
    private static void bufferStreams(byte[] source) throws Exception {
        ByteBuffer packed = ByteBuffer.allocateDirect(source.length * 2 + 1024);
        ByteBuffer input = ByteBuffer.allocateDirect(source.length); input.put(source); input.flip();
        try (ZstdDirectBufferCompressingStream stream = new ZstdDirectBufferCompressingStream(packed, 3)) { stream.compress(input); }
        packed.flip(); byte[] encoded = bytes(packed.duplicate());
        ByteBuffer restored = ByteBuffer.allocateDirect(source.length);
        try (ZstdDirectBufferDecompressingStream stream = new ZstdDirectBufferDecompressingStream(packed)) {
            while (stream.hasRemaining()) check(stream.read(restored) > 0, "direct stream progress");
        }
        restored.flip(); equal(source, bytes(restored), "direct stream");
        ByteBuffer heap = ByteBuffer.allocate(source.length);
        try (ZstdBufferDecompressingStream stream = new ZstdBufferDecompressingStream(ByteBuffer.wrap(encoded))) {
            while (stream.hasRemaining()) check(stream.read(heap) > 0, "heap stream progress");
        }
        heap.flip(); equal(source, bytes(heap), "heap stream");
    }
    /** 使用真实字典训练器和fast-dict JNI，覆盖qsort上下文适配及nativePtr字段生命周期。 */
    private static void dictionary(byte[] source) throws Exception {
        byte[][] samples = new byte[64][];
        for (int i = 0; i < samples.length; i++) samples[i] = data(2048, i + 11);
        byte[] buffer = new byte[4096]; long length = Zstd.trainFromBuffer(samples, buffer);
        check(!Zstd.isError(length) && length > 0 && length <= buffer.length, "dictionary training");
        byte[] dictionary = Arrays.copyOf(buffer, (int) length);
        try (ZstdDictCompress compress = new ZstdDictCompress(dictionary, 3); ZstdDictDecompress decompress = new ZstdDictDecompress(dictionary)) {
            equal(source, Zstd.decompress(Zstd.compress(source, compress), decompress, source.length), "fast dictionary");
            try (ZstdCompressCtx cc = new ZstdCompressCtx(); ZstdDecompressCtx dc = new ZstdDecompressCtx()) {
                cc.loadDict(compress); dc.loadDict(decompress);
                equal(source, dc.decompress(cc.compress(source), source.length), "dictionary context");
            }
        }
    }
    /** 可由隔离ClassLoader交替调用，不退出宿主；失败直接向调用者传播。 */
    public static String run() throws Exception {
        byte[] source = data(32768, 7);
        arraysAndDirect(1); contexts(source); streams(source); bufferStreams(source); dictionary(source);
        AtomicReference<Throwable> failure = new AtomicReference<Throwable>(); Thread[] threads = new Thread[4];
        for (int i = 0; i < threads.length; i++) {
            final int seed = i + 31;
            threads[i] = new Thread(new Runnable() { public void run() {
                try { for (int round = 0; round < 24; round++) arraysAndDirect(seed + round); }
                catch (Throwable error) { failure.compareAndSet(null, error); }
            } }, "AMCL-Zstd-Probe-" + i); threads[i].start();
        }
        for (Thread thread : threads) thread.join();
        if (failure.get() != null) throw new AssertionError("concurrent zstd roundtrip", failure.get());
        return "AMCL_ZSTD_INTEROP passed=true namespace=" + Zstd.class.getName() + " concurrentRoundtrips=96";
    }
    public static void main(String[] args) throws Exception {
        System.out.println(run());
        System.exit(0);
    }
}
