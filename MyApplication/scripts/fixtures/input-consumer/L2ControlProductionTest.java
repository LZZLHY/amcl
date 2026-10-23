package org.lwjgl.opengl;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import org.lwjgl.input.Keyboard;
import org.lwjgl.input.Mouse;

/**
 * 真实上游Keyboard/Mouse/Display、实际AMCLDisplay/JNI及neutral owner的生产闭包。
 * 平台来源只替换外部窗口/光标/五整数运输，游戏读取类、Java EventQueue和归约均原样执行。
 * 每项断言核实际next/poll与原consumer计数，不能用入队数量冒充游戏领取。
 */
public final class L2ControlProductionTest implements Runnable {
    private static AMCLDisplay display;
    private static native void publish(boolean valid);
    private static native void push(int type, int a, int b, int c, int d);
    private static native void armReentry(int mode);
    private static native void restoreWindow();
    private static int workerMode;
    private static Throwable workerError;

    /** 使用完整公开poll/next/getter在另一线程执行；上游GlobalLock是原有序列边界。 */
    public void run() {
        try {
            boolean down=workerMode==1;
            Keyboard.poll(); Mouse.poll();
            check(Keyboard.isKeyDown(Keyboard.KEY_Z)==down,"cross-thread legacy poll must update actual keyboard cache");
            check(Mouse.isButtonDown(3)==down,"cross-thread legacy poll must update actual mouse cache");
            check(Keyboard.next() && Keyboard.getEventKey()==Keyboard.KEY_Z && Keyboard.getEventKeyState()==down,"cross-thread actual Keyboard.next");
            check(Mouse.next() && Mouse.getEventButton()==3 && Mouse.getEventButtonState()==down,"cross-thread actual Mouse.next");
            check((Long)call("nControlOpen",new Class<?>[0])==handle(),"GlobalLock read thread reuses original live consumer");
        } catch(Throwable failure) { workerError=failure; }
    }

    /** start/join提供真实JMM发布/完成；此fixture不并行修改生产状态或模拟owner判断。 */
    private static void worker(int mode) throws Exception {
        workerMode=mode; workerError=null;
        Thread thread=new Thread(new L2ControlProductionTest()); thread.start(); thread.join();
        if(workerError!=null) throw new AssertionError(workerError);
    }

    /** 只用于触发真实JNI光标边界的同步Java重入；不替换生产归约或ticket验证。 */
    public static void reenter(int mode) throws Exception {
        if (mode == 1) call("applyMousePlane", new Class<?>[]{int.class,int.class,int.class}, 2,0,1);
        else if (mode == 2) display.destroyWindow();
    }

    private static Object call(String name, Class<?>[] parameters, Object... args) throws Exception {
        Method method = AMCLDisplay.class.getDeclaredMethod(name, parameters);
        method.setAccessible(true);
        return method.invoke(display, args);
    }

    private static long handle() throws Exception {
        Field field=AMCLDisplay.class.getDeclaredField("controlConsumer"); field.setAccessible(true);
        return field.getLong(display);
    }

    private static long[] snapshot() throws Exception {
        long[] values=new long[14];
        int result=(Integer)call("nControlSnapshot",new Class<?>[]{long.class,long[].class},handle(),values);
        check(result==0,"snapshot requires live original consumer"); return values;
    }

    private static void check(boolean value,String message) {
        if(!value) throw new AssertionError(message);
    }

    private static void key(int plane,int code,int action) { push(plane==1?1005:2005,code,37,action,0); }
    private static void button(int plane,int code,int action) { push(plane==1?1006:2006,code,action,0,0); }
    /** 原五整数位载荷编码；实际AMCLDisplay负责解码冻结坐标，不用最终全局坐标替代。 */
    private static void position(double x,double y) {
        long xb=Double.doubleToRawLongBits(x),yb=Double.doubleToRawLongBits(y);
        push(1010,(int)xb,(int)(xb>>>32),(int)yb,(int)(yb>>>32));
    }
    private static void emptyKeyboard() { while(Keyboard.next()) {} }
    private static void emptyMouse() { while(Mouse.next()) {} }

    public static void main(String[] args) throws Exception {
        System.load(args[0]); publish(false);
        display=new AMCLDisplay();
        boolean refused=false;
        try { display.createKeyboard(); } catch(org.lwjgl.LWJGLException expected) { refused=true; }
        check(refused,"bad descriptor must fail, never fixed-Edge/fallback owner");
        publish(true);
        // 上游私有create(InputImplementation)正是AWT反射允许入口；保留完整真实创建/poll/read。
        Method keyboardCreate=Keyboard.class.getDeclaredMethod("create",InputImplementation.class);
        keyboardCreate.setAccessible(true); keyboardCreate.invoke(null,display);
        Method mouseCreate=Mouse.class.getDeclaredMethod("create",InputImplementation.class);
        // 输入闭包只替外部窗口，没有执行GL context的Display.create；使用上游公开开关
        // 关闭其零尺寸窗口裁剪，避免把真实序列化坐标截成-1。事件解析/队列均保持生产实现。
        Mouse.setClipMouseCoordinatesToWindow(false);
        mouseCreate.setAccessible(true); mouseCreate.invoke(null,display);

        key(1,65,1); key(2,Keyboard.KEY_A,1); Keyboard.poll();
        long[] stats=snapshot();
        check(stats[2]==2 && stats[3]==1 && stats[4]==1,"legacy+typed share neutral first-down");
        check(stats[6]==0 && stats[7]==1,"enqueue/copy must not commit game pull");
        check(Keyboard.getNumKeyboardEvents()==1 && snapshot()[6]==0,"peek must remain readonly");
        long pollReads=snapshot()[8];
        check(Keyboard.isKeyDown(Keyboard.KEY_A),"actual poll cache held");
        check(snapshot()[8]==pollReads+1 && snapshot()[9]==0,"actual isKeyDown counts original consumer");
        check(Keyboard.next() && Keyboard.getEventKey()==Keyboard.KEY_A && Keyboard.getEventKeyState(),"legacy encoded once, typed unchanged");
        check(snapshot()[6]==1,"only actual next commits pull");
        push(1009,0,0,0,0); Keyboard.poll();
        check(Keyboard.isKeyDown(Keyboard.KEY_A) && !Keyboard.next(),"legacy reset keeps typed owner");
        key(2,Keyboard.KEY_A,0); Keyboard.poll();
        check(Keyboard.next() && !Keyboard.getEventKeyState(),"last neutral owner releases once");
        check(!Keyboard.next(),"no duplicate release");
        System.out.println("L2 real owner/once encoding/poll/readonly peek/next: PASS");

        long[] beforeWorker=snapshot();
        key(1,90,1); button(1,3,1); worker(1);
        key(1,90,0); button(1,3,0); worker(2);
        long[] afterWorker=snapshot();
        check(afterWorker[2]==beforeWorker[2]+4 && afterWorker[6]==beforeWorker[6]+4 &&
            afterWorker[7]==beforeWorker[7]+4,"cross-thread serialized producer/cache/actual reads remain true facts");
        check(afterWorker[8]==beforeWorker[8]+8 && afterWorker[9]==0,"cross-thread readonly scalar and bulk poll count real calls");
        System.out.println("L2 real GlobalLock cross-thread Keyboard/Mouse poll/next/consumer: PASS");

        long pulls=snapshot()[6];
        key(2,Keyboard.KEY_B,1); key(2,Keyboard.KEY_B,0); Keyboard.poll();
        check(!Keyboard.isKeyDown(Keyboard.KEY_B),"short pulse final poll state up");
        check(Keyboard.next() && Keyboard.getEventKeyState(),"legal queued short DOWN survives newer revision");
        check(Keyboard.next() && !Keyboard.getEventKeyState(),"short UP follows DOWN");
        check(snapshot()[6]==pulls+2,"short pulse actual reads counted");
        key(2,Keyboard.KEY_C,1); key(2,Keyboard.KEY_C,2); key(2,Keyboard.KEY_C,0); Keyboard.poll();
        long discarded=snapshot()[13];
        check(Keyboard.next() && Keyboard.getEventKeyState(),"repeat sequence starts down");
        check(Keyboard.next() && !Keyboard.getEventKeyState(),"filtered repeat cannot mask release");
        check(snapshot()[13]==discarded+1,"disabled repeat reports discard, not returned event");
        push(1000,0x4e2d,0,0,0); Keyboard.poll();
        check(Keyboard.next() && Keyboard.getEventCharacter()==0x4e2d,"character byte record preserved");
        System.out.println("L2 short pulse/repeat/character: PASS");

        // 真实EventQueue容量200；先填非control字符，再入DOWN使putEvent返回false。
        for(int i=0;i<200;i++) push(1000,65,0,0,0);
        key(2,Keyboard.KEY_D,1); Keyboard.poll();
        check(Keyboard.isKeyDown(Keyboard.KEY_D),"queuefalse retains real polling cache");
        check(snapshot()[13]>=discarded+2,"real queue false reports discarded ticket");
        for(int i=0;i<5;i++) { emptyKeyboard(); Keyboard.poll(); }
        key(2,Keyboard.KEY_D,0); Keyboard.poll();
        check(Keyboard.next() && !Keyboard.getEventKeyState(),"failed enqueue never removes neutral owner");
        System.out.println("L2 real EventQueue false/cache/owner retention: PASS");

        button(2,0,1); key(2,Keyboard.KEY_E,1); Mouse.poll(); Keyboard.poll();
        long beforeDestroy=snapshot()[6];
        Keyboard.destroy();
        check(Mouse.isButtonDown(0),"destroyKeyboard cannot retire mouse kind");
        check(Mouse.next() && Mouse.getEventButtonState(),"keyboard destroy preserves mouse pending record");
        check(snapshot()[6]==beforeDestroy+1,"independent consumer kind read still counts");
        keyboardCreate.invoke(null,display);
        button(2,0,0); Mouse.poll(); check(Mouse.next() && !Mouse.getEventButtonState(),"mouse owner releases after keyboard recreate");
        System.out.println("L2 independent Keyboard/Mouse lifetime: PASS");

        button(1,0,1); button(2,1,1); Mouse.poll();
        push(1009,0,0,0,0); Mouse.poll();
        check(Mouse.isButtonDown(1) && !Mouse.isButtonDown(0),"local reset changes only selected owner cache");
        check(Mouse.next() && Mouse.getEventButton()==0 && Mouse.getEventButtonState(),"local reset preserves old legitimate first down");
        check(Mouse.next() && Mouse.getEventButton()==1 && Mouse.getEventButtonState(),"local reset preserves sibling queue");
        check(Mouse.next() && Mouse.getEventButton()==0 && !Mouse.getEventButtonState(),"local reset appends own release");
        button(2,1,0); Mouse.poll(); emptyMouse();
        push(2007,0,2,0,0); Mouse.poll();
        check(Mouse.next() && Mouse.getEventDWheel()==240,"wheel22-byte record preserved");
        System.out.println("L2 local reset/sibling queued records/wheel: PASS");

        position(10,20); button(1,0,1); position(300,400); position(350,450); button(1,0,0); Mouse.poll();
        check(Mouse.next() && Mouse.getEventButton()==-1 && Mouse.getEventX()==10 && Mouse.getEventY()==580,"frozen source MOVE");
        check(Mouse.next() && Mouse.getEventButton()==0 && Mouse.getEventButtonState() && Mouse.getEventX()==10 && Mouse.getEventY()==580,"PRESS at source");
        check(Mouse.next() && Mouse.getEventButton()==-1 && Mouse.getEventX()==300 && Mouse.getEventY()==200,"intermediate ordered MOVE");
        check(Mouse.next() && Mouse.getEventButton()==-1 && Mouse.getEventX()==350 && Mouse.getEventY()==150,"frozen endpoint MOVE");
        check(Mouse.next() && Mouse.getEventButton()==0 && !Mouse.getEventButtonState() && Mouse.getEventX()==350 && Mouse.getEventY()==150,"UP at frozen endpoint");
        check(!Mouse.next(),"ordered MOVE records and tickets stay aligned");
        button(1,0,1); Mouse.poll();
        long grabDiscard=snapshot()[13]; Mouse.setGrabbed(true);
        check(!Mouse.next() && Mouse.isButtonDown(0),"real resetMouse discards read record but retains polling owner");
        check(snapshot()[13]==grabDiscard+1,"real resetMouse reports discarded, not game read");
        Mouse.setGrabbed(false); button(1,0,0); Mouse.poll(); emptyMouse();
        System.out.println("L2 ordered frozen MOVE22-byte records/real resetMouse: PASS");

        // 同步JNI光标重入在release phase0之后重获同button，旧UP不能晚排到新DOWN后。
        button(1,0,1); Mouse.poll(); emptyMouse();
        armReentry(1); push(1009,0,0,0,0); Mouse.poll();
        check(Mouse.isButtonDown(0),"reentry owner polling survives stale release completion");
        check(Mouse.next() && Mouse.getEventButtonState(),"reentry emits actual new down");
        check(!Mouse.next(),"stale release must not enqueue after reentrant down");
        button(2,0,0); Mouse.poll(); emptyMouse();
        System.out.println("L2 actual Java->JNI cursor reentry: PASS");

        key(2,Keyboard.KEY_F,1); button(2,0,1); Keyboard.poll(); Mouse.poll();
        long focusPulls=snapshot()[6];
        push(2010,0,0,0,0); Keyboard.poll(); Mouse.poll();
        check(Keyboard.next() && !Keyboard.getEventKeyState(),"full focus retire cancels old unread key DOWN");
        check(Mouse.next() && !Mouse.getEventButtonState(),"full focus retire cancels old unread button DOWN");
        check(snapshot()[6]==focusPulls+2,"focus only commits actual release records");
        check(!Keyboard.next() && !Mouse.next(),"canceled records cannot resurface after compact");
        System.out.println("L2 full focus/readBuffer cancellation/compaction: PASS");

        // 实际JNI光标边界销毁旧窗口；旧release不能改绑后来恢复的真实新consumer。
        button(1,0,1); button(2,1,1); Mouse.poll();
        check(Mouse.next() && Mouse.getEventButton()==0,"target reentry starts with one actual down read");
        long oldConsumer=handle();
        armReentry(2); push(1009,0,0,0,0); Mouse.poll();
        check(!Mouse.next(),"destroy during cursor JNI must reject old target record");
        check((Long)call("nControlOpen",new Class<?>[0])==0,"destroyed window cannot register consumer");
        Mouse.destroy(); Keyboard.destroy(); restoreWindow();
        display=new AMCLDisplay(); keyboardCreate.invoke(null,display); mouseCreate.invoke(null,display);
        check(handle()!=oldConsumer,"new actual window receives nonreused consumer");
        check(!Mouse.next() && !Keyboard.next(),"old target record never rebinds to new consumer");
        System.out.println("L2 actual Java->JNI target-destroy reentry: PASS");

        // 两次DOWN在真实JNI claim后均未写ABI缓存即discard；贡献仍有效但observed为false。
        // 局部UP只撤legacy，typed仍持有，此时实际恢复计划必须是DOWN，不能生成无法claim的UP。
        long[] recoveryTicket=new long[9];
        Class<?>[] recoverySignature={long.class,int.class,int.class,int.class,int.class,int.class,long[].class};
        for(int plane=1;plane<=2;plane++) {
            check((Integer)call("nControlApply",recoverySignature,handle(),plane,1,Keyboard.KEY_K,37,1,recoveryTicket)==1,"discarded owner down prepared by real JNI");
            check((Integer)call("nControlComplete",new Class<?>[]{long[].class,int.class},recoveryTicket,5)==0,"pre-cache real ticket discard");
        }
        check((Integer)call("nControlApply",recoverySignature,handle(),1,1,Keyboard.KEY_K,37,0,recoveryTicket)==1 && recoveryTicket[3]==1,
            "partial UP after both discarded DOWN requires actual recoverable DOWN");
        call("applyEmission",new Class<?>[]{long[].class},(Object)recoveryTicket.clone());
        Keyboard.poll();
        check(Keyboard.isKeyDown(Keyboard.KEY_K) && Keyboard.next() && Keyboard.getEventKeyState(),"recovery passes actual Java cache/event/next");
        key(2,Keyboard.KEY_K,0); Keyboard.poll();
        check(!Keyboard.isKeyDown(Keyboard.KEY_K) && Keyboard.next() && !Keyboard.getEventKeyState(),"remaining owner finally releases recovered cache");
        System.out.println("L2 real JNI pre-cache discard/partial-UP recovery DOWN: PASS");

        // 压力直接经过真实JNI Apply和共同owner：故意不报告缓存/终结，耗尽在途票预算。
        long[] ticket=new long[9];
        Class<?>[] signature={long.class,int.class,int.class,int.class,int.class,int.class,long[].class};
        check((Integer)call("nControlApply",signature,handle(),2,1,Keyboard.KEY_G,3,1,ticket)==1,"pressure first owner down");
        int result=1;
        for(int i=0;i<2200 && result==1;i++) result=(Integer)call("nControlApply",signature,handle(),2,1,Keyboard.KEY_G,3,2,ticket);
        check(result==-3,"real neutral ticket budget yields Pressure");
        check((Integer)call("nControlApply",signature,handle(),2,1,Keyboard.KEY_H,3,1,ticket)==-3,"pressure cannot silently accept new owner");
        display.destroyWindow();
        check((Integer)call("nControlApply",signature,handle(),2,1,Keyboard.KEY_H,3,1,ticket)==-2,"retired target/handle stays stale");
        System.out.println("L2 real JNI pressure/target retirement: PASS");
        System.out.println("L2_CONTROL_PRODUCTION_PASS");
    }
}
