import com.badlogic.gdx.jnigen.NativeCodeGenerator;

/** 使用上游 jnigen 与真实发布包的 Java 签名生成 JNI，C++ 实现取自锁定上游源码。 */
public final class GenerateBindings {
    public static void main(String[] args) throws Exception {
        new NativeCodeGenerator().generate(args[0], args[1], args[2]);
    }
}
