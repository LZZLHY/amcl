import org.lwjgl.Version;
import org.lwjgl.opengl.GL;
import org.lwjgl.opengl.GLCapabilities;
import org.lwjgl.opengl.GL11C;
import org.lwjgl.opengl.GL30C;
import org.lwjgl.opengl.GL15C;
import org.lwjgl.opengl.GL20C;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.JNI;
import java.nio.IntBuffer;
import java.nio.ByteBuffer;

/** B8 宿主消费者实验：调用现役 JAR 中的真实 GL.createCapabilities，不复制版本算法。
 * context 由 JNI 的同线程 production owner 建立和退休；官方 FunctionProvider 只把
 * 已冻结 MG 映像中的地址交给 LWJGL。Linux native 模块只负责实际 JNI 调用，不另找 GL。
 */
public final class FrontendLwjglConsumer {
    private static native String createOwner(int major, int minor);
    private static native long resolve(long nameAddress);
    private static native String inspectOwner();
    private static native String extensionEvidence();
    private static native String retireOwner();

    /** 已知core语义反例与cap flags分别记录。这里的失败不会伪称消费者未执行，
     * 也不会因OpenGL40=true就当FP64/线框合规；shader来自固定动态uint输入。 */
    private static void knownCoreSemantics() {
        final String fp64 = "#version 400 core\nuniform uint lhs;uniform uint rhs;out vec4 color;" +
            "void main(){double delta=double(lhs)-double(rhs);color=delta==double(1)?vec4(0,1,0,1):vec4(1,0,0,1);}";
        int fragment = GL20C.glCreateShader(GL20C.GL_FRAGMENT_SHADER);
        GL20C.glShaderSource(fragment, fp64); GL20C.glCompileShader(fragment);
        int status = GL20C.glGetShaderi(fragment, GL20C.GL_COMPILE_STATUS);
        System.out.println("FP64_SOURCE " + fp64.replace('\n', ' '));
        System.out.println("CORE_FP64 qualification=" + (status == 0 ? "FAIL" : "COMPILE_ONLY") +
            " compileStatus=" + status + " log=" + GL20C.glGetShaderInfoLog(fragment).replace('\n', '|'));
        GL20C.glDeleteShader(fragment);
        // LINE的内点应保留清屏黑色；独立FBO且先以FILL红色校准同一合法shader/draw路径。
        String vertexSource="#version 330 core\nin vec2 pos;void main(){gl_Position=vec4(pos,0,1);}";
        String fragmentSource="#version 330 core\nout vec4 color;void main(){color=vec4(1,0,0,1);}";
        int vertex=GL20C.glCreateShader(GL20C.GL_VERTEX_SHADER), pixel=GL20C.glCreateShader(GL20C.GL_FRAGMENT_SHADER);
        GL20C.glShaderSource(vertex,vertexSource);GL20C.glCompileShader(vertex);
        GL20C.glShaderSource(pixel,fragmentSource);GL20C.glCompileShader(pixel);
        if(GL20C.glGetShaderi(vertex,GL20C.GL_COMPILE_STATUS)==0||GL20C.glGetShaderi(pixel,GL20C.GL_COMPILE_STATUS)==0)
            throw new IllegalStateException("polygon calibration shader failed");
        int program=GL20C.glCreateProgram();GL20C.glAttachShader(program,vertex);GL20C.glAttachShader(program,pixel);
        GL20C.glBindAttribLocation(program,0,"pos");GL20C.glLinkProgram(program);
        if(GL20C.glGetProgrami(program,GL20C.GL_LINK_STATUS)==0)throw new IllegalStateException("polygon calibration link failed");
        int fbo=GL30C.glGenFramebuffers(),rb=GL30C.glGenRenderbuffers(),vao=GL30C.glGenVertexArrays(),vbo=GL15C.glGenBuffers();
        GL30C.glBindFramebuffer(GL30C.GL_FRAMEBUFFER,fbo);GL30C.glBindRenderbuffer(GL30C.GL_RENDERBUFFER,rb);
        GL30C.glRenderbufferStorage(GL30C.GL_RENDERBUFFER,GL30C.GL_RGBA8,64,64);
        GL30C.glFramebufferRenderbuffer(GL30C.GL_FRAMEBUFFER,GL30C.GL_COLOR_ATTACHMENT0,GL30C.GL_RENDERBUFFER,rb);
        if(GL30C.glCheckFramebufferStatus(GL30C.GL_FRAMEBUFFER)!=GL30C.GL_FRAMEBUFFER_COMPLETE)
            throw new IllegalStateException("polygon calibration FBO incomplete");
        GL30C.glBindVertexArray(vao);GL15C.glBindBuffer(GL15C.GL_ARRAY_BUFFER,vbo);
        try(MemoryStack stack=MemoryStack.stackPush()){
            GL15C.glBufferData(GL15C.GL_ARRAY_BUFFER,stack.floats(-.7f,-.7f,.7f,-.7f,0,.7f),GL15C.GL_STATIC_DRAW);
            GL20C.glVertexAttribPointer(0,2,GL11C.GL_FLOAT,false,0,0L);GL20C.glEnableVertexAttribArray(0);GL20C.glUseProgram(program);
            GL11C.glViewport(0,0,64,64);GL11C.glDisable(GL11C.GL_DEPTH_TEST);GL11C.glDisable(GL11C.GL_BLEND);
            GL11C.glDisable(GL11C.GL_CULL_FACE);GL11C.glDisable(GL11C.GL_SCISSOR_TEST);GL11C.glClearColor(0,0,0,1);
            ByteBuffer rgba=stack.malloc(4);
            GL11C.glPolygonMode(GL11C.GL_FRONT_AND_BACK,GL11C.GL_FILL);GL11C.glClear(GL11C.GL_COLOR_BUFFER_BIT);
            GL11C.glDrawArrays(GL11C.GL_TRIANGLES,0,3);GL11C.glFinish();GL11C.glReadPixels(32,32,1,1,GL11C.GL_RGBA,GL11C.GL_UNSIGNED_BYTE,rgba);
            if((rgba.get(0)&255)<252||(rgba.get(1)&255)>3||(rgba.get(2)&255)>3)throw new IllegalStateException("FILL pixel oracle failed");
            GL11C.glPolygonMode(GL11C.GL_FRONT_AND_BACK,GL11C.GL_LINE);GL11C.glClear(GL11C.GL_COLOR_BUFFER_BIT);
            GL11C.glDrawArrays(GL11C.GL_TRIANGLES,0,3);GL11C.glFinish();GL11C.glReadPixels(32,32,1,1,GL11C.GL_RGBA,GL11C.GL_UNSIGNED_BYTE,rgba);
            boolean black=(rgba.get(0)&255)<=3&&(rgba.get(1)&255)<=3&&(rgba.get(2)&255)<=3;
            System.out.println("CORE_POLYGON qualification="+(black?"PASS_THIS_INNER_PIXEL":"FAIL")+" fillCalibrated=1 lineRGBA="+
                (rgba.get(0)&255)+","+(rgba.get(1)&255)+","+(rgba.get(2)&255)+","+(rgba.get(3)&255)+" expectedRGB=0,0,0");
        }
        GL11C.glPolygonMode(GL11C.GL_FRONT_AND_BACK,GL11C.GL_FILL);GL20C.glUseProgram(0);
        GL30C.glBindFramebuffer(GL30C.GL_FRAMEBUFFER,0);GL30C.glDeleteFramebuffers(fbo);GL30C.glDeleteRenderbuffers(rb);
        GL30C.glDeleteVertexArrays(vao);GL15C.glDeleteBuffers(vbo);GL20C.glDeleteProgram(program);
        GL20C.glDeleteShader(vertex);GL20C.glDeleteShader(pixel);
        int error=GL11C.glGetError();if(error!=0)throw new IllegalStateException("known semantic calibration left GL error "+error);
    }

    public static void main(String[] args) {
        if (args.length != 3) throw new IllegalArgumentException("usage JNI-library major minor");
        System.load(args[0]);
        final int major = Integer.parseInt(args[1]);
        final int minor = Integer.parseInt(args[2]);
        boolean created = false;
        boolean initialized = false;
        try {
            System.out.println("JVM java=" + System.getProperty("java.runtime.version") + " vm=" + System.getProperty("java.vm.name") +
                " arch=" + System.getProperty("os.arch") + " thread=" + Thread.currentThread().getName());
            System.out.println("LWJGL version=" + Version.getVersion() + " GLClass=" + GL.class.getProtectionDomain().getCodeSource().getLocation());
            System.out.println(createOwner(major, minor));
            created = true;
            System.out.println(extensionEvidence());
            // OPENGL_EXPLICIT_INIT 在 JVM 命令行设置，类初始化不会先装系统 libGL。
            // FunctionProvider 的 ByteBuffer 正是 LWJGL 编码的真实NUL终止函数名称。
            GL.create(name -> resolve(MemoryUtil.memAddress(name)));
            initialized = true;
            // 这是与GL.java实际相同的标准原始查询，用于记录JNI入口输入；不构造
            // supportedExtensions或capabilities字段，也不改driver函数/Java算法。
            try (MemoryStack stack = MemoryStack.stackPush()) {
                IntBuffer versionQuery = stack.ints(-17);
                long getter = GL.getFunctionProvider().getFunctionAddress("glGetIntegerv");
                long errorGetter = GL.getFunctionProvider().getFunctionAddress("glGetError");
                JNI.callPV(GL30C.GL_MAJOR_VERSION, MemoryUtil.memAddress(versionQuery), getter);
                System.out.println("ACTUAL_JNI_QUERY major=" + versionQuery.get(0) + " error=" + JNI.callI(errorGetter));
                JNI.callPV(GL30C.GL_MINOR_VERSION, MemoryUtil.memAddress(versionQuery), getter);
                System.out.println("ACTUAL_JNI_QUERY minor=" + versionQuery.get(0) + " error=" + JNI.callI(errorGetter));
            }
            GLCapabilities caps = GL.createCapabilities();
            int actualMajor = GL11C.glGetInteger(GL30C.GL_MAJOR_VERSION);
            int actualMinor = GL11C.glGetInteger(GL30C.GL_MINOR_VERSION);
            String version = GL11C.glGetString(GL11C.GL_VERSION);
            System.out.println("CAPABILITIES requested=" + major + "." + minor + " actualInteger=" + actualMajor + "." + actualMinor +
                " string=" + version + " OpenGL30=" + caps.OpenGL30 + " OpenGL32=" + caps.OpenGL32 +
                " OpenGL33=" + caps.OpenGL33 + " OpenGL40=" + caps.OpenGL40);
            System.out.println("REQUIRED_POINTERS glGetError=" + caps.glGetError + " glGetString=" + caps.glGetString +
                " glGetIntegerv=" + caps.glGetIntegerv + " glGetStringi=" + caps.glGetStringi +
                " glCreateShader=" + caps.glCreateShader + " glLinkProgram=" + caps.glLinkProgram +
                " glDrawArrays=" + caps.glDrawArrays + " glDepthRange=" + caps.glDepthRange);
            int count = GL11C.glGetInteger(GL30C.GL_NUM_EXTENSIONS);
            for (int index = 0; index < count; ++index) {
                String extension = GL30C.glGetStringi(GL11C.GL_EXTENSIONS, index);
                if (extension != null && extension.startsWith("OpenGL"))
                    System.out.println("ACTUAL_CORE_TOKEN index=" + index + " token=" + extension);
            }
            if (caps.glGetError == 0 || caps.glGetString == 0 || caps.glGetIntegerv == 0 || caps.glGetStringi == 0 ||
                caps.glCreateShader == 0 || caps.glLinkProgram == 0 || caps.glDrawArrays == 0 || caps.glDepthRange == 0)
                throw new IllegalStateException("required actual provider pointer missing");
            int error = GL11C.glGetError();
            if (error != GL11C.GL_NO_ERROR) throw new IllegalStateException("capability queries left GL error " + error);
            if (major>=4)knownCoreSemantics();
            System.out.println(inspectOwner());
            System.out.println("CONSUMER_RESULT actual GL.createCapabilities completed; core semantics NOT qualified");
        } finally {
            // LWJGL要求销毁或迁移context时清其线程本地capabilities。这里先清Java表，再
            // 沿原owner退休真实EGL句柄；不将Java对象释放等同于native资源退休。
            if (initialized) { GL.setCapabilities(null); GL.destroy(); }
            if (created) System.out.println(retireOwner());
        }
    }
}
