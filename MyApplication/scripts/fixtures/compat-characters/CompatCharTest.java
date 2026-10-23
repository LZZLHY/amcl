/** 真实生产Java/JNI与三个消费接口的兼容字符轨迹；只组织断言，不复制输入归约。 */

package org.lwjgl.glfw;
import java.lang.reflect.Method;import java.util.Arrays;import org.lwjgl.opengl.CompatL2CharConsumer;
public final class CompatCharTest {
 // publish通过真实owner表发布，mode只指定identity反控；callbacks选择实际GLFW两个出口。
 // glfw执行原桥接pump返回收到的[char,mods]对；sdl执行正式dispatch与SDK poll返回文本。
 private static native void publish(int mode,String foreign);private static native void callbacks(int plain,int mods);private static native int[] glfw();private static native String sdl();
 /** 保留独立COMPAT_CHAR标记，外层只有成功编译后的字符行为断言才接受为有效负控。 */
 static void check(boolean v,String s){if(!v)throw new AssertionError("COMPAT_CHAR "+s);}
 /**
  * 输入为primary DLL、foreign DLL、identity模式及可选反控出口。每次新JVM执行完整
  * 原Java初始化和三端消费，验证BMP单位、回调fallback、旧JNI符号以及keyup不生字符。
  * identity模式期望真实类初始化被拒绝；正常模式任何绑定/字符计数错误直接失败。
  */
 public static void main(String[] a)throws Exception{
  // 每个JNI负控使用新JVM；旧类初始化失败不能通过同进程重试被掩盖。
  System.load(a[0]);publish(Integer.parseInt(a[2]),a[1]);
  if(!a[2].equals("0")){try{Class.forName("org.lwjgl.glfw.CallbackBridge");throw new AssertionError("bad descriptor/module accepted");}catch(UnsatisfiedLinkError expected){System.out.println("PASS real JNI bad descriptor/PID/module rejected "+a[2]);return;}}
  CompatL2CharConsumer.start();String focus=a.length>3?a[3]:"all";
  for(int config=0;config<4;config++){
   callbacks(config&1,(config>>1)&1);CallbackBridge.sendChar('a',3);CallbackBridge.sendKeycode(0,'é',0,2,true);CallbackBridge.sendChar('中',0);CallbackBridge.sendChar('€',1);CallbackBridge.sendKeycode(0,'X',0,0,false);
   int[] got=glfw();String expected="aé中€";
   // 正例核全部出口；撤回组分别聚焦每种实际ABI断言，避免首个失败遮住其它消费层。
   if(focus.equals("all")||focus.equals("glfw")){
    check(got.length==(config==0?0:8),"GLFW callback count "+config+" "+Arrays.toString(got));
    if(config!=0)for(int i=0;i<4;i++){check(got[2*i]==expected.charAt(i),"GLFW BMP unit "+config);check(got[2*i+1]==((config&2)!=0?new int[]{3,2,0,1}[i]:-1),"GLFW mods fallback "+config);}
   }
   String l2=CompatL2CharConsumer.read(),sdlText=sdl();
   if(focus.equals("all")||focus.equals("l2"))check(l2.equals(expected),"real L2 Keyboard.next charset "+config);
   if(focus.equals("all")||focus.equals("sdl"))check(sdlText.equals(expected),"actual SDL text queue/PollEvent charset "+config);
  }
  for(String method:new String[]{"nativeSendChar","nativeSendCharMods"}){
   callbacks(1,1);Method nativeMethod=CallbackBridge.class.getDeclaredMethod(method,method.endsWith("Mods")?new Class<?>[]{char.class,int.class}:new Class<?>[]{char.class});nativeMethod.setAccessible(true);
   if(method.endsWith("Mods"))nativeMethod.invoke(null,'中',7);else nativeMethod.invoke(null,'中');int[] got=glfw();check(got.length==2&&got[0]=='中',"old native public symbol single record "+method);check(CompatL2CharConsumer.read().equals("中"),"old L2 native symbol "+method);check(sdl().equals("中"),"old SDL native symbol "+method);
  }
  System.out.println("PASS actual CallbackBridge Java/JNI owner binding; one BMP char; GLFW onlyPlain/onlyMods/both/none; actual L2 Keyboard.next and SDL PollEvent");
 }
}
