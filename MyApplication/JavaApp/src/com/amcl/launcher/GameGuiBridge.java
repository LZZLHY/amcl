package com.amcl.launcher;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.List;
import java.util.concurrent.Executor;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 启动器自有GUI设置桥，不变换游戏类、不安装模组，也不访问世界/容器物品。
 * Native只把JVMTI确认已初始化的实际Minecraft类交给bind。GUI数值采集和设置写入均排到游戏线程，
 * ArkUI仅获取一份不可变数值快照；一次最多一个任务，不创建线程或常驻Java计时器。
 * 仅用户确认的小GUI恢复会写设置，并同时验证快照代次和Screen身份，防止迟到请求影响新页面。
 */
public final class GameGuiBridge {
    private GameGuiBridge() {}
    private static final AtomicBoolean QUEUED = new AtomicBoolean();
    private static volatile Adapter adapter;
    // 原13项前缀保持；末6项为只读导航kind/x/y/w/h/scrollable，均为GUI坐标，不发送游戏输入。
    private static volatile double[] state = new double[19];
    private static volatile long revision;
    private static volatile Object lastScreen;
    private static volatile long requestId;
    private static volatile int requestResult;
    private static final AtomicInteger restorePhase=new AtomicInteger();
    private static volatile long restoreDeadline;
    /** Native scoped恢复只从实际helper Class注册。JNI缺席时保只读降级，不能假造资源仍活着。 */
    private static native boolean nativeRequestCurrent(long ticket);
    private static native boolean nativeRestoreBegin(long ticket);

    private static boolean currentNativeRequest(long ticket) {
        if(ticket==0) return true; // 原Java兼容入口仍承担原Screen/revision/原值合同。
        try { return nativeRequestCurrent(ticket); }
        catch(UnsatisfiedLinkError unavailable) { return false; }
    }
    private static boolean beginNativeRestore(long ticket) {
        if(ticket==0) return true;
        try { return nativeRestoreBegin(ticket); }
        catch(UnsatisfiedLinkError unavailable) { return false; }
    }
    private static volatile String gameVersion="";
    private static final String[] PROFILE_VERSIONS={"1.16.5","1.18.2","1.19.4","1.20.1","1.20.4","1.21.1","1.21.11"};

    /** 真实继承根版本由启动器已验证的启动上下文给出；一次游戏进程只允许同一版本身份。 */
    public static synchronized boolean configure(String version) {
        if(version==null || version.length()==0 || version.length()>96) return false;
        if(gameVersion.length()>0) return gameVersion.equals(version);
        gameVersion=version; return true;
    }

    /** 官方固定客户端映射的最小字段面；按实际类名匹配，不用整合包显示名猜版本。 */
    private static final String[] OBFUSCATED = {
        "djz,k,y,aD,aS,u,q,r,s,t,a,b,i",
        "dyr,l,y,aC,bg,u,q,r,s,t,a,b,i",
        "emh,m,z,aM,cc,u,q,r,s,t,a,aq,i,s,b,a",
        "enn,m,z,aM,cd,u,q,r,s,t,a,aq,i,o,b,a",
        "evi,m,y,aM,cd,u,q,r,s,t,a,as,j,o,b,a",
        "fgo,m,y,aM,cg,w,s,t,u,v,a,aw,k,r,b,a",
        "gfj,k,x,aR,dk,w,s,t,u,v,a,aQ,o,d,b,a"
    };

    /** 同一批官方客户端映射的Screen/Widget/Component最小成员面；末两列指定字段实际声明根，避免短名被子类遮蔽。 */
    private static final String[] NAVIGATION_NAMES={
        "e,i,l,m,j,k,a,i,doz,o,p,dot,dlh", "o,g,l,m,j,k,a,i,eec,o,p,edw,eac", "p,k,c,d,s,t,b,a,etj,v,w,etd,enz",
        "k,l,c,d,o,p,b,a,eux,r,s,euq,epf", "k,x,c,d,g,h,b,b,fdi,j,k,fdb,exe", "r,z,c,d,g,h,b,b,frl,j,k,fod,fik", "d,B,a,b,g,h,b,b,gwg,k,l,gsb,gjc"
    };

    // Legacy访问名从对应官方JAR的设置序列化、GUI初始化和Unicode判据逐一核对。
    private static final String[] LEGACY_PROFILES={
        "1.7.10,bao,u,n,aI,b,b", "1.8.9,ave,t,m,aL,d,b",
        "1.9.4,bcd,u,m,aA,e,b", "1.10.2,bcx,u,m,aC,e,b",
        "1.11.2,bes,u,m,aC,e,b", "1.12.2,bib,t,m,aG,e,b"
    };

    /** Native据此过滤已加载类；没有匹配时降级，不主动Class.forName加载另一份游戏单例。 */
    public static String[] candidateNames() {
        String[] names = new String[OBFUSCATED.length + LEGACY_PROFILES.length + 3];
        names[0]="net.minecraft.client.Minecraft";
        names[1]="net.minecraft.client.MinecraftClient";
        names[2]="net.minecraft.class_310";
        for(int i=0;i<LEGACY_PROFILES.length;i++) names[i+3]=LEGACY_PROFILES[i].split(",")[1];
        for(int i=0;i<OBFUSCATED.length;i++) names[i+3+LEGACY_PROFILES.length]=OBFUSCATED[i].split(",")[0];
        return names;
    }

    /** 只缓存成功解析的访问器；游戏尚在构造时返回false，下次低频探测可继续尝试。 */
    public static synchronized boolean bind(Class<?> gameClass) {
        if (adapter != null) return true;
        try {
            Object game=null;
            for (Field field:gameClass.getDeclaredFields()) {
                if (Modifier.isStatic(field.getModifiers()) && field.getType()==gameClass) {
                    field.setAccessible(true);
                    Object value=field.get(null);
                    if (value!=null) { game=value; break; }
                }
            }
            if (game==null) return false;
            Adapter found=Adapter.create(game);
            if (found==null) return false;
            adapter=found;
            System.out.println("[AMCL-GUI] bound class="+gameClass.getName()+" restore="+found.canRestore());
            return true;
        } catch (ReflectiveOperationException | RuntimeException error) {
            return false;
        }
    }

    /** 请求一次游戏线程读，立即返回上次快照。fbW/H只是旧LWJGL2无Window对象时的已确认渲染尺寸。 */
    public static double[] poll(final int fbW, final int fbH) {
        return poll(fbW,fbH,false);
    }

    /** 导航扫描仅随活跃教学请求；普通快捷栏/GUI回读不增加控件遍历或第二条计时器。 */
    public static double[] poll(final int fbW, final int fbH,final boolean guideActive) {
        // 游戏线程卡在加载时不让恢复无限期排队；到期后该Runnable即使迟到也不能写设置。
        if(restorePhase.get()==1 && System.nanoTime()>restoreDeadline && restorePhase.compareAndSet(1,3)) {
            requestResult=3; double[] copy=state.clone(); copy[10]=requestId; copy[11]=3; state=copy;
        }
        final Adapter target=adapter;
        if (target!=null && fbW>0 && fbH>0 && QUEUED.compareAndSet(false,true)) {
            try {
                target.execute(new Runnable() {
                    @Override public void run() {
                        try { publish(target,fbW,fbH,guideActive); }
                        catch (ReflectiveOperationException | RuntimeException error) { invalidate(); }
                        finally { QUEUED.set(false); }
                    }
                });
            } catch (ReflectiveOperationException | RuntimeException error) { QUEUED.set(false); invalidate(); }
        }
        return state.clone();
    }

    /** 恢复请求返回是否入队；最终结果由快照中的requestId/result回执确认，不把入队当成已恢复。 */
    public static synchronized long restore(final int wanted, final long expectedRevision) {
        return restoreInternal(wanted,expectedRevision,0);
    }

    /**
     * Native异步恢复捕获原source/resource票据。返回Java入队ID，仍必须poll读取最终ACK；
     * Native把它映射回自己的精确票据。缺guard、退休或超出无回绕uint32范围立即拒绝。
     */
    public static synchronized long restoreScoped(final int wanted,final long expectedRevision,final long ticket) {
        if(ticket<=0 || ticket>4294967295L || !currentNativeRequest(ticket)) return 0;
        return restoreInternal(wanted,expectedRevision,ticket);
    }

    private static long restoreInternal(final int wanted,final long expectedRevision,final long ticket) {
        final Adapter target=adapter;
        final double[] observed=state;
        if (target==null || wanted<0 || wanted>64 || observed[0]!=2 || observed[7]!=1 ||
            observed[9]!=1 || (long)observed[8]!=expectedRevision) return 0;
        // 公共旧入口保持0拒绝语义；Native scoped端口明确区分同helper的读取Busy，
        // 让worker只在原Native2s队列期限内重试，不能把忙运输错误报告成已恢复。
        if(!QUEUED.compareAndSet(false,true)) return ticket==0 ? 0 : -2;
        final Object expectedScreen=lastScreen;
        final long id=++requestId;
        requestResult=1; restoreDeadline=System.nanoTime()+2000000000L; restorePhase.set(1);
        double[] pending=state.clone(); pending[10]=id; pending[11]=1; state=pending;
        try {
            target.execute(new Runnable() {
                @Override public void run() {
                    int before=-1;
                    try {
                        if(System.nanoTime()>restoreDeadline) restorePhase.compareAndSet(1,3);
                        if(!currentNativeRequest(ticket) || !restorePhase.compareAndSet(1,4)) { requestResult=3; restorePhase.set(3); return; }
                        // 用户可能继续切换GUI档位或离开页面；必须先核实原值与场景，不能覆盖新选择。
                        if (revision!=expectedRevision || target.screen()!=expectedScreen || expectedScreen==null ||
                            target.scale()!= (int)observed[1]) { requestResult=3; restorePhase.set(3); return; }
                        // 排队之后仍再次核Java原事实；窗口/source可在排队期退休，
                        // 原值也可被用户改动。实际setScale前最后回查资源，不能把入队当完成。
                        if(revision!=expectedRevision || target.screen()!=expectedScreen ||
                            target.scale()!=(int)observed[1]) { requestResult=3; restorePhase.set(3); return; }
                        before=target.scale();
                        // OptionInstance.get/反射读取可能阻塞。所有screen/原值读取与before
                        // 捕获必须先完成，最后才取得Native执行资格；否则来源/window在get
                        // 阻塞期退休后，旧任务仍会越过已失效的资格继续setScale。Begin是
                        // 原目标写方法调用的认领点，此后不再做任何可能阻塞的只读get。
                        if(before!=(int)observed[1] || revision!=expectedRevision || target.screen()!=expectedScreen ||
                            !currentNativeRequest(ticket) || !beginNativeRestore(ticket)) {
                            before=-1; requestResult=3; restorePhase.set(3); return;
                        }
                        target.setScale(wanted);
                        target.rebuild(expectedScreen);
                        target.save.invoke(target.options);
                        requestResult=target.scale()==wanted ? 2 : -1; restorePhase.set(requestResult);
                        publish(target,(int)observed[3],(int)observed[4],false);
                    } catch (ReflectiveOperationException | RuntimeException error) {
                        requestResult=-1; restorePhase.set(-1);
                        // 设置失败只尝试回到本次修改前的值；不对新的Screen做任何操作。
                        if (before>=0) try {
                            // 回滚也是实际写。先完成可能阻塞的当前Screen/scale读取，再最后
                            // 核原Native资源，不能在get等待期间退休后继续回写新用户设置。
                            Object rollbackScreen=target.screen();int rollbackScale=target.scale();
                            if (rollbackScreen==expectedScreen && rollbackScale==wanted && currentNativeRequest(ticket)) {
                                target.setScale(before); target.rebuild(expectedScreen); target.save.invoke(target.options);
                            }
                        } catch (ReflectiveOperationException | RuntimeException ignored) { /* 回执保持失败，不伪造恢复。 */ }
                    } finally {
                        QUEUED.set(false);
                        double[] copy=state.clone(); copy[10]=id; copy[11]=requestResult; state=copy;
                    }
                }
            });
        } catch (ReflectiveOperationException | RuntimeException error) { requestResult=-1; restorePhase.set(-1); QUEUED.set(false); return 0; }
        return id;
    }

    /** 读失败时立即撤销可写能力；旧几何不继续作为已确认的游戏状态。 */
    private static void invalidate() {
        double[] copy=state.clone(); copy[0]=0; copy[9]=0; state=copy;
    }

    /** 在游戏线程采集完整几何，只有配置/尺寸/页面身份变了才推进revision。 */
    private static void publish(Adapter target,int fallbackW,int fallbackH,boolean guideActive) throws ReflectiveOperationException {
        Object screen=target.screen();
        int requested=target.scale();
        if (requested<0 || requested>64) throw new IllegalStateException("Invalid GUI option");
        boolean unicode=target.unicode();
        int w=fallbackW,h=fallbackH;
        double effective;
        int guiW,guiH;
        if (target.windowGetter!=null) {
            Object window=target.windowGetter.invoke(target.game);
            w=number(target.fbWidth.get(window)); h=number(target.fbHeight.get(window));
            effective=((Number)target.windowScale.get(window)).doubleValue();
            guiW=number(target.guiWidth.get(window)); guiH=number(target.guiHeight.get(window));
        } else {
            w=number(target.fbWidth.get(target.game)); h=number(target.fbHeight.get(target.game));
            effective=calculateLegacyScale(w,h,requested,unicode);
            if (screen!=null) {
                guiW=number(target.screenWidth.get(screen)); guiH=number(target.screenHeight.get(screen));
                if (guiW>0 && guiH>0) effective=Math.max(1,Math.round((double)w/guiW));
            } else { guiW=(int)Math.ceil(w/effective); guiH=(int)Math.ceil(h/effective); }
        }
        if (w<=0 || h<=0 || guiW<=0 || guiH<=0 || effective<1 || effective>128 || Double.isInfinite(effective) || Double.isNaN(effective))
            throw new IllegalStateException("Invalid GUI geometry");
        double[] navigation=guideActive ? target.navigation(screen) : new double[6];
        double[] next={2,requested,effective,w,h,guiW,guiH,screen==null ? 0 : 1,0,
            target.canRestore() ? 1 : 0,requestId,requestResult,unicode ? 1 : 0,
            navigation[0],navigation[1],navigation[2],navigation[3],navigation[4],navigation[5]};
        boolean changed=screen!=lastScreen;
        for (int i=0;i<8;i++) if(next[i]!=state[i]) changed=true;
        for (int i=13;i<19;i++) if(state.length<=i || next[i]!=state[i]) changed=true;
        if (changed) {
            revision++;
            // 只在GUI状态变化时输出单调回执，不记录路径、帐号或options原文。
            System.out.println("[AMCL-GUI] revision="+revision+" requested="+requested+" effective="+effective+
                " framebuffer="+w+"x"+h+" gui="+guiW+"x"+guiH+" menu="+(screen!=null)+
                " request="+requestId+" result="+requestResult+" navigation="+(int)navigation[0]);
        }
        next[8]=revision; lastScreen=screen; state=next;
    }

    /** 旧版fallback与原版Window/ScaledResolution同构；实际现代窗口数据始终优先。 */
    static int calculateScale(int w,int h,int requested,boolean unicode) {
        int scale=1;
        while (scale!=requested && scale<w && scale<h && w/(scale+1)>=320 && h/(scale+1)>=240) scale++;
        if (unicode && scale%2!=0) scale++;
        return scale;
    }
    /** 1.7.10/1.12.2 ScaledResolution使用向下偶数档，且1档不调整；不能套现代Window的向上规则。 */
    static int calculateLegacyScale(int w,int h,int requested,boolean unicode) {
        int scale=calculateScale(w,h,requested,false);
        if(unicode && scale!=1 && scale%2!=0) scale--;
        return scale;
    }
    private static int number(Object value) { return ((Number)value).intValue(); }

    /** 类型受约束的反射访问器。名字来自官方/MCP/intermediary，缺任一必要字段即拒绝绑定。 */
    private static Field field(Class<?> type,String... names) throws NoSuchFieldException {
        for (Class<?> owner=type;owner!=null;owner=owner.getSuperclass()) for(String name:names) try {
            Field found=owner.getDeclaredField(name); found.setAccessible(true); return found;
        } catch(NoSuchFieldException ignored) { /* 尝试已声明的下一种映射，不猜任意同类型字段。 */ }
        throw new NoSuchFieldException(type.getName());
    }
    private static Method method(Class<?> type,Class<?>[] arguments,String... names) throws NoSuchMethodException {
        for(Class<?> owner=type;owner!=null;owner=owner.getSuperclass()) for(String name:names) try {
            Method found=owner.getDeclaredMethod(name,arguments); found.setAccessible(true); return found;
        } catch(NoSuchMethodException ignored) { /* 同上，仅兼容明确名字。 */ }
        throw new NoSuchMethodException(type.getName());
    }

    /** 缓存对象和成员，不在每次轮询重扫反射表。 */
    private static final class Adapter {
        Object game,options,guiOwner,option;
        Field optionField,screenField,windowScale,fbWidth,fbHeight,guiWidth,guiHeight,screenWidth,screenHeight,unicodeField;
        Method optionGet,optionSet,windowGetter,resize,save,unicodeMethod,schedule,reopen;
        // 官方固定映射的末三列依次为选项列表字段、按选项身份找按钮的方法、循环按钮setValue方法。
        String[] widgetNames;
        String[] navigationNames;
        boolean legacy;

        static Adapter create(Object game) throws ReflectiveOperationException {
            Adapter a=new Adapter(); a.game=game; Class<?> type=game.getClass();
            String[] p=null;
            for(int i=0;i<OBFUSCATED.length;i++) {
                String[] item=OBFUSCATED[i].split(",");
                if(item[0].equals(type.getName())) {
                    // 混淆名字可能在别的补丁版复用；版本不符绝不把另一个整数选项当GUI缩放写入。
                    if(!PROFILE_VERSIONS[i].equals(gameVersion)) return null;
                    p=item;
                    a.navigationNames=NAVIGATION_NAMES[i].split(",");
                }
            }
            String name=type.getName();
            String[] legacyProfile=null;
            for(String row:LEGACY_PROFILES) {
                String[] candidate=row.split(",");
                if(candidate[1].equals(name)) {
                    if(!candidate[0].equals(gameVersion)) return null;
                    legacyProfile=candidate;
                }
            }
            a.options=field(type,p!=null?p[1]:legacyProfile!=null?legacyProfile[2]:"options","gameSettings","field_1690","field_71474_y").get(game);
            if(a.options==null) return null;
            a.optionField=field(a.options.getClass(),p!=null?p[4]:legacyProfile!=null?legacyProfile[4]:"guiScale","field_1868","field_74335_Z");
            if(a.optionField.getType()!=Integer.TYPE) {
                a.option=a.optionField.get(a.options);
                if(a.option==null) return null;
                // OptionInstance/SimpleOption泛型擦除后get()->Object、set(Object)->void唯一；拒绝多义方法。
                for(Method candidate:a.option.getClass().getDeclaredMethods()) {
                    if(Modifier.isStatic(candidate.getModifiers()) || candidate.isSynthetic()) continue;
                    Class<?>[] args=candidate.getParameterTypes();
                    if(args.length==0 && candidate.getReturnType()==Object.class) {
                        if(a.optionGet!=null) return null; a.optionGet=candidate;
                    }
                    if(args.length==1 && args[0]==Object.class && candidate.getReturnType()==Void.TYPE) {
                        if(a.optionSet!=null) return null; a.optionSet=candidate;
                    }
                }
                if(a.optionGet==null || a.optionSet==null) return null;
                a.optionGet.setAccessible(true); a.optionSet.setAccessible(true);
            }
            try { a.windowGetter=method(type,new Class<?>[0],p!=null?p[3]:"getWindow","method_22683"); }
            catch(NoSuchMethodException absent) { a.legacy=true; }
            a.guiOwner=game;
            try { a.screenField=field(type,p!=null?p[2]:legacyProfile!=null?legacyProfile[3]:"screen","currentScreen","field_1755","field_71462_r"); }
            catch(NoSuchFieldException moved) {
                // 26.4把Screen移入Gui；只沿明确gui字段访问，不遍历世界对象图。
                a.guiOwner=field(type,"gui").get(game);
                if(a.guiOwner==null) return null;
                a.screenField=field(a.guiOwner.getClass(),"screen");
            }
            if(a.windowGetter!=null) {
                // 绑定阶段只看声明类型，窗口对象和数值在游戏线程读，避免UI线程调用游戏getter。
                Class<?> wt=a.windowGetter.getReturnType();
                a.windowScale=field(wt,p!=null?p[5]:"guiScale","scaleFactor","field_5179");
                a.fbWidth=field(wt,p!=null?p[6]:"framebufferWidth","field_5181");
                a.fbHeight=field(wt,p!=null?p[7]:"framebufferHeight","field_5196");
                a.guiWidth=field(wt,p!=null?p[8]:"guiScaledWidth","scaledWidth","field_5180");
                a.guiHeight=field(wt,p!=null?p[9]:"guiScaledHeight","scaledHeight","field_5194");
            } else {
                Class<?> screenType=a.screenField.getType();
                a.fbWidth=field(type,legacyProfile!=null?"d":"displayWidth","field_71443_c");
                a.fbHeight=field(type,legacyProfile!=null?"e":"displayHeight","field_71440_d");
                a.screenWidth=field(screenType,legacyProfile!=null?"l":"width","field_146294_l");
                a.screenHeight=field(screenType,legacyProfile!=null?"m":"height","field_146295_m");
                a.reopen=method(type,new Class<?>[]{screenType},legacyProfile!=null?"a":"displayGuiScreen","func_147108_a");
            }
            try { a.unicodeMethod=method(type,new Class<?>[0],p!=null?p[12]:legacyProfile!=null?legacyProfile[5]:"isEnforceUnicode","forcesUnicodeFont","method_1573","isUnicode","func_152349_b"); }
            catch(NoSuchMethodException absent) {
                try { a.unicodeField=field(a.options.getClass(),"forceUnicodeFont","field_151455_aw"); }
                catch(NoSuchFieldException ignored) { /* 现代Window提供实际scale，Unicode标记只影响legacy fallback。 */ }
            }
            try { a.save=method(a.options.getClass(),new Class<?>[0],p!=null?p[11]:legacyProfile!=null?legacyProfile[6]:"save","write","method_1640","saveOptions","func_74303_b"); }
            catch(NoSuchMethodException ignored) { /* 没有保存入口只读，不对GUI作半份修改。 */ }
            if(!a.legacy) try { a.resize=method(type,new Class<?>[0],p!=null?p[10]:"resizeGui","resizeDisplay","onResolutionChanged","method_15993"); }
            catch(NoSuchMethodException ignored) { /* 同上。 */ }
            if(p!=null && p.length>15) a.widgetNames=new String[]{p[13],p[14],p[15]};
            if(!(game instanceof Executor)) {
                for(Method candidate:type.getMethods()) if(candidate.getParameterTypes().length==1 &&
                    candidate.getParameterTypes()[0]==Runnable.class && Future.class.isAssignableFrom(candidate.getReturnType())) {
                    if(a.schedule!=null) return null; a.schedule=candidate;
                }
                if(a.schedule==null) return null;
            }
            return a;
        }
        void execute(Runnable task) throws ReflectiveOperationException {
            if(game instanceof Executor) ((Executor)game).execute(task); else schedule.invoke(game,task);
        }
        Object screen() throws IllegalAccessException { return screenField.get(guiOwner); }
        int scale() throws ReflectiveOperationException {
            Object value=optionGet==null?optionField.get(options):optionGet.invoke(option);
            if(!(value instanceof Integer)) throw new IllegalStateException("GUI option is not an integer");
            return ((Integer)value).intValue();
        }
        void setScale(int value) throws ReflectiveOperationException {
            if(optionSet==null) optionField.setInt(options,value); else optionSet.invoke(option,Integer.valueOf(value));
        }
        boolean unicode() throws ReflectiveOperationException {
            if(unicodeMethod!=null) return Boolean.TRUE.equals(unicodeMethod.invoke(game));
            return unicodeField!=null && Boolean.TRUE.equals(unicodeField.get(options));
        }
        boolean canRestore() { return save!=null && (resize!=null || reopen!=null); }
        void rebuild(Object screen) throws ReflectiveOperationException {
            if(resize!=null) {
                resize.invoke(game);
                if(screen()==screen) syncScaleWidget(screen);
            } else reopen.invoke(game,screen);
        }
        /**
         * 只同步GUI选项对应的原循环按钮。新版resize保留按钮缓存，而整页init又会向保留的布局重复添加控件。
         * 使用游戏原有findOption按OptionInstance身份定位，不按按钮文字/坐标或任意整数字段猜测；不触发用户点击。
         * 没有选项列表的普通菜单无需处理；发现目标按钮后的调用失败交给restore回滚，不伪造成功。
         */
        void syncScaleWidget(Object screen) throws ReflectiveOperationException {
            if(option==null) return;
            final Object list;
            final Method find;
            try {
                list=field(screen.getClass(),widgetNames!=null?widgetNames[0]:"list","body","field_51824").get(screen);
                if(list==null) return;
                find=method(list.getClass(),new Class<?>[]{option.getClass()},
                    widgetNames!=null?widgetNames[1]:"findOption","getWidgetFor","method_31046");
            } catch(NoSuchFieldException | NoSuchMethodException absent) {
                // 普通容器、旧版或未适配的自定义页面不存在标准选项列表；只保留已有尺寸恢复合同。
                return;
            }
            Object widget=find.invoke(list,option);
            if(widget==null) return;
            Method set=method(widget.getClass(),new Class<?>[]{Object.class},
                widgetNames!=null?widgetNames[2]:"setValue","method_32605");
            set.invoke(widget,Integer.valueOf(scale()));
        }

        /**
         * 只观察当前Screen的真实导航按钮：翻译键决定语义，控件几何决定位置，不匹配本地化文字或猜坐标。
         * 每次最多检查96个已存在子控件；不保留Screen/按钮引用、不加载游戏类、不增加线程。
         * 旧版或模组成员缺失时只撤销导航尾表，尺寸/恢复能力继续工作；未知页面不得显示虚构指针。
         */
        double[] navigation(Object screen) {
            double[] result=new double[6];
            if(screen==null || legacy) return result;
            String[] n=navigationNames;
            try {
                String name=screen.getClass().getName();
                if(name.equals("net.minecraft.client.gui.screens.options.VideoSettingsScreen") ||
                    name.equals("net.minecraft.client.gui.screens.VideoSettingsScreen") ||
                    name.equals("net.minecraft.client.gui.screen.option.VideoOptionsScreen") ||
                    name.equals("net.minecraft.class_446") || (n!=null && name.equals(n[8]))) {
                    result[0]=3; result[5]=-1;
                    try {
                        Object list=field(screen.getClass(),widgetNames!=null?widgetNames[0]:"list","body","field_51824").get(screen);
                        if(list!=null) {
                            Method max=method(list.getClass(),new Class<?>[0],"getMaxScrollAmount","getMaxScroll","method_25331");
                            result[5]=((Number)max.invoke(list)).doubleValue()>0 ? 1 : 0;
                        }
                    } catch(ReflectiveOperationException | RuntimeException absent) { /* 不具备滚动证据的已知视频页不假装是长列表。 */ }
                    return result;
                }
                // 混淆短名在子类中会重复：1.21.11 PauseScreen.d是静态BUTTON_PADDING，Screen.d才是children。
                // 只在已验证的实际声明根读成员，不能把第一个同名字段当作语义匹配，也不加载另一份游戏类。
                Class<?> screenType=n!=null ? navigationOwner(screen.getClass(),n[11]) : screen.getClass();
                Object raw=field(screenType,n!=null?n[0]:"children","buttons","field_22786").get(screen);
                if(!(raw instanceof List<?>)) return result;
                List<?> children=(List<?>)raw;
                for(int i=0;i<children.size() && i<96;i++) {
                    Object child=children.get(i);
                    if(child==null) continue;
                    try {
                        Class<?> widgetType=n!=null ? navigationOwner(child.getClass(),n[12]) : child.getClass();
                        Object message=method(widgetType,new Class<?>[0],n!=null?n[1]:"getMessage","method_25369").invoke(child);
                        String key=translationKey(message,n);
                        int kind="menu.options".equals(key) ? 1 : "options.video".equals(key) ? 2 : 0;
                        if(kind==0) continue;
                        if(!Boolean.TRUE.equals(field(widgetType,n!=null?n[9]:"active","field_22763").get(child)) ||
                            !Boolean.TRUE.equals(field(widgetType,n!=null?n[10]:"visible","field_22764").get(child))) continue;
                        result[0]=kind;
                        result[1]=number(field(widgetType,n!=null?n[2]:"x","field_22760").get(child));
                        result[2]=number(field(widgetType,n!=null?n[3]:"y","field_22761").get(child));
                        result[3]=number(field(widgetType,n!=null?n[4]:"width","field_22758").get(child));
                        result[4]=number(field(widgetType,n!=null?n[5]:"height","field_22759").get(child));
                        return result;
                    } catch(ReflectiveOperationException | RuntimeException absent) { /* 非标准子控件不影响下一项，也不缓存旧目标。 */ }
                }
            } catch(ReflectiveOperationException | RuntimeException absent) { /* 能力缺失只返回空导航，不能否定合法GUI尺寸。 */ }
            return new double[6];
        }

        /** 从当前对象的真实继承链找官方已核验的声明类；未知模组层级失败关闭导航，不扫描任意同类型字段。 */
        Class<?> navigationOwner(Class<?> type,String name) throws NoSuchFieldException {
            for(Class<?> owner=type;owner!=null;owner=owner.getSuperclass()) if(owner.getName().equals(name)) return owner;
            throw new NoSuchFieldException("navigation owner unavailable");
        }

        /** 兼容旧TranslatableComponent及新ComponentContents；只返回翻译键，不把用户文字带出游戏。 */
        String translationKey(Object message,String[] names) throws ReflectiveOperationException {
            if(message==null) return "";
            try {
                Method direct=method(message.getClass(),new Class<?>[0],names!=null?names[7]:"getKey","method_11022");
                // 新版Component.getContents与TranslatableContents.getKey可能都混淆成b()；先验证返回类型再调用。
                // 旧TranslatableComponent直接返回String；ComponentContents返回值不是缺能力，应走下面的内容入口。
                if(direct.getReturnType()==String.class && !Modifier.isStatic(direct.getModifiers())) return (String)direct.invoke(message);
            } catch(NoSuchMethodException absent) { /* 现代Component没有直接getKey，继续查真实内容对象。 */ }
            Object contents=method(message.getClass(),new Class<?>[0],names!=null?names[6]:"getContents","getContent","method_10851").invoke(message);
            if(contents==null) return "";
            Method key=method(contents.getClass(),new Class<?>[0],names!=null?names[7]:"getKey","method_11022");
            return key.getReturnType()==String.class && !Modifier.isStatic(key.getModifiers()) ? (String)key.invoke(contents) : "";
        }
    }
}
