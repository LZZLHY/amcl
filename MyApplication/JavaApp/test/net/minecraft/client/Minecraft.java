package net.minecraft.client;

import com.amcl.launcher.GameGuiBridge;
import java.util.Queue;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * JNI组合测试的真实Java游戏对象样本。它只提供已初始化单例、标准成员元数据及实际
 * Executor队列；观察/反射绑定/恢复政策均调用原GameGuiBridge，不替换JNI或桥方法。
 * 显式runTasks模拟游戏线程获得运行机会，blockBridge用真实Java monitor制造worker忙。
 */
public final class Minecraft implements Executor {
    public static final Minecraft INSTANCE=new Minecraft();
    public final Options options=new Options();
    public Screen screen=new Screen();
    private final Window window=new Window();
    private final Queue<Runnable> tasks=new ConcurrentLinkedQueue<Runnable>();
    private static volatile CountDownLatch blocked,release;
    private static volatile CountDownLatch getterBlocked,getterRelease;
    private static volatile int blockGetterAt;
    private static final AtomicInteger getterReads=new AtomicInteger();
    public static final class Option<T> {
        private T value;
        Option(T initial){value=initial;}
        public T get(){
            // 仅在宿主明确装闩后阻塞实际OptionInstance.get边界，不替换桥/Native guard。
            if(blockGetterAt>0 && getterReads.incrementAndGet()==blockGetterAt){
                getterBlocked.countDown();try{getterRelease.await();}catch(InterruptedException interrupted){Thread.currentThread().interrupt();}
            }
            return value;
        }
        public void set(T next){value=next;}
    }
    public static final class Options {
        public final Option<Integer> guiScale=new Option<Integer>(4);
        public int saves;
        public void save(){saves++;}
    }
    public static final class Screen {public int width=480,height=270;}
    public static final class Window {
        public int framebufferWidth=1920,framebufferHeight=1080,guiScaledWidth=480,guiScaledHeight=270;
        public double guiScale=4;
    }
    public Window getWindow(){return window;}
    public boolean isEnforceUnicode(){return false;}
    public void resizeGui(){
        int wanted=options.guiScale.get(),effective=1;
        while(effective!=wanted && 1920/(effective+1)>=320 && 1080/(effective+1)>=240)effective++;
        window.guiScale=effective;window.guiScaledWidth=(int)Math.ceil(1920.0/effective);window.guiScaledHeight=(int)Math.ceil(1080.0/effective);
    }
    public void execute(Runnable task){tasks.add(task);}
    public static void runTasks(){Runnable task;while((task=INSTANCE.tasks.poll())!=null)task.run();}
    public static int queued(){return INSTANCE.tasks.size();}
    public static int scale(){return INSTANCE.options.guiScale.get();}
    public static void chooseScale(int wanted){INSTANCE.options.guiScale.set(wanted);INSTANCE.resizeGui();}
    public static void replaceScreen(){INSTANCE.screen=new Screen();}
    /** 原GUI configure是synchronized，持它的实际Java monitor后worker JNI会真实阻塞。 */
    public static void blockBridge() throws InterruptedException {
        blocked=new CountDownLatch(1);release=new CountDownLatch(1);
        Thread thread=new Thread(new Runnable(){public void run(){
            synchronized(GameGuiBridge.class){blocked.countDown();try{release.await();}catch(InterruptedException interrupted){Thread.currentThread().interrupt();}}
        }},"gui-worker-test-block");
        thread.setDaemon(true);thread.start();blocked.await();
    }
    public static void releaseBridge(){release.countDown();}
    /** 查询stock JVM真实线程状态，不能仅凭Native dispatch计数假定已经进入忙JNI。 */
    public static int blockedObserver(){
        int count=0;
        for(Thread thread:Thread.getAllStackTraces().keySet())
            if(thread.getName().equals("AMCL-GUI-Observer") && thread.getState()==Thread.State.BLOCKED)count++;
        return count;
    }
    public static void armGetterBlock(int read){getterReads.set(0);getterBlocked=new CountDownLatch(1);getterRelease=new CountDownLatch(1);blockGetterAt=read;}
    public static int getterBlocked(){return getterBlocked.getCount()==0?1:0;}
    public static void releaseGetter(){blockGetterAt=0;getterRelease.countDown();}
}
