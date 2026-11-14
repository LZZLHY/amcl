package com.sun.media.sound;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import javax.sound.sampled.BooleanControl;
import javax.sound.sampled.FloatControl;
import javax.sound.sampled.Line;
import javax.sound.sampled.LineUnavailableException;
import javax.sound.sampled.Mixer;
import javax.sound.sampled.Port;

/** 真正补后PortMixer类+生产JNI的宿主回归；系统设备供应者为固定控制输入，不授予真机资格。 */
public final class PortsJavaTest {
    private static native void setScenario(int value);
    private static native int activeHandles();
    private static native int activeArrays();
    private static native long handleSequence();
    private static native void clearCache();
    private static void require(boolean value,String message){if(!value)throw new AssertionError(message);}
    private static Port port(Mixer mixer,boolean input) throws Exception {
        Line.Info[] infos=input?mixer.getSourceLineInfo():mixer.getTargetLineInfo();
        require(infos.length==1,"one concrete device must expose one correct role");
        require(infos[0] instanceof Port.Info,"expected real Port.Info");return (Port)mixer.getLine(infos[0]);
    }
    /** 原API没有公开系统setter，不能公布可写外观或以空成功吞掉内部native误调用。 */
    private static void controls(Port line) throws Exception {
        line.open();require(line.isOpen(),"line did not open");require(line.getControls().length==0,"fake writable controls");
        require(!line.isControlSupported(BooleanControl.Type.MUTE)&&!line.isControlSupported(FloatControl.Type.VOLUME),"fake system controls supported");
        try{line.getControl(FloatControl.Type.VOLUME);throw new AssertionError("fake volume get accepted");}catch(IllegalArgumentException expected){}
        line.close();line.close();require(!line.isOpen(),"close failed");
    }
    public static void main(String[] args) throws Exception {
        System.err.println("PORTS_PHASE_MAIN_ENTER");
        System.load(args[0]);
        System.err.println("PORTS_PHASE_NATIVE_LOADED");
        setScenario(0);PortMixerProvider provider=new PortMixerProvider();
        System.err.println("PORTS_PHASE_PROVIDER_CONSTRUCTED");
        Mixer.Info[] first=provider.getMixerInfo();
        require(first.length==4,"real SDK descriptors were suppressed or virtual ones invented");
        require(first[0].getName().equals("Port 扬声器🙂"),"UTF-8 non-BMP name lost");
        require(first[1].getName().equals("Port 麦克风🎤"),"microphone name lost");
        require(first[3].getName().length()>800&&first[3].getName().endsWith("设备🙂"),"name truncated or modified UTF-8 used");
        Mixer speaker=provider.getMixer(first[0]);Port speakerPort=port(speaker,false);
        require(speakerPort.getLineInfo().equals(Port.Info.SPEAKER),"speaker type not mapped");controls(speakerPort);
        Mixer microphone=provider.getMixer(first[1]);Port mic=port(microphone,true);
        require(mic.getLineInfo().equals(Port.Info.MICROPHONE),"microphone type not mapped");controls(mic);
        Port headphones=port(provider.getMixer(first[2]),false);require(headphones.getLineInfo().equals(Port.Info.HEADPHONE),"headphone type not mapped");controls(headphones);
        Port unknown=port(provider.getMixer(first[3]),false);require(((Port.Info)unknown.getLineInfo()).getName().endsWith("设备🙂"),"unknown type name lost");controls(unknown);
        require(activeHandles()==0&&activeArrays()==0,"normal open/close leaked");
        setScenario(1);Mixer.Info[] reordered=provider.getMixerInfo();
        for(int i=0;i<4;i++)require(first[i]==reordered[i],"same device reorder changed identity");
        require(provider.getMixer(first[0])==speaker,"cached mixer identity changed");
        setScenario(2);Mixer.Info[] changed=provider.getMixerInfo();
        require(changed[0]!=first[0]&&changed[1]==first[1],"same-size replacement did not invalidate precise device");
        try{provider.getMixer(first[0]);throw new AssertionError("removed Info still routes to new device");}catch(IllegalArgumentException expected){}
        try{speakerPort.open();throw new AssertionError("old Port silently opened replacement");}catch(LineUnavailableException expected){}
        require(!speakerPort.isOpen()&&activeHandles()==0,"failed old Port retained resources");
        controls(port(provider.getMixer(changed[0]),false));
        setScenario(4);
        try{mic.open();throw new AssertionError("SDK error pretended successful Port");}catch(LineUnavailableException expected){}
        require(!mic.isOpen()&&activeHandles()==0&&activeArrays()==0,"failed open leaked");
        try{provider.getMixerInfo();throw new AssertionError("SDK failure pretended empty success");}catch(IllegalStateException expected){}
        setScenario(0);require(provider.getMixerInfo().length==4,"provider did not recover");
        long sequence=handleSequence();setScenario(12);
        try{mic.open();throw new AssertionError("second SDK query failure not propagated");}catch(LineUnavailableException expected){}
        require(handleSequence()==sequence+1&&activeHandles()==0&&!mic.isOpen(),"partially reserved mixer did not roll back");
        setScenario(13);
        try{provider.getMixerInfo();throw new AssertionError("invalid system UTF-8 accepted");}catch(IllegalStateException expected){}
        require(activeHandles()==0&&activeArrays()==0,"bad name path leaked");
        setScenario(0);require(provider.getMixerInfo().length==4,"Unicode-error recovery failed");
        Method set=PortMixer.class.getDeclaredMethod("nControlSetFloatValue",long.class,float.class);set.setAccessible(true);
        try{set.invoke(null,1L,0.5f);throw new AssertionError("private setter falsely succeeded");}
        catch(InvocationTargetException expected){require(expected.getCause() instanceof UnsupportedOperationException,"wrong unsupported error");}
        setScenario(3);require(provider.getMixerInfo().length==0,"real empty device list produced fake device");
        clearCache();require(activeHandles()==0&&activeArrays()==0,"final resources not released");
        System.out.println("PASS real PortMixer Java/JNI: descriptors, typed roles, full UTF-16, stable identity/replacement, unsupported controls, failure cleanup and empty physical list; host binding injection only");
    }
}
