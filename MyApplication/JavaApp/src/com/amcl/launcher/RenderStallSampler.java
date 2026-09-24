package com.amcl.launcher;

import java.util.Arrays;
import java.util.Locale;

/**
 * Names the code that holds the render thread still during a stall.
 *
 * <p>Motivation (2026-08-27): boundary-crossing hitches show up in the native
 * frame telemetry as 150ms–1.2s windows in which the render thread issues no
 * GL call at all. GC, fence waits and the chunk-upload paths are individually
 * instrumented and excluded; what remains is "some Java code or lock", and the
 * device forbids kernel-side sampling (hiperf tracepoints return zero samples
 * for the shell user). This sampler is the zero-permission replacement: a
 * daemon thread polls the render thread's stack at 10ms; when the top frames
 * stay identical for at least 150ms, it prints one [AMCL-RENDER-STALL] record
 * with the full stack and the observed duration.</p>
 *
 * <p>Sampling one thread at 100Hz costs microseconds per tick and allocates
 * only during stalls, so the observer cannot manufacture the pauses it is
 * looking for. A moving stack (busy loop) is reported too, keyed by its
 * dominant top frame, because a 300ms on-CPU tick burst is as much a stall as
 * a parked lock wait; the two print with different `kind` values.</p>
 */
public final class RenderStallSampler {
    private static final long SAMPLE_INTERVAL_MS = 10L;
    private static final long REPORT_THRESHOLD_MS = 150L;
    private static final int TOP_FRAMES_COMPARED = 4;
    private static final int MAX_STACK_LINES = 44;
    private static final int MAX_REPORTS = 200;
    private static final long MIN_REPORT_GAP_MS = 500L;

    private RenderStallSampler() {}

    /** Installs the sampler against {@code target}; call before MC main. */
    public static void install(final Thread target) {
        if (!Boolean.parseBoolean(System.getProperty("amcl.renderStallSampler", "false"))) {
            return;
        }
        Thread sampler = new Thread(new Runnable() {
            public void run() { sample(target); }
        }, "AMCL-RenderStallSampler");
        sampler.setDaemon(true);
        sampler.setPriority(Thread.NORM_PRIORITY);
        sampler.start();
        System.out.println("[AMCL-RENDER-STALL] schema=1 status=active interval_ms="
            + SAMPLE_INTERVAL_MS + " threshold_ms=" + REPORT_THRESHOLD_MS
            + " target=" + target.getName());
    }

    private static void sample(Thread target) {
        StackTraceElement[] streakStack = null;
        long streakStartNs = 0L;
        boolean streakReported = false;
        long lastReportNs = 0L;
        int reports = 0;

        // Busy-stall attribution: a stall whose stack keeps moving (on-CPU
        // work) never produces a 150ms-identical streak, so the first field
        // session caught only parked launch-phase stalls and stayed silent
        // in-world. Aggregate instead: every sample charges the first
        // game-owned frame (net.minecraft / com.mojang), and once per second
        // the dominant frames are printed with their share. Offline these
        // [AMCL-RENDER-HOT] lines join the native slow-frame telemetry by
        // hilog timestamp.
        java.util.HashMap<String, Integer> attribution =
            new java.util.HashMap<String, Integer>();
        long windowStartNs = System.nanoTime();
        int windowSamples = 0;

        while (target.isAlive() && !Thread.currentThread().isInterrupted()) {
            try {
                Thread.sleep(SAMPLE_INTERVAL_MS);
            } catch (InterruptedException interrupted) {
                return;
            }
            long now = System.nanoTime();
            StackTraceElement[] stack;
            try {
                stack = target.getStackTrace();
            } catch (Throwable failure) {
                return; // diagnostics must never break the game
            }
            if (stack.length == 0) { // thread between frames of existence
                streakStack = null;
                continue;
            }

            windowSamples++;
            String frame = attributionFrame(stack);
            Integer seen = attribution.get(frame);
            attribution.put(frame, seen == null ? 1 : (seen.intValue() + 1));
            if (now - windowStartNs >= 1_000_000_000L) {
                printHotWindow(attribution, windowSamples,
                    (now - windowStartNs) / 1_000_000L);
                attribution.clear();
                windowSamples = 0;
                windowStartNs = now;
            }

            if (reports < MAX_REPORTS) {
                if (streakStack != null && sameTop(streakStack, stack)) {
                    long heldMs = (now - streakStartNs) / 1_000_000L;
                    if (!streakReported && heldMs >= REPORT_THRESHOLD_MS
                            && (now - lastReportNs) / 1_000_000L >= MIN_REPORT_GAP_MS) {
                        streakReported = true;
                        lastReportNs = now;
                        reports++;
                        print(stack, heldMs, reports);
                    }
                } else {
                    streakStack = stack;
                    streakStartNs = now;
                    streakReported = false;
                }
            }
        }
    }

    /** First game-owned frame; JDK/LWJGL plumbing frames attribute poorly. */
    private static String attributionFrame(StackTraceElement[] stack) {
        for (int i = 0; i < stack.length; i++) {
            String owner = stack[i].getClassName();
            if (owner.startsWith("net.minecraft") || owner.startsWith("com.mojang")) {
                return stack[i].toString();
            }
        }
        return stack[0].toString();
    }

    private static void printHotWindow(java.util.HashMap<String, Integer> attribution,
                                       int samples, long windowMs) {
        if (samples < 20) return; // thread mostly gone/asleep; shares would lie
        String[] topFrame = new String[3];
        int[] topCount = new int[3];
        for (java.util.Map.Entry<String, Integer> entry : attribution.entrySet()) {
            int count = entry.getValue().intValue();
            for (int slot = 0; slot < 3; slot++) {
                if (count > topCount[slot]) {
                    for (int shift = 2; shift > slot; shift--) {
                        topCount[shift] = topCount[shift - 1];
                        topFrame[shift] = topFrame[shift - 1];
                    }
                    topCount[slot] = count;
                    topFrame[slot] = entry.getKey();
                    break;
                }
            }
        }
        StringBuilder text = new StringBuilder(512);
        text.append("[AMCL-RENDER-HOT] schema=1 window_ms=").append(windowMs)
            .append(" samples=").append(samples)
            .append(" distinct=").append(attribution.size());
        for (int slot = 0; slot < 3 && topFrame[slot] != null; slot++) {
            text.append(" top").append(slot + 1).append('=')
                .append(String.format(Locale.ROOT, "%d%%", topCount[slot] * 100 / samples))
                .append(':').append(topFrame[slot]);
        }
        System.out.println(text);
    }

    private static boolean sameTop(StackTraceElement[] left, StackTraceElement[] right) {
        int frames = Math.min(TOP_FRAMES_COMPARED, Math.min(left.length, right.length));
        for (int i = 0; i < frames; i++) {
            if (!left[i].equals(right[i])) return false;
        }
        return true;
    }

    private static void print(StackTraceElement[] stack, long heldMs, int index) {
        StringBuilder text = new StringBuilder(2048);
        text.append("[AMCL-RENDER-STALL] schema=1 kind=stall index=").append(index)
            .append(" held_ms>=").append(String.format(Locale.ROOT, "%d", heldMs))
            .append(" top=").append(stack[0]).append('\n');
        int lines = Math.min(stack.length, MAX_STACK_LINES);
        for (int i = 0; i < lines; i++) {
            text.append("    at ").append(stack[i]).append('\n');
        }
        if (lines < stack.length) {
            text.append("    ... ").append(stack.length - lines).append(" more\n");
        }
        System.out.print(text);
    }

    static long thresholdMsForTests() { return REPORT_THRESHOLD_MS; }

    static boolean sameTopForTests(StackTraceElement[] a, StackTraceElement[] b) {
        return sameTop(a, b);
    }

    static String printableForTests(StackTraceElement[] stack) {
        return Arrays.toString(stack);
    }
}
