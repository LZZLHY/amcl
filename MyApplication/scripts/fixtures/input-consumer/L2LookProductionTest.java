package org.lwjgl.opengl;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import org.lwjgl.input.Keyboard;
import org.lwjgl.input.Mouse;

/** 真Core/两owner/JNI/完整AMCLDisplay与上游Mouse/Keyboard消费轨迹；外部平台事实显式提供。 */
public final class L2LookProductionTest {
    private static AMCLDisplay display;
    private static native void publishLook(boolean valid);
    private static native long prefix(double x,double y,boolean queued);
    private static native void cancelOne();
    private static native void focus(boolean active);
    private static native void futureCursor();
    private static native int cursorReads();
    private static native int retire(long token);
    private static native void keepSibling(long token);
    private static native int latencyDrain(long[] output);

    /** 实际fixture运输入口来自原P3五int记录，prefix全部由正式owner生成。 */
    private static void push(int type,int a,int b,int c,int d)throws Exception {
        Method method=L2ControlProductionTest.class.getDeclaredMethod("push",int.class,int.class,int.class,int.class,int.class);
        method.setAccessible(true);method.invoke(null,type,a,b,c,d);
    }
    /** 只窥原实例private identity与正式JNI snapshot，不复制或替代consumer状态。 */
    private static long handle()throws Exception {
        Field field=AMCLDisplay.class.getDeclaredField("controlConsumer");field.setAccessible(true);return field.getLong(display);
    }
    /** 原consumer的私有只读快照，不推进prefix、claim或transport游标。 */
    private static long[] snapshot()throws Exception {
        long[] out=new long[16];Method method=AMCLDisplay.class.getDeclaredMethod("nLookSnapshot",long.class,long[].class);
        method.setAccessible(true);check((Integer)method.invoke(null,handle(),out)==0,"actual look snapshot");return out;
    }
    /** 外层只接受L2_LOOK行为断言，初始化、链接与工具失败保持明确异常。 */
    private static void check(boolean value,String message){if(!value)throw new AssertionError("L2_LOOK "+message);}
    /** 使用原允许的反射创建边缘，之后只走完整公开Mouse/Keyboard poll/next/getter。 */
    private static void create(int kind)throws Exception {
        Class<?> type=kind==1?Keyboard.class:Mouse.class;Method method=type.getDeclaredMethod("create",InputImplementation.class);
        method.setAccessible(true);method.invoke(null,display);
    }
    /** 通过真实公开next清空当前鼠标队列；不直接编辑EventQueue或旁带。 */
    private static void mouseEmpty(){while(Mouse.next()){} }
    /** 通过真实公开next清空当前键盘队列；键鼠队列独立，不能按游戏全序互相等待。 */
    private static void keyboardEmpty(){while(Keyboard.next()){} }

    /** 真正collector导出只读值；不读取或改写诊断表，不构造完成票。 */
    private static long[] latencyOne(long token, int outcome, boolean terminal)throws Exception {
        long[] rows = new long[64];
        int count = latencyDrain(rows);
        // 原前序业务测试还含未claim的错token/closed-resource材料；模式退休会合法导出它们。
        // 按本测试实际producer返回token精确匹配，不把一次drain的其它历史记录贴给当前票。
        int matching = 0, at = -1;
        for (int i = 0; i < count; i++) {
            System.out.println("L2_LATENCY_DRAIN pfx=" + rows[i*8] + " outcome=" + rows[i*8+2] + " mask=" + rows[i*8+3]);
            if (rows[i*8] == token) { matching++; at = i*8; }
        }
        check(matching == 1 && rows[at+1] != 0 && rows[at+2] == outcome,
            "latency original prefix ticket terminal count=" + count + " expected=" + token + "/" + outcome);
        check(rows[at+4] == handle() && rows[at+5] != 0 && rows[at+6] != 0 && rows[at+7] == 0,
            "latency original consumer activation target");
        check((rows[at+3] & 16) != 0 && ((rows[at+3] & 32) != 0) == terminal,
            "latency real cache and poll view points");
        // 外部五int夹具没有neutral ring：未观察的两段必须继续缺失，不能拿新seq补戳。
        check((rows[at+3] & 12) == 0, "latency no fabricated enqueue read");
        return rows;
    }

    /** 原公共API在诊断OFF/foreign也执行同一消费；仅ON检查真实接缝和原票。 */
    private static void testLatency()throws Exception {
        String mode = System.getProperty("amcl.test.latency", "off");
        Field capability = AMCLDisplay.class.getDeclaredField("lookLatencyAvailable");
        capability.setAccessible(true);
        boolean enabled = capability.getBoolean(display);
        check(enabled == "on".equals(mode), "latency optional cold capability");
        long[] rows = new long[64]; while (latencyDrain(rows) != 0) { }
        Mouse.getDX(); Mouse.getDY(); mouseEmpty();
        long first = prefix(4, 0, true); Keyboard.poll();
        if (enabled) check(latencyDrain(rows) == 0, "latency cache must wait for actual poll view");
        Mouse.poll(); check(Mouse.getDX() == 4, "latency optional diagnostic preserves motion");
        if (enabled) latencyOne(first, 10, true);
        mouseEmpty();
        long overwritten = prefix(2, 0, true), pending = prefix(3, 0, true);
        Keyboard.poll();
        if (enabled) latencyOne(overwritten, 12, false);
        Mouse.poll(); check(Mouse.getDX() == 5, "latency overwrite does not lose business motion");
        if (enabled) latencyOne(pending, 10, true);
        mouseEmpty();
        long retired = prefix(6, 0, true); Keyboard.poll();
        Mouse.setGrabbed(false);
        // 锁定上游 Mouse.java 先implementation.grabMouse再poll；旧mode原未读影子已
        // 退休，后面菜单坐标poll不能替它补终点。不得按仅有poll这个名称推断先后。
        if (enabled) latencyOne(retired, 14, false);
        Mouse.setGrabbed(true);
        retired = prefix(7, 0, true); Keyboard.poll();
        Mouse.destroy();
        if (enabled) latencyOne(retired, 14, false);
        create(2); prefix(1, 0, true); Mouse.poll();
        check(Mouse.getDX() == 1, "latency Mouse recreate preserves fresh business motion");
        if (!enabled) {
            int count;
            while ((count = latencyDrain(rows)) != 0) {
                for (int i = 0; i < count; i++)
                    check((rows[i*8+3] & 48) == 0 && rows[i*8+2] != 10 && rows[i*8+2] != 12,
                        "latency OFF foreign cannot fabricate cache or consumer terminal");
            }
        }
        System.out.println("L2_LATENCY_CONSUMER_PASS mode=" + mode +
            " actual collector cache/poll-view/overwrite/mode/Mouse lifetime; external five-int transport, no six-point or product getter claim");
    }

    /** 每次独立JVM执行真实descriptor拒绝、prefix/cache/poll/22byte MOVE及生命周期。 */
    public static void main(String[] args)throws Exception {
        System.load(args[0]);publishLook(false);display=new AMCLDisplay();
        boolean denied=false;try{display.createKeyboard();}catch(org.lwjgl.LWJGLException expected){denied=true;}
        check(denied,"bad independent look getter must not borrow control-v1 as capability");
        publishLook(true);create(1);Mouse.setClipMouseCoordinatesToWindow(false);create(2);Mouse.setGrabbed(true);
        mouseEmpty();keyboardEmpty();Mouse.getDX();Mouse.getDY();
        long originalHandle=handle();long[] before=snapshot();

        prefix(10.8,0.4,true);push(1006,0,1,0,0);prefix(6.48,1.1,true);push(1006,0,0,0,0);
        push(2005,Keyboard.KEY_A,0,1,0);push(2005,Keyboard.KEY_A,0,0,0);
        Keyboard.poll();long[] after=snapshot();
        check(after[7]==before[7]+2&&after[9]==0,"cache final is actual availability, never fake MOVE next");
        check(Keyboard.next()&&Keyboard.getEventKey()==Keyboard.KEY_A&&Keyboard.getEventKeyState(),"independent actual Keyboard.next DOWN");
        check(Keyboard.next()&&!Keyboard.getEventKeyState(),"independent Keyboard UP cannot wait for Mouse.next");
        Mouse.poll();check(Mouse.getDX()==17&&Mouse.getDY()==-1,"actual poll integer truncation/fraction retained");
        check(Mouse.next()&&Mouse.getEventButton()==-1&&Mouse.getEventDX()==10&&Mouse.getEventDY()==0,"first immutable MOVE22");
        check(Mouse.next()&&Mouse.getEventButton()==0&&Mouse.getEventButtonState(),"actual Mouse.next DOWN between prefixes");
        check(Mouse.next()&&Mouse.getEventButton()==-1&&Mouse.getEventDX()==7&&Mouse.getEventDY()==-1,"future immutable MOVE22 independent remainder");
        check(Mouse.next()&&Mouse.getEventButton()==0&&!Mouse.getEventButtonState()&&!Mouse.next(),"actual Mouse.next final UP");

        int reads=cursorReads();futureCursor();Mouse.poll();check(Mouse.getDX()==0&&Mouse.getDY()==0,"future global cursor cannot fabricate world motion");
        check(cursorReads()==reads,"grabbed poll must not query latest cursor snapshot");
        long token=prefix(2.8,0.2,true);before=snapshot();Mouse.poll();after=snapshot();
        check(Mouse.getDX()==3&&after[7]==before[7]+1&&after[10]==before[10]+1,"poll-only cache plus actual upstream poll hook");
        check(retire(token)==0,"poll-only final must not wait forever for queue next");
        check(Mouse.next()&&Mouse.getEventDX()==3&&!Mouse.next(),"MOVE remains original valid ABI bytes after owner GC");

        token=prefix(1.2,0,false);before=snapshot();push(1020,(int)token,(int)(token>>>32)+1,0,0);Mouse.poll();
        check(snapshot()[7]==before[7]&&Mouse.getDX()==0,"high token bits must not alias a real low token");
        push(1020,(int)token,(int)(token>>>32),0,0);Mouse.poll();check(Mouse.getDX()==1,"actual full token applied once");mouseEmpty();

        before=snapshot();cancelOne();Mouse.poll();after=snapshot();
        check(Mouse.getDX()==7&&after[7]==before[7]+1&&after[12]>before[12],"retire one source before cache reprepare only sibling");mouseEmpty();
        token=prefix(4,0,true);before=snapshot();focus(false);Mouse.poll();
        check(snapshot()[7]==before[7]&&Mouse.getDX()==0,"actual Core focus retires pending resource");
        focus(true);prefix(2,0,true);Mouse.poll();check(Mouse.getDX()==2,"fresh resource after refocus");mouseEmpty();

        push(2005,Keyboard.KEY_B,0,1,0);Keyboard.poll();keyboardEmpty();
        token=prefix(6,0,false);keepSibling(token);Mouse.destroy();
        check(Keyboard.isKeyDown(Keyboard.KEY_B)&&handle()==originalHandle,"Mouse look closure keeps Keyboard and control identity");
        long closedToken=prefix(5,0,false); // window/Keyboard仍活，真实Mouse已经关闭，运输位必须为0。
        create(2);push(1020,(int)token,(int)(token>>>32),0,0);Mouse.poll();
        check(Mouse.getDX()==0&&snapshot()[7]==0,"recreated Mouse cannot reclaim cleared receiver of old prefix");
        push(1020,(int)closedToken,(int)(closedToken>>>32),0,0);Mouse.poll();
        check(Mouse.getDX()==0&&snapshot()[7]==0,"Mouse recreate cannot catch up motion produced while its outlet was closed");
        prefix(3,0,true);Mouse.poll();check(Mouse.getDX()==3,"fresh prefix after actual Mouse recreate");mouseEmpty();
        testLatency();
        System.out.println("L2_LOOK_PRODUCTION_PASS actual JNI owner identity/independent queues/immutable MOVE22/poll-only/source-focus-lifetime; no game camera claim");
    }
}
