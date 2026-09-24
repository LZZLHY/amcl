import java.nio.*;
import org.lwjgl.stb.STBImageResize;
import org.lwjgl.system.MemoryUtil;

/** Exercises Java descriptors through real JNI; verifies v1 fidelity and v2 coexistence. */
public final class StbCompatTest {
    static void check(boolean value, String detail) { if (!value) throw new AssertionError(detail); }
    static int u(ByteBuffer buffer, int offset) { return buffer.get(offset) & 255; }
    public static void main(String[] args) {
        ByteBuffer input = MemoryUtil.memAlloc(8), output = MemoryUtil.memAlloc(20), modern = MemoryUtil.memAlloc(4);
        try {
            input.put(new byte[]{(byte)255, 0, 0, 0, 0, 0, (byte)255, (byte)255}).flip();
            for (int i = 0; i < 20; i++) output.put(i, (byte)0x5a);
            int ok = STBImageResize.nstbir_resize_uint8(MemoryUtil.memAddress(input), 2, 1, 0,
                MemoryUtil.memAddress(output), 1, 1, 0, 4);
            check(ok == 1, "legacy JNI result");
            check(u(output, 0) > 100 && u(output, 2) > 100 && Math.abs(u(output, 3) - 128) <= 2, "v1 must not alpha-weight RGBA");
            for (int i = 4; i < 20; i++) check(u(output, i) == 0x5a, "output boundary changed");
            long pointer = STBImageResize.nstbir_resize_uint8_linear(MemoryUtil.memAddress(input), 2, 1, 0,
                MemoryUtil.memAddress(modern), 1, 1, 0, STBImageResize.STBIR_RGBA);
            check(pointer == MemoryUtil.memAddress(modern), "modern JNI result");
            check(u(modern, 0) < 5 && u(modern, 2) > 250, "modern alpha semantics must remain intact");
        } finally { MemoryUtil.memFree(input); MemoryUtil.memFree(output); MemoryUtil.memFree(modern); }
        for (int channels : new int[]{1, 2, 3, 4, 5, 8}) {
            int inStride = 2 * channels + 3, outStride = 3 * channels + 5;
            ByteBuffer source = MemoryUtil.memAlloc(inStride * 2 + 7), dest = MemoryUtil.memAlloc(outStride * 3 + 9);
            try {
                for (int i = 0; i < source.capacity(); i++) source.put(i, (byte)0x33);
                for (int y = 0; y < 2; y++) for (int x = 0; x < 2; x++) for (int c = 0; c < channels; c++) source.put(7 + y * inStride + x * channels + c, (byte)(11 + c * 17));
                for (int i = 0; i < dest.capacity(); i++) dest.put(i, (byte)0x5a);
                check(STBImageResize.nstbir_resize_uint8(MemoryUtil.memAddress(source) + 7, 2, 2, inStride,
                    MemoryUtil.memAddress(dest), 3, 3, outStride, channels) == 1, "legacy multi-channel JNI");
                for (int y = 0; y < 3; y++) {
                    for (int x = 0; x < 3; x++) for (int c = 0; c < channels; c++) check(u(dest, y * outStride + x * channels + c) == 11 + c * 17, "stride/ROI/channel semantics");
                    for (int i = 3 * channels; i < outStride; i++) check(u(dest, y * outStride + i) == 0x5a, "row padding changed");
                }
            } finally { MemoryUtil.memFree(source); MemoryUtil.memFree(dest); }
        }
        FloatBuffer floats = MemoryUtil.memAllocFloat(6), resized = MemoryUtil.memAllocFloat(3);
        try {
            floats.put(new float[]{0.125f, 0.25f, 0.5f, 0.125f, 0.25f, 0.5f}).flip();
            check(STBImageResize.stbir_resize_float(floats, 2, 1, 0, resized, 1, 1, 0, 3), "legacy float wrapper");
            check(Math.abs(resized.get(2) - 0.5f) < 0.00001f, "float value");
        } finally { MemoryUtil.memFree(floats); MemoryUtil.memFree(resized); }
        System.out.println("[stb-compat] PASS real JNI: v1/v2 alpha distinction, channels 1/2/3/4/5/8, ROI, stride, bounds, float");
    }
}
