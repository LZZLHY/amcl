package org.lwjgl.opengl;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import org.lwjgl.glfw.CallbackBridge;
import org.lwjgl.input.Keyboard;
import org.lwjgl.input.Mouse;

/**
 * 唯一Source/Core/bridge真实运输经原JNI进入正式JAR，最终只读公开Keyboard/Mouse cache/next。
 * Native夹具仅组织平台资源、公开producer和运输观测，不计算desired/归约/票/容量。
 * 这是宿主消费者证据，不证明设备实际连入或游戏相机/独立tick已经采用。
 */
public final class L2SourceProductionTest {
    private static AMCLDisplay display;
    private static Method keyboardCreate, mouseCreate;
    private static int targetReentryCalls;
    /** 只保原真实acquire返回的token供此场正常release，不造owner或原资格。 */
    private static long targetReentryOwner;
    private static boolean focusNestedRead;
    private static native void initialize(String foreignOwner);
    /** Source实际result字段：owner/accepted/transportAccepted/status/finalEdges/deferredEdges。 */
    private static native long[] acquire(int source, String control, int[] codes);
    private static native long[] release(long owner);
    /** 实际Source快照：owners/outputs/physical/deferred，及原五source held数量。 */
    private static native long[] sourceSnapshot();
    /** 只调用真实Core文字资格与Source原子pair；这不是SDK/JAR Keyboard ready替身。 */
    private static native void ownedTextBegin();
    /** 原Native ingress焦点及原cancel Core后缀，不伪造Java FOCUS/原scope。 */
    private static native boolean focusBoundary(int kind);
    private static native long[] focusFacts();
    /** 固定UTF8样本/非法编码提交真实Core；snapshot只读blob/queue/held/consumer。 */
    private static native boolean unicodeCommit(int sample);
    private static native void unicodeLegacy(int scalar);
    private static native long[] unicodeCoreSnapshot();
    /** 完整宿主surface寿命结束，原ingress维护消费者随生产生命周期关闭。 */
    private static native void unicodeSurfaceClose();
    private static native long[] ownedTextTap();
    private static native void ownedTextEnd();
    private static native void ownedTextAbort();
    private static native void ownedTextFocus(boolean active);
    private static native void ownedTextBoundary();
    private static native void fillPressure(int records);
    private static native void velocity(boolean active);
    private static native void sealFuturePrefix();
    /** 逐字生产physical事务入口，typed选择/Core/backend资格仍是正式实现。 */
    private static native int physical(boolean down);
    /** 每5项一条真正bridge L2Next结果，仅观测已返回的原type/i1/i2/i3/i4。 */
    private static native int[] takeTransportTrace();
    private static native void armTargetReentry();
    private static native void restoreWindow();

    /** 所有失败都带独立行为标记，工具/初始化错误不能作为有效反控。 */
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError("L2_SOURCE " + message);
    }
    /** 窗口是外部边缘；使用实际上游允许的create反射，poll/read/next都不重写。 */
    private static void create() throws Exception {
        synchronized (GlobalLock.lock) {
            display = new AMCLDisplay();
            display.createWindow(null,new DisplayMode(800,600),null,0,0);
            keyboardCreate.invoke(null, display); mouseCreate.invoke(null, display);
        }
    }
    /** 反射沿原公开create的GlobalLock合同；只执行真实上游方法，不设created或Native资格。 */
    private static void createKeyboard() throws Exception {
        synchronized (GlobalLock.lock) { keyboardCreate.invoke(null, display); }
    }
    /** Mouse先建时仅真实Mouse有队列；共享control consumer不替代独立Keyboard成功。 */
    private static void createMouseOnly() throws Exception {
        synchronized (GlobalLock.lock) {
            display = new AMCLDisplay();
            display.createWindow(null,new DisplayMode(800,600),null,0,0);
            mouseCreate.invoke(null, display);
        }
    }
    /** 只读正式Java原字段，不能通过反射制造Ready、修改缓存或复制owner状态。 */
    private static Object member(String name) throws Exception {
        Field field = AMCLDisplay.class.getDeclaredField(name); field.setAccessible(true);
        return field.get(display);
    }
    private static long consumer() throws Exception { return ((Long)member("controlConsumer")).longValue(); }
    /** 原POD身份仅用于断言资源确实换代，不参与生产判断或事件路由。 */
    private static long[] keyboardLease() throws Exception { return ((long[])member("keyboardLease")).clone(); }
    /** 清理使用实际公开退出；不篡改owner、字节队列或资源generation。 */
    private static void finish() {
        synchronized (GlobalLock.lock) {
            display.destroyWindow();
            if (Keyboard.isCreated()) Keyboard.destroy();
            if (Mouse.isCreated()) Mouse.destroy();
        }
    }
    /** 一组有界真实poll/next，返回游戏API实际可读取的键；没有后续新输入帮旧UP收尾。 */
    private static List<Integer> pullKeys() {
        List<Integer> result = new ArrayList<Integer>();
        for (int i = 0; i < 4; i++) { poll(); result.addAll(keyEdges()); while (Mouse.next()) {} }
        return result;
    }
    /** 只由真实Keyboard.next读取字符；既不读运输侧带代替交付，也不重建Java字符队列。 */
    private static List<Integer> pullCharacters() {
        List<Integer> result = new ArrayList<Integer>();
        for (int i = 0; i < 4; i++) {
            poll();
            while (Keyboard.next()) if (Keyboard.getEventCharacter() != 0)
                result.add((int)Keyboard.getEventCharacter());
            while (Mouse.next()) {}
        }
        return result;
    }
    /**
     * typed物理持有从唯一Core原事实恢复；原scope未泵UP只撤其原held，不能投给新队列。
     * 调用原physical JNI/transaction，不直接inject backend记录，不写owner或Keyboard缓存。
     */
    private static void typedKeyboardRecreate() throws Exception {
        create(); poll(); empty(); takeTransportTrace();
        long originalConsumer = consumer(); long[] firstLease = keyboardLease();
        long mouse = accepted(acquire(1,"typed-recreate-mouse",new int[]{-1}),"typed-recreate Mouse sibling");
        poll(); empty(); check(Mouse.isButtonDown(0),"typed-recreate actual Mouse held");
        check(physical(true) == 11,"typed-recreate original physical DOWN accepted");
        poll(); List<Integer> first = keyEdges();
        check(first.equals(java.util.Arrays.asList(Keyboard.KEY_A)) && Keyboard.isKeyDown(Keyboard.KEY_A),
            "typed-recreate original actual cache/next " + first);
        Keyboard.destroy(); createKeyboard(); long[] secondLease = keyboardLease();
        List<Integer> baseline = pullKeys();
        check(consumer() == originalConsumer && secondLease[2] != firstLease[2] &&
            baseline.equals(java.util.Arrays.asList(Keyboard.KEY_A)) && Keyboard.isKeyDown(Keyboard.KEY_A),
            "typed-recreate lawful Core held baseline once " + baseline);
        check(physical(false) == 11,"typed-recreate original physical final UP accepted");
        List<Integer> last = pullKeys();
        check(last.equals(java.util.Arrays.asList(-Keyboard.KEY_A)) && !Keyboard.isKeyDown(Keyboard.KEY_A),
            "typed-recreate original final cache/next UP once " + last);
        check(physical(true) == 11,"typed-recreate second actual DOWN");
        poll(); check(keyEdges().equals(java.util.Arrays.asList(Keyboard.KEY_A)),"typed-recreate second original next DOWN");
        check(physical(false) == 11,"typed-recreate old unpumped UP accepted");
        Keyboard.destroy(); createKeyboard(); List<Integer> old = pullKeys();
        check(old.isEmpty() && !Keyboard.isKeyDown(Keyboard.KEY_A) && Mouse.isButtonDown(0),
            "typed-recreate old UP cannot enter new queue or leave held " + old);
        System.out.println("L2_KEYBOARD_MODE_PASS typed-held-recreate baseline=" + baseline + " finalNext=" + last +
            " oldUpNext=" + old + " MouseSibling=true");
        check(release(mouse)[1] == 1,"typed-recreate original Mouse cleanup"); poll(); empty(); finish();
    }
    /**
     * typed TEXT_COMMIT与legacy CHAR都在接受处带原Keyboard scope。仅局部重建Keyboard，
     * 保同consumer/Mouse，旧未泵字符必须丢弃；当前新字符仍由真实Keyboard.next领取。
     */
    private static void textCharacterRecreate() throws Exception {
        create(); poll(); empty(); takeTransportTrace();
        long originalConsumer = consumer(); long[] firstLease = keyboardLease();
        long mouse = accepted(acquire(1,"text-recreate-mouse",new int[]{-1}),"text-recreate Mouse sibling");
        poll(); empty();
        ownedTextBegin(); ownedTextBoundary(); fillPressure(1);
        Keyboard.destroy(); createKeyboard(); List<Integer> old = pullCharacters();
        check(consumer() == originalConsumer && keyboardLease()[2] != firstLease[2] && old.isEmpty() && Mouse.isButtonDown(0),
            "text-recreate old typed COMMIT/legacy CHAR cannot enter new queue " + old);
        ownedTextBegin(); ownedTextBoundary(); fillPressure(1); List<Integer> current = pullCharacters();
        check(current.equals(java.util.Arrays.asList((int)'o',(int)'n',(int)'A')) && Mouse.isButtonDown(0),
            "text-recreate current actual COMMIT/CHAR next only " + current);
        System.out.println("L2_KEYBOARD_MODE_PASS text-char-recreate oldCharacters=" + old +
            " currentCharacters=" + current + " MouseSibling=true");
        check(release(mouse)[1] == 1,"text-recreate original Mouse cleanup"); poll(); empty(); finish();
    }

    /**
     * 每个模式在独立JVM执行完整Keyboard/Mouse真实生命周期。Source和Core/JNI均来自
     * 同一冻结生产二进制；这里仅组织公开producer、create/destroy、cache/poll/next观测。
     */
    private static void keyboardLifecycle(String mode) throws Exception {
        createMouseOnly();
        for (int i = 0; i < 3; i++) { Mouse.poll(); while (Mouse.next()) {} }
        takeTransportTrace();
        check(Mouse.isCreated() && !Keyboard.isCreated(), "lifecycle actual Mouse-only original resource");
        if (mode.equals("mouse-only")) {
            check(member("keyboardEventQueue") == null && member("keyboardLease") == null, "mouse-only no Keyboard queue/lease");
            ownedTextBegin(); long[] before = controls(), tap = ownedTextTap();
            for (int i = 0; i < 4; i++) { Mouse.poll(); while (Mouse.next()) {} }
            long[] after = controls(); int[] trace = takeTransportTrace();
            check(tap[1] == 0 && tap[2] == 0 && after[2] == before[2] && after[7] == before[7] &&
                sourceSnapshot()[0] == 0 && member("keyboardEventQueue") == null,
                "mouse-only owned tap rejects without transport/cache " + java.util.Arrays.toString(tap));
            for (int i = 0; i < trace.length; i += 5)
                check(trace[i] != 1005 && trace[i] != 2005, "mouse-only no key transport");
            System.out.println("L2_KEYBOARD_MODE_PASS mouse-only tap=" + java.util.Arrays.toString(tap) +
                " created=false queue=null cacheDelta=" + (after[7]-before[7]) + " Mouse=true");
            finish(); return;
        }
        createKeyboard(); poll(); empty(); takeTransportTrace();
        long originalConsumer = consumer(); long[] originalLease = keyboardLease();
        long mouse = accepted(acquire(1, "keyboard-life-mouse", new int[]{-1}), "lifecycle actual Mouse sibling");
        poll(); empty(); check(Mouse.isButtonDown(0), "lifecycle original Mouse sibling held");
        if (mode.equals("local-recreate")) {
            ownedTextBegin(); long[] oldTap = ownedTextTap();
            check(oldTap[1] == 1 && oldTap[2] == 1, "local-recreate original unpumped tap accepted");
            Keyboard.destroy(); check(Mouse.isCreated() && Mouse.isButtonDown(0), "local-recreate only Keyboard destroyed");
            createKeyboard(); long[] nextLease = keyboardLease();
            check(consumer() == originalConsumer && nextLease[0] == originalLease[0] &&
                nextLease[1] == originalLease[1] && nextLease[2] != originalLease[2], "local-recreate same consumer new Keyboard generation");
            List<Integer> edges = pullKeys();
            check(edges.isEmpty() && !Keyboard.isKeyDown(Keyboard.KEY_BACK) && Mouse.isButtonDown(0) &&
                ownedTextTap()[1] == 0, "local-recreate old pair/scope cannot adopt new queue " + edges);
            System.out.println("L2_KEYBOARD_MODE_PASS local-recreate oldTap=" + java.util.Arrays.toString(oldTap) +
                " oldLease=" + java.util.Arrays.toString(originalLease) + " newLease=" + java.util.Arrays.toString(nextLease) +
                " next=" + edges + " MouseSibling=true");
        } else if (mode.equals("held-recreate")) {
            long original = accepted(acquire(1, "keyboard-life-back", new int[]{259}), "held-recreate original Source held");
            poll(); List<Integer> first = keyEdges();
            check(first.equals(java.util.Arrays.asList(Keyboard.KEY_BACK)) && Keyboard.isKeyDown(Keyboard.KEY_BACK), "held-recreate original real cache/next");
            Keyboard.destroy(); createKeyboard(); long[] nextLease = keyboardLease();
            check(consumer() == originalConsumer && nextLease[2] != originalLease[2] && Mouse.isButtonDown(0), "held-recreate resource only changed");
            List<Integer> baseline = pullKeys();
            check(baseline.equals(java.util.Arrays.asList(Keyboard.KEY_BACK)) && Keyboard.isKeyDown(Keyboard.KEY_BACK), "held-recreate actual lawful Source baseline " + baseline);
            long[] added = acquire(2, "keyboard-life-back-coholder", new int[]{259});
            long coholder = accepted(added, "held-recreate explicit new coholder");
            check(added[4] == 0 && pullKeys().isEmpty() && Keyboard.isKeyDown(Keyboard.KEY_BACK), "held-recreate zero-edge coholder preserves real cache");
            long[] oldRelease = release(original);
            check(oldRelease[1] == 1 && oldRelease[4] == 0 && pullKeys().isEmpty() && Keyboard.isKeyDown(Keyboard.KEY_BACK), "held-recreate old token release preserves new holder");
            long[] finalRelease = release(coholder); List<Integer> last = pullKeys();
            check(finalRelease[1] == 1 && finalRelease[4] == 1 && last.equals(java.util.Arrays.asList(-Keyboard.KEY_BACK)) &&
                !Keyboard.isKeyDown(Keyboard.KEY_BACK) && Mouse.isButtonDown(0), "held-recreate actual final UP once " + last);
            System.out.println("L2_KEYBOARD_MODE_PASS held-recreate baseline=" + baseline + " coholderFinalEdges=" + added[4] +
                " oldReleaseFinalEdges=" + oldRelease[4] + " finalNext=" + last + " MouseSibling=true");
        } else if (mode.equals("deferred-old-scope")) {
            compat(78, true); poll(); List<Integer> first = keyEdges();
            check(first.equals(java.util.Arrays.asList(Keyboard.KEY_N)) && Keyboard.isKeyDown(Keyboard.KEY_N), "deferred-old original actual N cache");
            fillPressure(8); compat(78, false);
            check(sourceSnapshot()[3] == 1, "deferred-old real Source terminal pending");
            Keyboard.destroy(); createKeyboard(); long[] nextLease = keyboardLease();
            check(consumer() == originalConsumer && nextLease[2] != originalLease[2] && Mouse.isButtonDown(0), "deferred-old same Mouse consumer new key resource");
            // 实际消费者有界回收旧满ring；不伪造容量、不用新命令重放旧scope的末松。
            List<Integer> old = pullKeys();
            check(old.isEmpty() && !Keyboard.isKeyDown(Keyboard.KEY_N) && sourceSnapshot()[3] == 0 && Mouse.isButtonDown(0),
                "deferred-old retired UP cannot restore new resource " + old + " source=" + java.util.Arrays.toString(sourceSnapshot()));
            ownedTextBegin(); long[] newTap = ownedTextTap(); List<Integer> current = pullKeys();
            check(newTap[1] == 1 && newTap[2] == 1 && current.equals(java.util.Arrays.asList(Keyboard.KEY_BACK,-Keyboard.KEY_BACK)) &&
                !Keyboard.isKeyDown(Keyboard.KEY_N) && !Keyboard.isKeyDown(Keyboard.KEY_BACK) && sourceSnapshot()[3] == 0 && Mouse.isButtonDown(0),
                "deferred-old only current BACK pair reaches actual next " + current);
            System.out.println("L2_KEYBOARD_MODE_PASS deferred-old-scope oldNext=" + old + " newNext=" + current +
                " newTap=" + java.util.Arrays.toString(newTap) + " deferred=0 MouseSibling=true");
        } else throw new AssertionError("L2_SOURCE unknown keyboard lifecycle mode " + mode);
        check(release(mouse)[1] == 1, "lifecycle exact Mouse sibling cleanup"); poll(); empty(); finish();
    }
    /** 排空的是实际两个独立队列；键盘不会等待鼠标next来获得合法poll状态。 */
    private static void empty() { while (Keyboard.next()) {} while (Mouse.next()) {} }
    private static void poll() { Keyboard.poll(); Mouse.poll(); }
    /** 返回公开next真实取出的键，保原短脉冲与源编码，不取测试旁带desired。 */
    private static List<Integer> keyEdges() {
        List<Integer> result = new ArrayList<Integer>();
        while (Keyboard.next()) if (Keyboard.getEventKey() != 0)
            result.add(Keyboard.getEventKeyState() ? Keyboard.getEventKey() : -Keyboard.getEventKey());
        return result;
    }
    /** 原14字段snapshot只读；实际cache终结与next回执继续由正式JNI/Java产生。 */
    private static long[] controls() throws Exception {
        Field field = AMCLDisplay.class.getDeclaredField("controlConsumer"); field.setAccessible(true);
        Method method = AMCLDisplay.class.getDeclaredMethod("nControlSnapshot", long.class, long[].class);
        method.setAccessible(true); long[] facts = new long[14];
        check(((Integer)method.invoke(null, field.getLong(display), facts)).intValue() == 0, "live actual consumer snapshot");
        return facts;
    }
    /** public JNI兼容0经真实CallbackBridge类；不直接push KEY伪造这个来源。 */
    private static void compat(int code, boolean down) { CallbackBridge.sendKeycode(code, '\u0000', 37, 0, down); }
    private static long accepted(long[] result, String label) {
        check(result.length == 6 && result[1] == 1 && result[2] == 1 && result[0] != 0, label); return result[0];
    }
    /** 原cursor JNI同步Java回入可退休旧target；调用者仅组织实际公开窗口/consumer生命周期。 */
    public static void reenter(int ignored) throws Exception {
        targetReentryCalls++;
        if (focusNestedRead) {
            // 真实cursor JNI同步回入仍持原GlobalLock；外层drain未完成时不能领取旧low。
            check(!Keyboard.next() && Keyboard.getNumKeyboardEvents() == 0,
                "focus scalar nested preflight defers before outer ordered frame completes");
        }
        display.destroyWindow(); Keyboard.destroy(); Mouse.destroy(); restoreWindow(); create();
        targetReentryOwner=accepted(acquire(2, "new-target", new int[]{-1}), "new target source acquire");
    }

    /** 当前Core scalar经原L2 JNI进入实际JAR；只读标准API，scope/held/队列不在测试计算。 */
    private static List<Integer> unicodeRead() {
        List<Integer> result = new ArrayList<Integer>();
        for (int attempt = 0; attempt < 12; attempt++) {
            Keyboard.poll();
            while (Keyboard.next()) {
                check(Keyboard.getEventKey() == Keyboard.KEY_NONE && Keyboard.getEventKeyState() && !Keyboard.isRepeatEvent(),
                    "L2_UNICODE character key/state/repeat unchanged");
                result.add((int)Keyboard.getEventCharacter());
            }
        }
        return result;
    }
    /** 队列物理游标仅用于断言预算；不修改queue、readBuffer或源scope。 */
    private static int unicodeQueueBytes() throws Exception {
        Object queue = member("keyboardEventQueue");
        Field bytes = EventQueue.class.getDeclaredField("queue"); bytes.setAccessible(true);
        return ((java.nio.ByteBuffer)bytes.get(queue)).position();
    }
    /** 原全部旁带必须和真记录一起收回；blobBytes从实际Core只读snapshot取得。 */
    private static void unicodeReclaimed() throws Exception {
        for (String name : new String[]{"keyboardQueued","keyboardQueuedScopes","keyboardRead","keyboardReadScopes","keyboardQueuedScalars","keyboardReadScalars"})
            check(((List<?>)member(name)).isEmpty(),"L2_UNICODE final exact sidecar reclaim " + name);
        long[] core = unicodeCoreSnapshot();
        check(core[0] == 0 && core[1] == 0 && core[2] == 0 && sourceSnapshot()[0] == 0,
            "L2_UNICODE final Core blob/queue/held/Source reclaim " + java.util.Arrays.toString(core));
    }
    /**
     * 固定上游Display.destroyWindow先Mouse、再Keyboard、最后implementation窗口；
     * 本夹具只替创建窗口边缘，收尾也必须保这条真实顺序。旧finish专测先退休窗口，
     * 不在此改写它；否则Mouse.destroy原reset/poll会在窗口关闭后重新取L2 adapter。
     */
    private static void unicodeFinish() throws Exception {
        synchronized (GlobalLock.lock) {
            if (Mouse.isCreated()) Mouse.destroy();
            if (Keyboard.isCreated()) Keyboard.destroy();
            display.destroyWindow();
        }
        long[] core = unicodeCoreSnapshot();
        // initialize的SurfaceCreated已经打开唯一ingress维护consumer；L2从2退到1，
        // 不能把维护owner仍活着误报成窗口资源泄漏，也不能仅关窗口就要求全Core为0。
        check(core[0] == 0 && core[2] == 0 && core[3] == 1 && consumer() == 0 &&
            member("keyboardLease") == null && member("keyboardEventQueue") == null,
            "L2_UNICODE final original Display order resource reclaim " + java.util.Arrays.toString(core));
        unicodeSurfaceClose(); core = unicodeCoreSnapshot();
        check(core[0] == 0 && core[1] == 0 && core[2] == 0 && core[3] == 0,
            "L2_UNICODE final original Surface ingress owner reclaim " + java.util.Arrays.toString(core));
    }
    /** 直接运行原EventQueue的bulk边界；此局部合同证据与下方完整Core链证据分别记录。 */
    private static void unicodeQueueContract() throws Exception {
        EventQueue queue = new EventQueue(Keyboard.EVENT_SIZE);
        java.nio.ByteBuffer event = java.nio.ByteBuffer.allocate(Keyboard.EVENT_SIZE);
        for (int i = 0; i < event.capacity(); i++) event.put((byte)0x31);
        event.flip();
        for (int i = 0; i < 199; i++) { event.rewind(); check(queue.putEvent(event),"queue original 199 events"); }
        java.nio.ByteBuffer pair = java.nio.ByteBuffer.allocate(3 + 2 * Keyboard.EVENT_SIZE);
        for (int i = 0; i < pair.capacity(); i++) pair.put((byte)0x52);
        pair.flip(); pair.position(3); int position = pair.position(), limit = pair.limit();
        check(!queue.putEvents(pair) && pair.position() == position && pair.limit() == limit,
            "L2_UNICODE_ATOMIC_PAIR_BUDGET queue one-slot rejection preserves source position/limit");
        java.nio.ByteBuffer old = java.nio.ByteBuffer.allocate(200 * Keyboard.EVENT_SIZE);
        queue.copyEvents(old); check(old.position() == 199 * Keyboard.EVENT_SIZE,"queue reject preserves old count");
        for (int i = 0; i < old.position(); i++) check(old.get(i) == 0x31,"queue reject preserves old bytes");
        check(queue.putEvents(pair) && pair.position() == limit && pair.limit() == limit,"queue full batch advances source once");
        java.nio.ByteBuffer invalid = java.nio.ByteBuffer.allocate(Keyboard.EVENT_SIZE + 1);
        check(!queue.putEvents(invalid) && invalid.position() == 0 && invalid.limit() == invalid.capacity(),"queue malformed whole-record reject");
        check(!queue.putEvents(java.nio.ByteBuffer.allocate(0)) && !queue.putEvents(null),"queue empty/null reject");
        Field storage = EventQueue.class.getDeclaredField("queue"); storage.setAccessible(true);
        java.nio.ByteBuffer self = (java.nio.ByteBuffer)storage.get(queue); int before = self.position();
        check(!queue.putEvents(self) && self.position() == before,"queue self-source reject preserves old position");
        java.nio.ByteBuffer retained = java.nio.ByteBuffer.allocate(200 * Keyboard.EVENT_SIZE);
        queue.copyEvents(retained); check(retained.position() == 2 * Keyboard.EVENT_SIZE,"queue malformed/null/self rejects retain full pair");
        for (int i = 0; i < retained.position(); i++) check(retained.get(i) == 0x52,"queue rejected inputs cannot overwrite accepted pair");
        for (byte value : pair.array()) check(value == 0x52,"queue bulk source contents unchanged");
        for (byte value : invalid.array()) check(value == 0,"queue malformed source contents unchanged");
        System.out.println("L2_UNICODE_QUEUE_CONTRACT_PASS oneSlot=false sourcePosition="+position+" sourceLimit="+limit+" twoRecords=true");
    }
    /** 用真实legacy producer逐条填原队列；Mouse.poll只排运输，不复制Keyboard readBuffer。 */
    private static void unicodeFillQueue(int count) throws Exception {
        for (int i = 0; i < count; i++) { fillPressure(1); Mouse.poll(); while (Mouse.next()) {} }
        check(unicodeQueueBytes() == count * Keyboard.EVENT_SIZE,"unicode real queue fill count="+count);
    }
    /** 一槽与两槽分别穿过Core ownedText→full bridge→原JNI→实际Java编码及标准next。 */
    private static void unicodeBudget() throws Exception {
        create(); poll(); empty(); ownedTextBegin(); Mouse.poll();
        unicodeFillQueue(199); long[] before = controls();
        check(unicodeCommit(1),"unicode one-slot original Core accepts complete scalar"); Mouse.poll();
        check(unicodeQueueBytes() == 199 * Keyboard.EVENT_SIZE && ((List<?>)member("keyboardQueued")).size() == 199 &&
            ((List<?>)member("keyboardQueuedScopes")).size() == 199 && controls()[7] == before[7],
            "L2_UNICODE_ATOMIC_PAIR_BUDGET actual one-slot leaves no half/sidecar/cache");
        List<Integer> rejected = unicodeRead();
        check(rejected.size() == 199,"unicode one-slot original records retained");
        for (int c : rejected) check(c == 'A',"unicode no partial surrogate when one slot");
        unicodeFillQueue(198); check(unicodeCommit(1),"unicode two-slot actual commit"); Mouse.poll();
        check(unicodeQueueBytes() == 200 * Keyboard.EVENT_SIZE,"unicode two-slot full 36B commit");
        List<Integer> accepted = unicodeRead();
        check(accepted.size() == 200 && accepted.get(198) == 0xd83d && accepted.get(199) == 0xde00,
            "L2_UNICODE_UTF16_PAIR two-slot actual public pair " + accepted);
        for (int i = 0; i < 198; i++) check(accepted.get(i) == 'A',"unicode pair follows original prefix");
        ownedTextEnd(); poll(); empty(); unicodeReclaimed(); unicodeFinish();
        unicodeQueueContract();
        System.out.println("L2_UNICODE_BUDGET_PASS oneSlot=199 twoSlot=200 fullPair=[55357,56832] noKey0Hold=true");
    }
    /** 完整scalar序列、BMP、legacy合法UTF16单元与非法Core UTF8对照；键边沿继续走原Source。 */
    private static void unicodeSequence() throws Exception {
        create(); poll(); empty(); takeTransportTrace(); ownedTextBegin(); long[] before = controls();
        check(unicodeCommit(0),"unicode actual mixed Core commit"); List<Integer> units = unicodeRead();
        check(units.equals(java.util.Arrays.asList(65,0x4e2d,0x6587,0xd83d,0xde00,90)),
            "L2_UNICODE_UTF16_PAIR ordered actual public units " + units);
        int[] trace = takeTransportTrace(); List<Integer> scalars = new ArrayList<Integer>();
        for (int i = 0; i < trace.length; i += 5) if (trace[i] == 1000 || trace[i] == 1001) scalars.add(trace[i+1]);
        check(scalars.equals(java.util.Arrays.asList(65,0x4e2d,0x6587,0x1f600,90)),"unicode original transport scalar order " + scalars);
        check(!Keyboard.isKeyDown(Keyboard.KEY_NONE) && controls()[7] == before[7] && sourceSnapshot()[0] == 0,
            "unicode character creates no control contributor/key0 hold/cache edge");
        check(unicodeCommit(1),"unicode original pair metadata commit"); Mouse.poll();
        List<?> origins = (List<?>)member("keyboardQueuedScopes");
        check(origins.size() == 2 && java.util.Arrays.equals((long[])origins.get(0),keyboardLease()) &&
            java.util.Arrays.equals((long[])origins.get(0),(long[])origins.get(1)),"unicode both records preserve original complete lease POD");
        Keyboard.poll(); check(Keyboard.next() && Keyboard.getEventCharacter() == 0xd83d,"unicode actual pair metadata high");
        long highNanos = Keyboard.getEventNanoseconds();
        check(Keyboard.next() && Keyboard.getEventCharacter() == 0xde00 && Keyboard.getEventNanoseconds() == highNanos &&
            !Keyboard.isRepeatEvent() && !Keyboard.next(),"unicode same original emission time pair with no extra record");
        check(!unicodeCommit(2) && !unicodeCommit(3) && !unicodeCommit(4) && unicodeRead().isEmpty(),"unicode invalid UTF8 scalar rejected at real Core");
        unicodeLegacy(-1); unicodeLegacy(0x110000); check(unicodeRead().isEmpty(),"unicode invalid transport scalar rejected without truncation");
        CallbackBridge.sendChar((char)0xd83d,0); CallbackBridge.sendChar((char)0xde00,0);
        check(unicodeRead().equals(java.util.Arrays.asList(0xd83d,0xde00)),"unicode legal legacy UTF16 units unchanged");
        long[] back = ownedTextTap(); check(back[1] == 1 && back[2] == 1,"unicode real Source BACK accepted");
        check(pullKeys().equals(java.util.Arrays.asList(Keyboard.KEY_BACK,-Keyboard.KEY_BACK)) && !Keyboard.isKeyDown(Keyboard.KEY_BACK),
            "unicode original key pair/cache unchanged");
        ownedTextEnd(); poll(); empty(); unicodeReclaimed(); unicodeFinish();
        System.out.println("L2_UNICODE_SEQUENCE_PASS transport="+scalars+" publicUtf16="+units+" legacyPair=true invalidScalarRejected=true BACK=[14,-14]");
    }
    /** 原scope在运输、已复制readBuffer与私有编码提交三处退休；不借新current修补旧身份。 */
    private static void unicodeScope() throws Exception {
        create(); poll(); empty(); ownedTextBegin();
        final long consumer = consumer(); final long[] original = (long[])member("keyboardLease");
        check(unicodeCommit(1),"unicode old actual Core commit before local retirement");
        Keyboard.destroy(); createKeyboard();
        check(consumer() == consumer && keyboardLease()[2] != original[2] && unicodeRead().isEmpty(),"unicode old unpumped scope cannot adopt new Keyboard");
        Method codec = AMCLDisplay.class.getDeclaredMethod("putCharacterEvent",int.class,long[].class); codec.setAccessible(true);
        boolean staleAccepted;
        synchronized (GlobalLock.lock) { staleAccepted = ((Boolean)codec.invoke(display,0x1f600,original)).booleanValue(); }
        check(!staleAccepted && unicodeQueueBytes() == 0 && ((List<?>)member("keyboardQueuedScopes")).isEmpty(),
            "L2_UNICODE_ORIGINAL_SCOPE stale codec request cannot write new queue");
        ownedTextBegin(); check(unicodeCommit(1),"unicode current new scope actual commit"); Keyboard.poll();
        // 两条原readBuffer记录尚未next领取；真正目标销毁先fence原Keyboard lease，
        // 还不销毁上游Keyboard/readBuffer，直接由实际ready/read hook丢原pair。
        // 单独Core focus变化不等于Keyboard局部scope退休，不能混用两个合同。
        display.destroyWindow(); check(!Keyboard.next(),"unicode copied pair target retired before actual next");
        Keyboard.destroy(); Mouse.destroy(); restoreWindow(); create(); poll(); empty(); ownedTextBegin();
        check(unicodeCommit(1),"unicode target re-entry current commit");
        check(unicodeRead().equals(java.util.Arrays.asList(0xd83d,0xde00)),"unicode re-enter legitimate new pair once");
        ownedTextEnd(); poll(); empty(); unicodeReclaimed(); unicodeFinish();
        System.out.println("L2_UNICODE_SCOPE_PASS oldTransport=[] oldCodec=false retiredRead=[] reenteredPair=[55357,56832]");
    }
    /** 标准Keyboard.poll/next在另一线程仍阻塞于原GlobalLock；不另造线程owner或game队列。 */
    private static void unicodeThread() throws Exception {
        create(); poll(); empty(); ownedTextBegin(); check(unicodeCommit(1),"unicode threaded original Core commit");
        final List<Integer> units = new ArrayList<Integer>(); final Throwable[] failure = new Throwable[1];
        final java.util.concurrent.CountDownLatch ready = new java.util.concurrent.CountDownLatch(1);
        Thread worker = new Thread(new Runnable() { public void run() {
            ready.countDown(); try { units.addAll(unicodeRead()); } catch (Throwable value) { failure[0] = value; }
        }},"actual-l2-unicode-reader");
        synchronized (GlobalLock.lock) {
            worker.start(); check(ready.await(5,java.util.concurrent.TimeUnit.SECONDS),"unicode worker started");
            long deadline = System.nanoTime() + 1000000000L;
            while (worker.isAlive() && worker.getState() != Thread.State.BLOCKED && System.nanoTime() < deadline) Thread.yield();
            check(worker.getState() == Thread.State.BLOCKED && units.isEmpty(),"unicode actual reader waits original GlobalLock");
        }
        worker.join(10000); check(!worker.isAlive() && failure[0] == null && units.equals(java.util.Arrays.asList(0xd83d,0xde00)),
            "unicode same GlobalLock complete pair across thread " + failure[0]);
        ownedTextEnd(); poll(); empty(); unicodeReclaimed(); unicodeFinish();
        System.out.println("L2_UNICODE_THREAD_PASS actualGlobalLock=BLOCKED publicUtf16="+units);
    }

    /**
     * 真实Core→bridge→原JNI→实际JAR；只操作公开next/poll/peek，反射只读旁带形状。
     * 本测试证明API返回与原资源围栏，仍不代商用XComponent整Blur或游戏文档采用。
     */
    private static void focusScalar(String mode) throws Exception {
        create(); poll(); empty(); takeTransportTrace(); ownedTextBegin();
        if (mode.equals("split-buffer")) {
            // 上游readBuffer实际50条。逐条经原ring/poll积49BMP，避免宿主8槽压力覆盖。
            for (int i=0;i<49;i++) { unicodeLegacy('p'); Keyboard.poll(); }
            check(Keyboard.getNumKeyboardEvents()==49,"focus scalar 49 original public prefix records");
            check(unicodeCommit(1),"focus scalar real pair after 49 records"); Keyboard.poll();
            check(Keyboard.getNumKeyboardEvents()==49,"focus scalar pair must not split at 50th readBuffer slot");
            for (int i=0;i<49;i++) check(Keyboard.next()&&Keyboard.getEventCharacter()=='p',"focus scalar prefix FIFO");
            check(!Keyboard.next(),"focus scalar full pair stays queued until real buffer has two slots");
            Keyboard.poll(); check(Keyboard.next()&&Keyboard.getEventCharacter()==0xd83d,"focus scalar queued pair high");
        } else if (mode.equals("legacy-units")) {
            unicodeLegacy(0xd83d); unicodeLegacy(0xde00); Keyboard.poll();
            check(Keyboard.next()&&Keyboard.getEventCharacter()==0xd83d,"focus scalar legacy high original unit");
        } else {
            check(unicodeCommit(mode.equals("fifo")?0:1),"focus scalar actual Core commit"); Keyboard.poll();
            if (mode.equals("fifo")) {
                List<Integer> actual = new ArrayList<Integer>();
                while(Keyboard.next())actual.add((int)Keyboard.getEventCharacter());
                check(actual.equals(java.util.Arrays.asList(65,0x4e2d,0x6587,0xd83d,0xde00,90)),
                    "focus scalar public mixed FIFO " + actual);
                // focus-only的真实bridge使用512槽测试预算；通过原公开ring放300条，
                // 让真正Keyboard.next走固定256前沿，而不是用private helper小预算代证。
                check(unicodeCommit(1),"focus scalar budget original cached pair"); Keyboard.poll();
                takeTransportTrace();for(int i=0;i<300;i++)unicodeLegacy('x');
                Field bufferField=Keyboard.class.getDeclaredField("readBuffer");bufferField.setAccessible(true);
                java.nio.ByteBuffer originalBuffer=(java.nio.ByteBuffer)bufferField.get(null);
                int position=originalBuffer.position(),limit=originalBuffer.limit();
                check(!Keyboard.next(),"focus scalar actual public next fixed256 budget exhausted");
                check(originalBuffer.position()==position&&originalBuffer.limit()==limit,
                    "focus scalar exhausted public preflight does not consume original readBuffer");
                int[] first=takeTransportTrace();check(first.length==256*5,
                    "focus scalar actual bridge trace fixed256 reads " + first.length);
                for(int i=0;i<first.length;i+=5)check(first[i]==1000&&first[i+1]=='x',"focus scalar original ring first256");
                check(Keyboard.next()&&Keyboard.getEventCharacter()==0xd83d&&
                    Keyboard.next()&&Keyboard.getEventCharacter()==0xde00&&!Keyboard.next(),
                    "focus scalar next resumes original pair after actual bounded public preflight");
                int[] tail=takeTransportTrace();check(tail.length==44*5,"focus scalar actual original frame remaining44 " + tail.length);
                int count=0;for(int attempt=0;attempt<5;attempt++){
                    Keyboard.poll();while(Keyboard.next()){
                        check(Keyboard.getEventCharacter()=='x',"focus scalar remaining queued FIFO");count++;
                    }
                }
                // 原EventQueue容量200，本场只核其实际成功缓存与回收；不是300个输入无损承诺。
                check(count==200,"focus scalar original bounded EventQueue actual200 reclaim " + count);
                ownedTextEnd(); poll(); empty(); unicodeReclaimed(); unicodeFinish(); return;
            }
            if (mode.equals("peek")) check(Keyboard.getNumKeyboardEvents()==2,"focus scalar peek sees pair without starting");
            if (mode.startsWith("half-")||mode.equals("retire")||mode.equals("reentry"))
                check(Keyboard.next()&&Keyboard.getEventCharacter()==0xd83d,"focus scalar actual high before boundary");
        }
        if (mode.equals("retire")) {
            display.destroyWindow(); Keyboard.destroy(); Mouse.destroy(); restoreWindow(); create(); poll();
            check(!Keyboard.next(),"focus scalar old low cannot adopt new Keyboard target");
            // 原window退休已经结束原700资格，不能再次END并假定成功。
            // 原维护consumer的队列只在真正Surface关闭后要求全0。
            poll(); empty(); unicodeFinish(); unicodeReclaimed(); return;
        }
        if (mode.equals("reentry")) {
            // 原Mouse getter同步回入真实reenter销毁/重建窗口。该次旧Keyboard next不可
            // 读后来静态implementation/readBuffer，原兄弟新来源仍由下一次真实poll接管。
            long token=accepted(acquire(1,"focus-reentry",new int[]{-1}),"focus scalar old target source");
            Mouse.poll(); while(Mouse.next()){}; focusNestedRead=true; armTargetReentry(); check(release(token)[1]==1,"focus scalar old target release");
            check(!Keyboard.next()&&targetReentryCalls==1,"focus scalar preflight original buffer reentry guard");
            poll(); check(Mouse.isButtonDown(0),"focus scalar new target sibling survives old preflight");
            check(release(targetReentryOwner)[1]==1,"focus scalar release original new-target source token");
            // 原window回入也已结束旧700；先按真实原顺序关闭新资源/Surface再核全零。
            focusNestedRead=false; poll(); empty(); unicodeFinish(); unicodeReclaimed(); return;
        }
        check(focusBoundary(mode.equals("end")?2:1),"focus scalar actual Native boundary");
        long[] facts=focusFacts();
        if(!mode.equals("end"))check(facts[0]==0&&facts[4]==0&&!unicodeCommit(1)&&ownedTextTap()[1]==0,
            "focus scalar Native producer text qualification actually closed");
        else check(facts[0]==1&&facts[4]==0,"focus scalar ordinary END retains focus");
        if(mode.equals("half-pump")||mode.equals("split-buffer"))Keyboard.poll();
        if(mode.equals("half-pump"))check(Keyboard.getNumKeyboardEvents()==1,
            "focus scalar peek retains started original low without beginning another group");
        if(mode.equals("peek"))check(Keyboard.getNumKeyboardEvents()==0,"focus scalar peek preflight cancels unstarted pair");
        List<Integer> actual = new ArrayList<Integer>();
        while(Keyboard.next())actual.add((int)Keyboard.getEventCharacter());
        if(mode.equals("half-pump")||mode.equals("half-no-pump")||mode.equals("split-buffer"))
            check(actual.equals(java.util.Arrays.asList(0xde00)),"focus scalar started original low completes once " + actual);
        else if(mode.equals("end"))check(actual.equals(java.util.Arrays.asList(0xd83d,0xde00)),
            "focus scalar ordinary END preserves accepted full pair " + actual);
        else check(actual.isEmpty(),"focus scalar unstarted cancelled before public next " + actual);
        check(!Keyboard.next(),"focus scalar no duplicate after boundary");
        poll(); empty(); unicodeReclaimed();
        for(String name:new String[]{"keyboardQueuedScalars","keyboardReadScalars"})
            check(((List<?>)member(name)).isEmpty(),"focus scalar exact private group reclaim " + name);
        unicodeFinish();
        System.out.println("L2_FOCUS_SCALAR_PASS mode="+mode+" actual="+actual+" core="+java.util.Arrays.toString(facts)+
            " publicApiOnly=true gameDocumentApplied=unproven fullXComponentExecuted=false");
    }

    public static void main(String[] args) throws Exception {
        System.load(args[1]); System.load(args[0]); initialize(args[2]);
        keyboardCreate = Keyboard.class.getDeclaredMethod("create", InputImplementation.class);
        mouseCreate = Mouse.class.getDeclaredMethod("create", InputImplementation.class);
        keyboardCreate.setAccessible(true); mouseCreate.setAccessible(true);
        Mouse.setClipMouseCoordinatesToWindow(false);
        if(args.length>3&&args[3].startsWith("focus:")){focusScalar(args[3].substring(6));return;}
        if (args.length > 3 && args[3].equals("unicode-sequence")) { unicodeSequence(); return; }
        if (args.length > 3 && args[3].equals("unicode-budget")) { unicodeBudget(); return; }
        if (args.length > 3 && args[3].equals("unicode-scope")) { unicodeScope(); return; }
        if (args.length > 3 && args[3].equals("unicode-thread")) { unicodeThread(); return; }
        if (args.length > 3 && args[3].equals("typed-held-recreate")) { typedKeyboardRecreate(); return; }
        if (args.length > 3 && args[3].equals("text-char-recreate")) { textCharacterRecreate(); return; }
        if (args.length > 3 && (args[3].equals("mouse-only") || args[3].equals("local-recreate") ||
            args[3].equals("held-recreate") || args[3].equals("deferred-old-scope"))) {
            keyboardLifecycle(args[3]); return;
        }
        create(); poll(); empty(); takeTransportTrace();
        if(args.length>3&&args[3].equals("poll-target")) {
            armTargetReentry();Mouse.poll();
            check(targetReentryCalls==1,"actual menu poll getter target reentry");
            check(Mouse.getX()==500,"retired original poll cannot overwrite new target coordinates x="+Mouse.getX());
            System.out.println("PASS L2_SOURCE original poll getter cannot overwrite new target coordinate cache");return;
        }
        // Keyboard已由真正上游create建立，poll/next读取正式JAR；producer只报告整pair入运输。
        ownedTextBegin();long[] tap=ownedTextTap();
        check(tap[1]==1&&tap[2]==1&&tap[4]==2,"owned pair fully transported");
        List<Integer> ownedEdges=new ArrayList<Integer>();
        for(int i=0;i<4;i++){poll();ownedEdges.addAll(keyEdges());}
        check(ownedEdges.size()==2&&ownedEdges.get(0)==Keyboard.KEY_BACK&&ownedEdges.get(1)==-Keyboard.KEY_BACK,
            "actual owned BACK cache/Keyboard.next pair");
        check(!Keyboard.isKeyDown(Keyboard.KEY_BACK)&&sourceSnapshot()[0]==0,"owned pair no held remainder");
        fillPressure(7);tap=ownedTextTap();check(tap[1]==0&&sourceSnapshot()[0]==0,"owned pressure rejects without DOWN");
        poll();empty();ownedTextEnd();tap=ownedTextTap();check(tap[1]==0,"original retired text scope rejects");
        poll();empty();takeTransportTrace();
        System.out.println("PASS L2_SOURCE owned pair actual JAR BACK cache/next, whole pressure and original text retirement");
        // accepted命令不能因producer后来END变成重放。late pump核真实Keyboard队列：
        // 旧编辑DOWN必须在旧commit/newcommit之前，末松按原短脉冲/next回执有界完成。
        ownedTextBegin();tap=ownedTextTap();check(tap[1]==1,"owned accepted before END");ownedTextBoundary();
        List<Integer> boundary=new ArrayList<Integer>();
        for(int i=0;i<5;i++){poll();while(Keyboard.next()){
            if(Keyboard.getEventKey()==Keyboard.KEY_BACK)boundary.add(Keyboard.getEventKeyState()?1:2);
            else if(Keyboard.getEventCharacter()=='o')boundary.add(3);
            else if(Keyboard.getEventCharacter()=='n')boundary.add(4);}}
        check(boundary.indexOf(1)>=0&&boundary.indexOf(2)>boundary.indexOf(1)&&boundary.indexOf(3)>boundary.indexOf(1)&&
            boundary.indexOf(4)>boundary.indexOf(3)&&!Keyboard.isKeyDown(Keyboard.KEY_BACK),"owned late pump old/new order and final UP "+boundary);
        check(ownedTextTap()[1]==0,"late old producer scope cannot adopt new701");
        System.out.println("PASS L2_SOURCE accepted tap old commit/END/newscope late Keyboard queue="+boundary);
        // ABORT/失焦在accepted之后，使用实际生命周期；已入运输pair按原序完成，
        // 新调用不借已退休原scope。没有等待新按键帮忙收尾。
        ownedTextBegin();check(ownedTextTap()[1]==1,"owned accepted before ABORT");ownedTextAbort();
        ownedEdges.clear();for(int i=0;i<4;i++){poll();ownedEdges.addAll(keyEdges());}
        check(ownedEdges.size()==2&&ownedEdges.get(0)==Keyboard.KEY_BACK&&ownedEdges.get(1)==-Keyboard.KEY_BACK&&
            !Keyboard.isKeyDown(Keyboard.KEY_BACK)&&ownedTextTap()[1]==0,"accepted pair before actual ABORT late next");
        ownedTextBegin();takeTransportTrace();long[] beforeFocus=controls();
        check(ownedTextTap()[1]==1,"owned accepted before focus retirement");ownedTextFocus(false);
        ownedEdges.clear();for(int i=0;i<4;i++){poll();ownedEdges.addAll(keyEdges());}
        long[] afterFocus=controls();int[] focusTrace=takeTransportTrace();
        // L2的真实失焦reset取消未被game next的旧queue；不能要求已撤票仍交next。
        // 原pair先写actual cache(STATE_ONLY+2)，随后两张旧票DISCARDED而非假PULL。
        check(ownedEdges.isEmpty()&&!Keyboard.isKeyDown(Keyboard.KEY_BACK)&&ownedTextTap()[1]==0&&
            afterFocus[7]==beforeFocus[7]+2&&afterFocus[6]==beforeFocus[6]&&afterFocus[13]==beforeFocus[13]+2,
            "accepted pair before focus applies cache then discards old queue edges="+ownedEdges+" stats="+java.util.Arrays.toString(afterFocus));
        check(focusTrace.length==20&&focusTrace[0]==1005&&focusTrace[3]==1&&focusTrace[5]==1005&&focusTrace[8]==0&&
            focusTrace[15]==2010&&focusTrace[16]==0,"real pair transport precedes FOCUS0 "+java.util.Arrays.toString(focusTrace));
        ownedTextFocus(true);poll();empty();
        System.out.println("PASS L2_SOURCE ABORT actual next final UP; focus late cache then exact old queue discard, no fake next");

        long touch = accepted(acquire(1, "touch-a", new int[]{65}), "touch first source acquire");
        poll(); check(Keyboard.isKeyDown(Keyboard.KEY_A), "actual touch cache down");
        check(keyEdges().size() == 1, "actual first source one Keyboard.next DOWN");
        long gamepad = accepted(acquire(2, "gamepad-a", new int[]{65}), "gamepad cohold acquire");
        compat(65, true); compat(65, false); int physicalDown=physical(true);
        check(physicalDown == 11, "actual typed physical ingress accepted outcome="+physicalDown);
        poll(); check(Keyboard.isKeyDown(Keyboard.KEY_A) && keyEdges().isEmpty(), "JNI compat0 plus typed physical cannot duplicate common first DOWN");
        check(release(touch)[1] == 1 && release(gamepad)[1] == 1, "original Source tokens released");
        poll(); check(Keyboard.isKeyDown(Keyboard.KEY_A) && keyEdges().isEmpty(), "typed physical sibling survives last legacy Source UP");
        check(physical(false) == 11, "actual typed physical final UP"); poll();
        check(!Keyboard.isKeyDown(Keyboard.KEY_A) && keyEdges().size() == 1, "actual physical final cache/next UP once");
        System.out.println("PASS L2_SOURCE actual JNI/Source/Core typed cohold and final actual cache/next");

        touch = accepted(acquire(1, "orphan-up", new int[]{66}), "source hold before orphan compat UP"); poll(); empty();
        compat(66, false); poll(); check(Keyboard.isKeyDown(Keyboard.KEY_B) && keyEdges().isEmpty(), "ownerless compat UP cannot steal source token");
        check(release(touch)[1] == 1, "original holder release"); poll(); empty();

        Mouse.setGrabbed(true); poll(); empty(); takeTransportTrace(); velocity(true);
        fillPressure(2); long[] before = sourceSnapshot();
        int[] combo = new int[]{340, 70, 71, 72, 73, 74};
        long[] rejected = acquire(2, "combo-six", combo); long[] after = sourceSnapshot();
        check(rejected[1] == 0 && rejected[0] == 0 && rejected[3] == -3, "real ring six-plus-prefix pressure rejects atomic owner");
        check(after[0] == before[0] && after[1] == before[1], "real pressure has no partial Source owner/output");
        poll(); empty(); takeTransportTrace(); long appliedBefore = controls()[7];
        gamepad = accepted(acquire(2, "combo-six", combo), "all six source outputs after real capacity recovery");
        sealFuturePrefix(); poll(); int[] trace = takeTransportTrace();
        List<Integer> firstSix = keyEdges();
        check(firstSix.size() == 6 && controls()[7] == appliedBefore + 6, "all six actual Java cache writes and Keyboard.next records");
        int first = -1, last = -1, keys = 0;
        for (int i = 0; i < trace.length; i += 5) {
            if (trace[i] == 1020) { if (first < 0) first = i; last = i; }
            if (trace[i] == 1005 && trace[i+3] == 1) { check(first >= 0, "prefix actually transported before every edge"); keys++; }
        }
        check(first >= 0 && last > first && keys == 6, "actual prefix-six-edges-future-prefix transport order");
        check(Mouse.next() && Mouse.getEventButton() == -1, "actual first immutable MOVE22");
        check(Mouse.next() && Mouse.getEventButton() == -1 && !Mouse.next(), "actual future MOVE22 independent of Keyboard.next");
        velocity(false); check(release(gamepad)[1] == 1, "original six owner release"); poll(); empty();
        System.out.println("PASS L2_SOURCE real capacity/source atomicity/prefix-six-edge-prefix/actual MOVE22 and Keyboard.next");

        compat(78, true); poll(); empty(); check(Keyboard.isKeyDown(Keyboard.KEY_N), "compat native held before pressure UP");
        fillPressure(8); compat(78, false); check(sourceSnapshot()[3] == 1, "real Source defers terminal after void JNI UP");
        for (int i = 0; i < 4 && Keyboard.isKeyDown(Keyboard.KEY_N); i++) { poll(); empty(); }
        check(!Keyboard.isKeyDown(Keyboard.KEY_N) && sourceSnapshot()[3] == 0, "no new input actual L2 pull drains deferred UP");
        System.out.println("PASS L2_SOURCE no-new-input actual consumer drains deferred Source terminal");

        Mouse.setGrabbed(false); touch = accepted(acquire(1, "old-target", new int[]{-1}), "old target mouse source"); poll(); empty();
        armTargetReentry(); check(release(touch)[1] == 1, "old target source retirement"); poll();
        // reentry中新来源晚于原frame fence；下一次真实pull才有权领取它，不能跨fence抢读。
        poll();
        check(Mouse.isButtonDown(0), "new target same-code source remains held after old completion reentry="+targetReentryCalls+
            " source="+java.util.Arrays.toString(sourceSnapshot())+" control="+java.util.Arrays.toString(controls())+" trace="+java.util.Arrays.toString(takeTransportTrace()));
        System.out.println("PASS L2_SOURCE original target retirement does not complete stale UP into new same-code source");
        // 真window destroy同时关闭原control/Keyboard/Mouse，再创建新消费资源。
        // 原pair还未pump；bridge的原activation cutoff必须使它不能落到新target。
        ownedTextBegin();check(ownedTextTap()[1]==1,"owned accepted before target destroy");
        display.destroyWindow();Keyboard.destroy();Mouse.destroy();restoreWindow();create();
        ownedEdges.clear();for(int i=0;i<4;i++){poll();ownedEdges.addAll(keyEdges());}
        check(!ownedEdges.contains(Keyboard.KEY_BACK)&&!ownedEdges.contains(-Keyboard.KEY_BACK)&&
            !Keyboard.isKeyDown(Keyboard.KEY_BACK)&&ownedTextTap()[1]==0,"old owned pair never adopts recreated target edges="+ownedEdges+
            " held="+Keyboard.isKeyDown(Keyboard.KEY_BACK)+" tap="+java.util.Arrays.toString(ownedTextTap())+
            " trace="+java.util.Arrays.toString(takeTransportTrace()));
        System.out.println("PASS L2_SOURCE unpumped accepted owned pair cancelled by actual window/consumer retirement");
        System.out.println("L2_SOURCE_PRODUCTION_PASS actual Source/bridge/JNI/JAR/Keyboard-Mouse cache-next; no game tick or device claim");
    }
}
