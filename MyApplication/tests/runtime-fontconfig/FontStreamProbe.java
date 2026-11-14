import java.nio.ByteBuffer;

/** 真实JNI调用实际上游/候选读桥；Reader只控制读取结果和故障，不替换被测试的native决策。 */
public final class FontStreamProbe {
    private static native long exercise(Reader reader, int mode);
    private static native long last();
    private static native void invalidate(Scaler scaler, Throwable prior);
    private static void require(boolean value, String label) { if (!value) throw new AssertionError(label); }
    public static final class Scaler {
        long nativeScaler = 123;
        final IllegalArgumentException invalidation = new IllegalArgumentException("controlled-scaler-invalidation");
        public void invalidateScaler() { nativeScaler = 0; throw invalidation; }
    }
    public static final class Reader {
        final int mode;
        final Throwable marker;
        int calls, byteCalls;
        Reader(int mode) {
            this.mode = mode;
            marker = mode == 3 ? new OutOfMemoryError("controlled-direct-buffer-OOM") : new IllegalStateException("controlled-font-read-error");
        }
        public int readBlock(ByteBuffer buffer, int offset, int length) {
            ++calls;
            if (mode == 4 || mode == 10) throw (RuntimeException) marker;
            if (mode == 7) return -1;
            if (mode == 8) return length + 1;
            int count = mode == 6 ? Math.min(17, length) : length;
            for (int at = 0; at < count; ++at) buffer.put(at, (byte)(offset + at));
            return count;
        }
        public byte[] readBytes(int offset, int length) {
            ++byteCalls;
            if (mode == 5) throw (RuntimeException) marker;
            byte[] bytes = new byte[length];
            for (int at = 0; at < length; ++at) bytes[at] = (byte)(offset + at);
            return bytes;
        }
    }
    public static void main(String[] args) {
        System.load(args[0]);
        boolean fixed = Boolean.parseBoolean(args[1]);
        boolean modern = args[2].equals("21") || args[2].equals("25");
        int cases = 0;
        for (int mode = 0; mode <= 10; ++mode) {
            // 原码的这三种 pending→Java 违规可能导致VM直接终止；原负控已由正常读的
            // CheckJNI警告、短读缓存错误及readBlock异常语义独立验证，不把任意崩溃算通过。
            if (!fixed && (mode == 3 || mode == 5 || mode == 9 || mode == 10)) continue;
            Reader reader = new Reader(mode);
            Throwable caught = null;
            try { exercise(reader, mode); } catch (Throwable error) { caught = error; }
            long state = last();
            int first = (int)(state & 0xffffL), second = (int)((state >>> 16) & 0xffffL);
            int cacheLength = (int)((state >>> 32) & 0xffffL);
            boolean noHotJni = (state & (1L << 48)) != 0, correctTail = (state & (1L << 49)) != 0;
            if (mode == 0) require(caught == null && first == 64 && second == 16 && reader.calls == 1 && noHotJni, "ordinary cache-hit");
            if (mode == 1) require(caught == null && first == 2048 && reader.calls == 1, "large direct read");
            if (mode == 2) require(caught == null && first == 2048 && reader.byteCalls == 1 && reader.calls == 0, "array fallback preserved");
            if (mode == 6) require(caught == null && first == 17 && second == 16 &&
                    (fixed ? cacheLength == 17 && reader.calls == 2 && correctTail : reader.calls == 1 && !correctTail), "short-read valid cache");
            if (mode == 7 || mode == 8) require(caught == null &&
                    (fixed ? first == 0 && second == 0 && cacheLength == 0 : second == 16 && cacheLength == 1024), "invalid-read cache unpublished");
            if (mode == 4) {
                require(fixed || !modern ? caught == reader.marker : caught == null, "same first exception identity");
                require(fixed ? second == 0 && cacheLength == 0 && reader.calls == 1 : second == 16, "exception read cannot be cache hit");
            }
            if (fixed && (mode == 3 || mode == 5 || mode == 9 || mode == 10))
                require(caught == reader.marker && first == 0 && cacheLength == 0, "failure boundary " + mode);
            ++cases;
        }
        for (boolean withPrior : new boolean[] { false, true }) {
            Scaler scaler = new Scaler();
            Throwable prior = withPrior ? new IllegalStateException("first-read-failure") : null;
            Throwable caught = null;
            try { invalidate(scaler, prior); } catch (Throwable error) { caught = error; }
            require(scaler.nativeScaler == 0 && last() == 1, "native pointer invalidated and resources released once");
            require(caught == (fixed && withPrior ? prior : scaler.invalidation), "invalidation first-error identity");
            ++cases;
        }
        System.out.println("PASS real JNI font stream " + (fixed ? "repaired" : "original-negative-control") + " major=" + args[2] + " cases=" + cases);
    }
}
