package com.amcl.qa;
import java.nio.*;
import org.lwjgl.BufferUtils;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.GL;
import static org.lwjgl.opengl.GL33C.*;

/** 定性VS-only/rasterizer-discard的警告：实际TF数据与前后控制像素分别验，不把有警告等同失败。 */
public final class TransformFeedbackProbe {
    private static int checks,failures;
    private TransformFeedbackProbe() { }
    private static int shader(int type,String text){int s=glCreateShader(type);glShaderSource(s,text);glCompileShader(s);if(glGetShaderi(s,GL_COMPILE_STATUS)==0)throw new AssertionError(glGetShaderInfoLog(s));return s;}
    private static int program(boolean feedback){
        String vertex=feedback?"#version 330 core\nout vec3 captured;void main(){float i=float(gl_VertexID);captured=vec3(i+1.0,i+2.0,i+3.0);gl_Position=vec4(i*.5-.5,0,0,1);}":"#version 330 core\nvoid main(){vec2 p=gl_VertexID==0?vec2(-1,-1):gl_VertexID==1?vec2(3,-1):vec2(-1,3);gl_Position=vec4(p,0,1);}";
        int p=glCreateProgram(),vs=shader(GL_VERTEX_SHADER,vertex),fs=0;glAttachShader(p,vs);
        if(feedback)glTransformFeedbackVaryings(p,new CharSequence[]{"captured"},GL_INTERLEAVED_ATTRIBS);
        else{fs=shader(GL_FRAGMENT_SHADER,"#version 330 core\nout vec4 color;void main(){color=vec4(1,0,0,1);}");glAttachShader(p,fs);}
        glLinkProgram(p);if(glGetProgrami(p,GL_LINK_STATUS)==0)throw new AssertionError(glGetProgramInfoLog(p));glDeleteShader(vs);if(fs!=0)glDeleteShader(fs);return p;
    }
    /** 标记与hilog实取时钟对照；不凭日志出现顺序猜具体VkPipeline身份。 */
    private static void phase(String name){System.out.println("AMCL_TF_PHASE name="+name+" epochMs="+System.currentTimeMillis());}
    private static void pixel(String label,int x,int y){ByteBuffer b=BufferUtils.createByteBuffer(4);glReadPixels(x,y,1,1,GL_RGBA,GL_UNSIGNED_BYTE,b);int error=glGetError();boolean ok=error==0&&(b.get(0)&255)==255&&(b.get(1)&255)==0&&(b.get(2)&255)==0&&(b.get(3)&255)==255;checks++;if(!ok)failures++;System.out.println("AMCL_TF_PIXEL label="+label+" passed="+ok+" error="+error+" rgba="+(b.get(0)&255)+","+(b.get(1)&255)+","+(b.get(2)&255)+","+(b.get(3)&255));}
    public static void main(String[] args){long window=0;try{
        if(!GLFW.glfwInit())throw new AssertionError("GLFW init");GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MAJOR,3);GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR,3);GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_PROFILE,GLFW.GLFW_OPENGL_CORE_PROFILE);window=GLFW.glfwCreateWindow(64,64,"TF control QA",0,0);if(window==0)throw new AssertionError("GLFW window");GLFW.glfwMakeContextCurrent(window);GL.createCapabilities();System.out.println("AMCL_TF_IDENTITY "+glGetString(GL_VERSION));
        int vao=glGenVertexArrays();glBindVertexArray(vao);int fbo=glGenFramebuffers(),color=glGenTextures();glBindTexture(GL_TEXTURE_2D,color);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,64,64,0,GL_RGBA,GL_UNSIGNED_BYTE,(ByteBuffer)null);glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,color,0);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw new AssertionError("FBO");glDisable(GL_DEPTH_TEST);glDisable(GL_BLEND);glDisable(GL_CULL_FACE);glDisable(GL_SCISSOR_TEST);
        int normal=program(false),tf=program(true),buffer=glGenBuffers();glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER,buffer);glBufferData(GL_TRANSFORM_FEEDBACK_BUFFER,36L,GL_DYNAMIC_READ);glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER,0,buffer);
        phase("before-control");glUseProgram(normal);glViewport(0,0,32,64);glDrawArrays(GL_TRIANGLES,0,3);
        phase("tf-begin");glUseProgram(tf);glEnable(GL_RASTERIZER_DISCARD);glBeginTransformFeedback(GL_POINTS);glDrawArrays(GL_POINTS,0,3);glEndTransformFeedback();glDisable(GL_RASTERIZER_DISCARD);phase("tf-end");
        // 不读回/不换context/不插finish，直接复用同一FBO和VAO绘制第二半控制图。
        glUseProgram(normal);glViewport(32,0,32,64);glDrawArrays(GL_TRIANGLES,0,3);phase("after-control");
        pixel("before",16,32);pixel("after",48,32);
        FloatBuffer values=BufferUtils.createFloatBuffer(9);glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER,buffer);glGetBufferSubData(GL_TRANSFORM_FEEDBACK_BUFFER,0L,values);
        for(int i=0;i<9;i++){float expected=i/3+i%3+1;boolean ok=Math.abs(values.get(i)-expected)<.0001f;checks++;if(!ok)failures++;System.out.println("AMCL_TF_VALUE index="+i+" expected="+expected+" actual="+values.get(i)+" passed="+ok);}
        int error=glGetError();checks++;if(error!=0)failures++;System.out.println("AMCL_TF_ERROR "+error);
        glDeleteBuffers(buffer);glDeleteProgram(normal);glDeleteProgram(tf);glDeleteFramebuffers(fbo);glDeleteTextures(color);glDeleteVertexArrays(vao);
    }catch(Throwable error){failures++;error.printStackTrace();}finally{if(window!=0)GLFW.glfwDestroyWindow(window);GLFW.glfwTerminate();}System.out.println("AMCL_TF_RESULT checks="+checks+" failures="+failures+" passed="+(failures==0));System.exit(failures==0?0:1);}
}
