package com.amcl.launcher;

import java.lang.reflect.Field;
import java.util.ArrayDeque;
import java.util.Queue;
import java.util.List;
import java.util.ArrayList;
import java.util.concurrent.Executor;
import java.util.concurrent.Future;
import java.util.concurrent.FutureTask;
import java.util.concurrent.atomic.AtomicBoolean;

/** 执行生产GUI桥，只替换游戏提供的对象和调度器；覆盖异步回执、过期页面及旧版整数字段。 */
public final class GameGuiBridgeTest {
    private static int passed;
    public static void main(String[] args) throws Exception {
        check(GameGuiBridge.configure("26.4-snapshot-1"),"accept real version");
        check(!GameGuiBridge.configure("1.20.1"),"reject process version replacement");
        check(GameGuiBridge.bind(Game.class),"bind actual initialized fixture singleton");
        Game game=Game.INSTANCE;
        double[] before=GameGuiBridge.poll(100,100);
        check(before[0]==0 && game.queue.size()==1,"read is queued, not executed on caller");
        GameGuiBridge.poll(100,100); GameGuiBridge.poll(100,100);
        check(game.queue.size()==1,"one in-flight read only");
        game.run();
        double[] state=sample(game);
        check(state[0]==2 && state[1]==4 && state[2]==4,"read effective and requested scale");
        check(state[3]==1920 && state[4]==1080,"actual framebuffer wins over fallback");
        check(state[9]==1 && state[7]==1,"restore is explicit menu capability");
        check(GameGuiBridge.restoreScoped(2,(long)state[8],1)==0,"scoped restore refuses absent actual Native guard");
        state[1]=55;
        check(sample(game)[1]==4,"caller cannot mutate shared snapshot");

        // 使用翻译键与当前按钮几何验证生产导航，不把夹具文字或固定屏幕位置当真实目标。
        GuideButton guideButton=new GuideButton("menu.options",34,70,150,20);
        game.screen.children.add(guideButton);
        double[] navigation=sampleGuide(game);
        check(navigation.length==19 && navigation[13]==1 && navigation[14]==34 && navigation[16]==150,
            "guide reads actual options key and geometry from active screen");
        guideButton.visible=false;
        check(sampleGuide(game)[13]==0,"invisible button cannot become navigation target");
        guideButton.visible=true;guideButton.message=new GuideMessage("options.video");guideButton.x=200;
        navigation=sampleGuide(game);
        check(navigation[13]==2 && navigation[14]==200,"video target follows actual relocated button");
        check(sample(game)[13]==0,"ordinary GUI poll clears guidance and avoids widget scanning");

        // 1.21.11真实失败形状：暂停页静态短名遮住Screen.children，按钮子类短名遮住基类坐标，两个b()返回类型不同。
        // 仅提供游戏成员映射元数据，导航、声明根解析和返回类型判断仍执行原生产实现。
        Field adapterField=GameGuiBridge.class.getDeclaredField("adapter");adapterField.setAccessible(true);
        Object adapter=adapterField.get(null);Field namesField=adapter.getClass().getDeclaredField("navigationNames");namesField.setAccessible(true);
        namesField.set(adapter,new String[]{"children","getMessage","x","y","width","height","getContents","getKey","unknown-video",
            "active","visible",Screen.class.getName(),GuideButton.class.getName()});
        game.screen=new ShadowScreen();GuideButton shadowButton=new ShadowButton("menu.options",45,90,150,20);
        game.screen.children.add(shadowButton);
        navigation=sampleGuide(game);
        check(navigation[13]==1 && navigation[14]==45 && navigation[15]==90,
            "obfuscated declaration roots avoid subclass static and instance name shadows");
        String[] fixtureNames=(String[])namesField.get(adapter);fixtureNames[6]="b";fixtureNames[7]="b";
        shadowButton.message=new AmbiguousMessage("options.video");navigation=sampleGuide(game);
        check(navigation[13]==2,"same obfuscated getter name follows actual ComponentContents return type");
        ((ShadowScreen)game.screen).unrelated=123;
        check(sampleGuide(game)[14]==45,"unrelated shadow field remains unrelated to actual widget geometry");
        namesField.set(adapter,null);game.screen=new Screen();

        long revision=(long)sample(game)[8];
        long id=GameGuiBridge.restore(2,revision);
        check(id>0 && game.options.guiScale.get()==4,"restore acknowledgement waits for game thread");
        game.run(); state=sample(game);
        check(state[1]==2 && state[2]==2 && state[10]==id && state[11]==2,"successful restore has result and new geometry");
        // 现代Screen.resize只重排位置，按钮可能仍缓存旧档位；恢复必须同时刷新当前页面的控件值。
        check(game.screen.list.guiButton.value==2 && game.screen.rebuilds==0,
            "restored option refreshes the original widget without duplicating retained layout");
        check(game.screen.list.unrelatedButton.value==7,"GUI restore leaves unrelated option widgets alone");
        check(game.options.saves==1,"saved exactly once");
        check(GameGuiBridge.restore(1,revision)==0,"old revision rejected before enqueue");

        revision=(long)state[8]; id=GameGuiBridge.restore(3,revision);
        game.screen=new Screen(); game.run(); state=sample(game);
        check(state[11]==3 && game.options.guiScale.get()==2,"new screen cancels queued restore");
        revision=(long)state[8]; id=GameGuiBridge.restore(3,revision);
        game.options.guiScale.set(1); game.resizeGui(); game.run(); state=sample(game);
        check(state[11]==3 && state[1]==1,"user's newer scale is not overwritten");
        game.screen=null; state=sample(game);
        check(state[7]==0 && GameGuiBridge.restore(4,(long)state[8])==0,"gameplay cannot restore GUI");
        game.screen=new Screen(); game.options.guiScale.set(3); game.resizeGui(); state=sample(game);
        game.failResize=true;
        check(GameGuiBridge.restore(2,(long)state[8])>0,"failure case queued");
        game.run();
        check(game.options.guiScale.get()==3,"resize failure attempts rollback of option");
        game.failResize=false; state=sample(game);
        check(state[11]==-1,"failure is not reported as success");
        check(GameGuiBridge.restore(-1,(long)state[8])==0 && GameGuiBridge.restore(65,(long)state[8])==0,"invalid scale rejected");
        int original=game.options.guiScale.get();
        check(GameGuiBridge.restore(2,(long)state[8])>0,"delayed request queued");
        Field deadline=GameGuiBridge.class.getDeclaredField("restoreDeadline"); deadline.setAccessible(true); deadline.setLong(null,0);
        check(GameGuiBridge.poll(100,100)[11]==3,"expired queue reports failure without waiting for game thread");
        game.run();check(game.options.guiScale.get()==original,"expired task cannot change GUI after it finally runs");

        resetFixture();
        check(GameGuiBridge.configure("1.12.2") && GameGuiBridge.bind(LegacyGame.class),"legacy scheduled Runnable supported");
        LegacyGame old=LegacyGame.INSTANCE;
        GameGuiBridge.poll(1280,720); old.run();
        double[] legacy=GameGuiBridge.poll(1280,720); old.run();
        check(legacy[1]==3 && legacy[2]==3 && legacy[5]==427,"legacy reads screen dimensions");
        check(GameGuiBridge.restore(1,(long)legacy[8])>0,"legacy restore queued");
        old.run(); legacy=GameGuiBridge.poll(1280,720); old.run();
        check(legacy[1]==1 && old.reopens==1 && old.gameSettings.saves==1,"legacy rebuild/save use existing game API");
        check(GameGuiBridge.calculateScale(1920,1080,0,false)==4,"auto scale algorithm");
        check(GameGuiBridge.calculateScale(1920,1080,3,true)==4,"Unicode even scale");
        check(GameGuiBridge.calculateScale(640,480,12,false)==2,"manual scale clamps to viewport");
        check(GameGuiBridge.calculateLegacyScale(1280,720,3,true)==2,"legacy Unicode rounds down");
        check(GameGuiBridge.calculateLegacyScale(640,480,1,true)==1,"legacy Unicode keeps scale one");
        System.out.println("Results: "+passed+" passed, 0 failed");
    }
    private static double[] sample(Game game) {
        double[] result=GameGuiBridge.poll(100,100); game.run();
        result=GameGuiBridge.poll(100,100); game.run(); return result;
    }
    /** 同生产入口请求一次教学观察；其它GUI回归仍使用兼容的两参数调用。 */
    private static double[] sampleGuide(Game game) {
        GameGuiBridge.poll(100,100,true);game.run();
        double[] result=GameGuiBridge.poll(100,100,true);game.run();return result;
    }
    private static void check(boolean value,String name) {
        if(!value) throw new AssertionError(name); passed++;
    }
    /** 测试进程依次模拟两个独立游戏进程，清理静态宿主；不替换生产读写/恢复方法。 */
    private static void resetFixture() throws Exception {
        for(String name:new String[]{"adapter","lastScreen"}) { Field f=GameGuiBridge.class.getDeclaredField(name); f.setAccessible(true); f.set(null,null); }
        for(String name:new String[]{"revision","requestId"}) { Field f=GameGuiBridge.class.getDeclaredField(name); f.setAccessible(true); f.setLong(null,0); }
        Field state=GameGuiBridge.class.getDeclaredField("state"); state.setAccessible(true); state.set(null,new double[13]);
        Field version=GameGuiBridge.class.getDeclaredField("gameVersion"); version.setAccessible(true); version.set(null,"");
        Field queued=GameGuiBridge.class.getDeclaredField("QUEUED"); queued.setAccessible(true); ((AtomicBoolean)queued.get(null)).set(false);
    }
    public static final class Option<T> {
        private T value;
        Option(T value) { this.value=value; }
        public T get() { return value; }
        public void set(T value) { this.value=value; }
    }
    public static final class Options {
        public Option<Integer> guiScale=new Option<Integer>(4);
        int saves;
        public void save() { saves++; }
    }
    public static final class Window {
        public int framebufferWidth=1920,framebufferHeight=1080,guiScaledWidth=480,guiScaledHeight=270;
        public double guiScale=4;
    }
    /** 模拟现代Screen的独立控件缓存；单纯窗口resize不能偷偷替测试同步这一值。 */
    public static class Screen {
        public int width=427,height=240;
        public OptionsList list=new OptionsList();
        public List<Object> children=new ArrayList<Object>();
        int rebuilds;
        // 真实OptionsSubScreen的布局对象跨init保留；重复init不等于替换旧按钮，不能把夹具写成理想行为。
        protected void rebuildWidgets() { rebuilds++; }
    }
    /** 模拟游戏既存按钮、Component和翻译内容；不替换桥的成员查找或语义识别逻辑。 */
    public static class GuideButton {
        public int x,y,width,height;
        public boolean active=true,visible=true;
        GuideMessage message;
        GuideButton(String key,int px,int py,int w,int h) { message=new GuideMessage(key);x=px;y=py;width=w;height=h; }
        public GuideMessage getMessage() { return message; }
    }
    public static class GuideMessage {
        GuideContents contents;
        GuideMessage(String key) { contents=new GuideContents(key); }
        public GuideContents getContents() { return contents; }
    }
    public static class GuideContents {
        String key;
        GuideContents(String value) { key=value; }
        public String getKey() { return key; }
    }
    /** 静态同名常量与基类children列表不是同一语义；通过父类型保留真实列表。 */
    public static final class ShadowScreen extends Screen { public static int children=8;int unrelated; }
    /** 子类自己的同名坐标不能替代AbstractWidget声明的实际矩形。 */
    public static final class ShadowButton extends GuideButton {
        public int x=999,y=999;
        ShadowButton(String key,int px,int py,int w,int h) { super(key,px,py,w,h); }
    }
    /** 模拟1.20.4以后两个不同对象上的b()，生产桥不能先把ComponentContents强转为String。 */
    public static final class AmbiguousMessage extends GuideMessage {
        AmbiguousMessage(String key) { super(key);contents=new AmbiguousContents(key); }
        public GuideContents b() { return contents; }
    }
    public static final class AmbiguousContents extends GuideContents {
        AmbiguousContents(String key) { super(key); }
        public String b() { return key; }
    }
    /** 列表按OptionInstance身份查找；只有GUI选项的原按钮允许同步，不遍历并修改所有同类型控件。 */
    public static final class OptionsList {
        final Cycle<Integer> guiButton=new Cycle<Integer>(4);
        final Cycle<Integer> unrelatedButton=new Cycle<Integer>(7);
        public Cycle<Integer> findOption(Option<?> option) { return option==Game.INSTANCE.options.guiScale ? guiButton : null; }
    }
    /** 模拟循环按钮自有值；setValue不反向写设置或制造用户点击。 */
    public static final class Cycle<T> {
        T value;
        Cycle(T initial) { value=initial; }
        public void setValue(T next) { value=next; }
    }
    public static final class Game implements Executor {
        static final Game INSTANCE=new Game();
        public Options options=new Options(); public Screen screen=new Screen();
        private Window window=new Window(); final Queue<Runnable> queue=new ArrayDeque<Runnable>();
        boolean failResize;
        public Window getWindow() { return window; }
        public boolean isEnforceUnicode() { return false; }
        public void resizeGui() {
            if(failResize) throw new IllegalStateException("fixture resize failure");
            int s=GameGuiBridge.calculateScale(window.framebufferWidth,window.framebufferHeight,options.guiScale.get(),false);
            window.guiScale=s; window.guiScaledWidth=(int)Math.ceil(1920.0/s); window.guiScaledHeight=(int)Math.ceil(1080.0/s);
        }
        public void execute(Runnable task) { queue.add(task); }
        void run() { while(!queue.isEmpty()) queue.remove().run(); }
    }
    public static final class LegacyOptions {
        public int guiScale=3; public boolean forceUnicodeFont=false; int saves;
        public void saveOptions() { saves++; }
    }
    public static final class LegacyGame {
        static final LegacyGame INSTANCE=new LegacyGame();
        public LegacyOptions gameSettings=new LegacyOptions(); public Screen currentScreen=new Screen();
        public int displayWidth=1280,displayHeight=720;
        final Queue<Runnable> queue=new ArrayDeque<Runnable>(); int reopens;
        public Future<Object> schedule(Runnable task) { FutureTask<Object> future=new FutureTask<Object>(task,null); queue.add(future); return future; }
        public void displayGuiScreen(Screen screen) {
            reopens++; currentScreen=screen;
            int s=GameGuiBridge.calculateScale(1280,720,gameSettings.guiScale,false);
            screen.width=(int)Math.ceil(1280.0/s); screen.height=(int)Math.ceil(720.0/s);
        }
        void run() { while(!queue.isEmpty()) queue.remove().run(); }
    }
}
