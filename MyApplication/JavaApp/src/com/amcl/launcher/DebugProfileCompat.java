package com.amcl.launcher;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * MC 26.2 / NeoForge debug-overlay compatibility.
 *
 * Sodium 0.9.2 registers {@code sodium:buffer_arena} as an ordinary Minecraft
 * debug-screen entry and defaults it to {@code IN_OVERLAY}.  On a phone the
 * allocator heatmap covers much of F3, so AMCL changes that single entry to
 * {@code NEVER} once per isolated game directory.
 *
 * Important boundaries:
 *  - No Sodium class or private field is reflected.
 *  - The entry must already exist in Minecraft's public debug-entry registry.
 *  - Mutation uses Minecraft's public DebugScreenEntryList#setStatus on the
 *    render thread.  Minecraft therefore preserves the complete live status
 *    map and performs its normal debug-profile.json save.
 *  - A one-time marker prevents AMCL from overwriting a status that the user
 *    deliberately changes later.
 *  - We wait until the launch thread is inside Minecraft.run before resolving
 *    any Minecraft class.  Class.forName(..., false, gameLoader) therefore
 *    returns classes that NeoForge has already transformed and loaded; it does
 *    not race game bootstrap or initialize an untransformed parent copy.
 */
final class DebugProfileCompat {
    private static final String LOG_PREFIX = "[AMCL DebugProfileCompat] ";
    private static final String MINECRAFT_CLASS = "net.minecraft.client.Minecraft";
    private static final String ENTRY_NAMESPACE = "sodium";
    private static final String ENTRY_PATH = "buffer_arena";
    private static final String ENTRY_ID = ENTRY_NAMESPACE + ":" + ENTRY_PATH;
    private static final String MARKER_NAME = ".amcl-sodium-buffer-arena-never-v1";
    private static final long STARTUP_TIMEOUT_MS = 120_000L;
    private static final long POLL_INTERVAL_MS = 200L;
    private static final long RENDER_DISPATCH_TIMEOUT_MS = 15_000L;
    private static final long MAX_DEBUG_PROFILE_BYTES = 1024L * 1024L;

    private DebugProfileCompat() {}

    /** Starts the compatibility task only for the exact affected launch family. */
    static void install(LaunchConfig config, Thread launchThread) {
        if (!isTargetLaunch(config)) {
            return;
        }
        if (launchThread == null) {
            log("unsupported: launch thread unavailable");
            return;
        }

        final File gameDir = new File(config.gameDir);
        final File debugProfile = new File(gameDir, "debug-profile.json");
        final File marker = new File(gameDir, MARKER_NAME);

        Thread worker = new Thread(new Runnable() {
            @Override
            public void run() {
                waitForMinecraftAndApply(launchThread, debugProfile, marker);
            }
        }, "amcl-debug-profile-compat");
        worker.setDaemon(true);
        worker.setPriority(Thread.MIN_PRIORITY);
        worker.start();
    }

    /** Package-private for the Java launcher regression suite. */
    static boolean isTargetLaunch(LaunchConfig config) {
        if (config == null || !config.isForge || config.isFabric
                || config.gameDir == null || config.gameDir.isEmpty()) {
            return false;
        }

        boolean neoForge = config.mainClass != null
                && config.mainClass.toLowerCase(java.util.Locale.ROOT).startsWith("net.neoforged.");
        if (!neoForge && config.classpath != null) {
            for (String path : config.classpath) {
                if (path == null) continue;
                String normalized = path.replace('\\', '/').toLowerCase(java.util.Locale.ROOT);
                if (normalized.contains("/net/neoforged/") || normalized.contains("neoforge")) {
                    neoForge = true;
                    break;
                }
            }
        }
        if (!neoForge) {
            return false;
        }

        String version = argumentAfter(config.mcArgs, "--version");
        return isMc262Version(version);
    }

    private static String argumentAfter(String[] args, String key) {
        if (args == null) return null;
        for (int i = 0; i + 1 < args.length; i++) {
            if (key.equals(args[i])) return args[i + 1];
        }
        return null;
    }

    /** Accept 26.2 and its launcher suffixes, but not 26.20 / 26.2.1. */
    private static boolean isMc262Version(String version) {
        if (version == null || !version.startsWith("26.2")) return false;
        if (version.length() == 4) return true;
        char suffix = version.charAt(4);
        return suffix == '-' || suffix == '_' || suffix == '+';
    }

    private static void waitForMinecraftAndApply(Thread launchThread, File debugProfile, File marker) {
        long deadline = System.currentTimeMillis() + STARTUP_TIMEOUT_MS;
        while (System.currentTimeMillis() < deadline) {
            if (!launchThread.isAlive()) {
                log("unsupported: launch thread ended before Minecraft.run");
                return;
            }

            ClassLoader gameLoader = launchThread.getContextClassLoader();
            if (isTransformingGameLoader(gameLoader) && isInsideMinecraftRun(launchThread.getStackTrace())) {
                applyWithLoadedGame(gameLoader, debugProfile, marker);
                return;
            }

            try {
                Thread.sleep(POLL_INTERVAL_MS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                log("unsupported: compatibility worker interrupted");
                return;
            }
        }
        log("timeout: Minecraft.run / transformed game loader not observed within "
                + STARTUP_TIMEOUT_MS + " ms");
    }

    /** Package-private pure checks for tests; they never load a game class. */
    static boolean isTransformingGameLoader(ClassLoader loader) {
        if (loader == null) return false;
        String name = loader.getClass().getName();
        return "net.neoforged.fml.classloading.transformation.TransformingClassLoader".equals(name)
                || name.endsWith(".TransformingClassLoader");
    }

    static boolean isInsideMinecraftRun(StackTraceElement[] stack) {
        if (stack == null) return false;
        for (StackTraceElement frame : stack) {
            if (MINECRAFT_CLASS.equals(frame.getClassName()) && "run".equals(frame.getMethodName())) {
                return true;
            }
        }
        return false;
    }

    private static void applyWithLoadedGame(ClassLoader gameLoader, File debugProfile, File marker) {
        try {
            // Minecraft.run is already on the launch-thread stack.  These calls
            // therefore retrieve already-loaded transformed classes only.
            final Class<?> minecraftClass = Class.forName(MINECRAFT_CLASS, false, gameLoader);
            final Class<?> identifierClass = Class.forName(
                    "net.minecraft.resources.Identifier", false, gameLoader);
            final Class<?> entriesClass = Class.forName(
                    "net.minecraft.client.gui.components.debug.DebugScreenEntries", false, gameLoader);
            final Class<?> statusClass = Class.forName(
                    "net.minecraft.client.gui.components.debug.DebugScreenEntryStatus", false, gameLoader);

            final Object minecraft = minecraftClass.getMethod("getInstance").invoke(null);
            if (minecraft == null) {
                log("unsupported: Minecraft.run observed but singleton is null");
                return;
            }

            final Method execute = minecraftClass.getMethod("execute", Runnable.class);
            final AtomicReference<RuntimeResult> result = new AtomicReference<RuntimeResult>();
            final CountDownLatch completed = new CountDownLatch(1);
            final boolean markerExists = marker.isFile();

            Runnable renderTask = new Runnable() {
                @Override
                public void run() {
                    try {
                        result.set(applyOnRenderThread(
                                minecraft, minecraftClass, identifierClass, entriesClass,
                                statusClass, markerExists));
                    } catch (Throwable t) {
                        result.set(RuntimeResult.unsupported(
                                "public Minecraft debug API failed: " + describe(t)));
                    } finally {
                        completed.countDown();
                    }
                }
            };

            execute.invoke(minecraft, renderTask);
            if (!completed.await(RENDER_DISPATCH_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                log("timeout: render-thread dispatch did not complete within "
                        + RENDER_DISPATCH_TIMEOUT_MS + " ms");
                return;
            }

            RuntimeResult runtime = result.get();
            if (runtime == null) {
                log("unsupported: render-thread task returned no result");
                return;
            }

            if (runtime.kind == ResultKind.APPLIED) {
                if (!profileContainsPersistedNever(debugProfile)) {
                    log("unsupported: runtime became NEVER but debug-profile.json persistence "
                            + "could not be confirmed; marker not written, next launch will retry");
                    return;
                }
                boolean markerWritten = markerExists || writeMarker(marker);
                log("applied: " + ENTRY_ID + "=NEVER via Minecraft public API; full status map saved"
                        + (markerWritten ? "" : "; marker write failed, next launch will retry"));
                return;
            }

            if (runtime.kind == ResultKind.ALREADY_NEVER) {
                boolean markerWritten = markerExists || writeMarker(marker);
                log("already-never: " + ENTRY_ID
                        + (markerWritten ? "" : "; marker write failed, next launch will re-check"));
                return;
            }

            if (runtime.kind == ResultKind.ALREADY_MIGRATED) {
                log("already-migrated: respecting user/current status=" + runtime.detail);
                return;
            }

            log("unsupported: " + runtime.detail);
        } catch (ClassNotFoundException e) {
            log("unsupported: MC 26.2 debug API class missing: " + describe(e));
        } catch (NoSuchMethodException e) {
            log("unsupported: MC 26.2 public debug API shape changed: " + describe(e));
        } catch (Throwable t) {
            log("unsupported: compatibility hook failed closed: " + describe(t));
        }
    }

    /** Runs only on Minecraft's render thread. */
    @SuppressWarnings("unchecked")
    private static RuntimeResult applyOnRenderThread(
            Object minecraft,
            Class<?> minecraftClass,
            Class<?> identifierClass,
            Class<?> entriesClass,
            Class<?> statusClass,
            boolean markerExists) throws Exception {
        Method createIdentifier = identifierClass.getMethod(
                "fromNamespaceAndPath", String.class, String.class);
        Object entryId = createIdentifier.invoke(null, ENTRY_NAMESPACE, ENTRY_PATH);

        Method allEntries = entriesClass.getMethod("allEntries");
        Object entriesObject = allEntries.invoke(null);
        if (!(entriesObject instanceof Map)
                || !((Map<Object, Object>) entriesObject).containsKey(entryId)) {
            return RuntimeResult.unsupported(ENTRY_ID + " is not registered; no state changed");
        }

        Field debugEntriesField = minecraftClass.getField("debugEntries");
        Object debugEntries = debugEntriesField.get(minecraft);
        if (debugEntries == null) {
            return RuntimeResult.unsupported("Minecraft.debugEntries is null");
        }

        Object never = statusClass.getField("NEVER").get(null);
        Method getStatus = debugEntries.getClass().getMethod("getStatus", identifierClass);
        Object current = getStatus.invoke(debugEntries, entryId);

        StatusAction action = decideStatusAction(markerExists, current == never);
        if (action == StatusAction.ALREADY_NEVER) return RuntimeResult.alreadyNever();
        if (action == StatusAction.RESPECT_MIGRATED) {
            return RuntimeResult.alreadyMigrated(String.valueOf(current));
        }

        Method setStatus = debugEntries.getClass().getMethod(
                "setStatus", identifierClass, statusClass);
        setStatus.invoke(debugEntries, entryId, never);
        Object after = getStatus.invoke(debugEntries, entryId);
        if (after != never) {
            return RuntimeResult.unsupported("setStatus returned but status is " + String.valueOf(after));
        }
        return RuntimeResult.applied();
    }

    /** Shared by production logic and tests: a marker makes later user choice authoritative. */
    static StatusAction decideStatusAction(boolean markerExists, boolean statusIsNever) {
        if (markerExists) {
            return statusIsNever ? StatusAction.ALREADY_NEVER : StatusAction.RESPECT_MIGRATED;
        }
        return statusIsNever ? StatusAction.ALREADY_NEVER : StatusAction.APPLY;
    }

    /** Package-private for regression tests and post-save verification. */
    static boolean profileContainsPersistedNever(File file) {
        if (file == null || !file.isFile() || file.length() < 2L
                || file.length() > MAX_DEBUG_PROFILE_BYTES) {
            return false;
        }
        try {
            String json = new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
            // A profile wins over custom during MC 26.2 load, so both conditions matter.
            if (findJsonStringMemberValue(json, "profile") != null) return false;
            return "never".equals(findJsonStringMemberValue(json, ENTRY_ID));
        } catch (IOException e) {
            return false;
        }
    }

    /**
     * Finds a JSON string member without pulling Gson into the JDK-8-compatible
     * launcher jar.  Minecraft writes this file itself, so only string keys and
     * string values are needed here.  Quoted values are decoded for basic JSON
     * escapes; malformed input simply returns null and the hook fails closed.
     */
    private static String findJsonStringMemberValue(String json, String wantedKey) {
        if (json == null || wantedKey == null) return null;
        int index = 0;
        while (index < json.length()) {
            int quote = json.indexOf('"', index);
            if (quote < 0) return null;
            ParsedString key = parseJsonString(json, quote);
            if (key == null) return null;
            int colon = skipWhitespace(json, key.nextIndex);
            if (colon < json.length() && json.charAt(colon) == ':') {
                int valueStart = skipWhitespace(json, colon + 1);
                if (wantedKey.equals(key.value)
                        && valueStart < json.length() && json.charAt(valueStart) == '"') {
                    ParsedString value = parseJsonString(json, valueStart);
                    return value == null ? null : value.value;
                }
            }
            index = key.nextIndex;
        }
        return null;
    }

    private static int skipWhitespace(String value, int index) {
        while (index < value.length()) {
            char c = value.charAt(index);
            if (c != ' ' && c != '\t' && c != '\r' && c != '\n') break;
            index++;
        }
        return index;
    }

    private static ParsedString parseJsonString(String json, int quoteIndex) {
        if (quoteIndex < 0 || quoteIndex >= json.length() || json.charAt(quoteIndex) != '"') {
            return null;
        }
        StringBuilder value = new StringBuilder();
        for (int i = quoteIndex + 1; i < json.length(); i++) {
            char c = json.charAt(i);
            if (c == '"') return new ParsedString(value.toString(), i + 1);
            if (c != '\\') {
                value.append(c);
                continue;
            }
            if (++i >= json.length()) return null;
            char escaped = json.charAt(i);
            switch (escaped) {
                case '"': value.append('"'); break;
                case '\\': value.append('\\'); break;
                case '/': value.append('/'); break;
                case 'b': value.append('\b'); break;
                case 'f': value.append('\f'); break;
                case 'n': value.append('\n'); break;
                case 'r': value.append('\r'); break;
                case 't': value.append('\t'); break;
                case 'u':
                    if (i + 4 >= json.length()) return null;
                    try {
                        value.append((char) Integer.parseInt(json.substring(i + 1, i + 5), 16));
                    } catch (NumberFormatException e) {
                        return null;
                    }
                    i += 4;
                    break;
                default:
                    return null;
            }
        }
        return null;
    }

    private static boolean writeMarker(File marker) {
        File parent = marker.getParentFile();
        if (parent != null && !parent.isDirectory() && !parent.mkdirs()) {
            return false;
        }
        byte[] contents = ("entry=" + ENTRY_ID + "\nstatus=never\nversion=1\n")
                .getBytes(StandardCharsets.UTF_8);
        try (FileOutputStream output = new FileOutputStream(marker, false)) {
            output.write(contents);
            output.flush();
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    private static String describe(Throwable throwable) {
        Throwable root = throwable;
        while (root.getCause() != null && root.getCause() != root) root = root.getCause();
        String message = root.getMessage();
        return root.getClass().getSimpleName() + (message == null ? "" : ": " + message);
    }

    private static void log(String message) {
        System.out.println(LOG_PREFIX + message);
    }

    private enum ResultKind {
        APPLIED,
        ALREADY_NEVER,
        ALREADY_MIGRATED,
        UNSUPPORTED
    }

    enum StatusAction {
        APPLY,
        ALREADY_NEVER,
        RESPECT_MIGRATED
    }

    private static final class RuntimeResult {
        final ResultKind kind;
        final String detail;

        private RuntimeResult(ResultKind kind, String detail) {
            this.kind = kind;
            this.detail = detail;
        }

        static RuntimeResult applied() {
            return new RuntimeResult(ResultKind.APPLIED, "");
        }

        static RuntimeResult alreadyNever() {
            return new RuntimeResult(ResultKind.ALREADY_NEVER, "NEVER");
        }

        static RuntimeResult alreadyMigrated(String currentStatus) {
            return new RuntimeResult(ResultKind.ALREADY_MIGRATED, currentStatus);
        }

        static RuntimeResult unsupported(String reason) {
            return new RuntimeResult(ResultKind.UNSUPPORTED, reason);
        }
    }

    private static final class ParsedString {
        final String value;
        final int nextIndex;

        ParsedString(String value, int nextIndex) {
            this.value = value;
            this.nextIndex = nextIndex;
        }
    }
}
