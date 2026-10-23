/** 真实生产Java/JNI与三个消费接口的兼容字符轨迹；只组织断言，不复制输入归约。 */

package org.lwjgl.opengl;
import java.lang.reflect.Method;import org.lwjgl.input.Keyboard;
public final class CompatL2CharConsumer {
 private static AMCLDisplay display;
 /**
  * 为新JVM创建维护AMCLDisplay，再调用原Keyboard的私有创建边缘。这只省略图形窗口
  * 创建，InputImplementation和随后poll/next仍是JAR中的真实类；反射/加载失败直接抛出。
  */
 public static void start()throws Exception{display=new AMCLDisplay();Method create=Keyboard.class.getDeclaredMethod("create",InputImplementation.class);create.setAccessible(true);create.invoke(null,display);}
 /** 实际poll并逐条next，只合并key==0的原字符事件；返回空串即当前没有可消费文本。 */
 public static String read(){Keyboard.poll();StringBuilder text=new StringBuilder();while(Keyboard.next())if(Keyboard.getEventKey()==0)text.append(Keyboard.getEventCharacter());return text.toString();}
}
