package com.amcl.qa;
import java.io.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import org.lwjgl.BufferUtils;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.GL;
import static org.lwjgl.opengl.GL43C.*;

/** 原DH生产fog/copy/far-fade语义诊断，覆盖实际GL43顶点绑定与采样depth仍附着DRAW FBO的情况。 */
public final class DistantCompositeProbe {
    private static int checks,failures,outputFbo,depthFbo,colorTarget,depth,green,red,transparent,vbo,legacy,separate;
    private DistantCompositeProbe() { }
    static String source(String name)throws Exception{
        InputStream in=DistantCompositeProbe.class.getResourceAsStream("/assets/distanthorizons/shaders/"+name);if(in==null)throw new IOException(name);ByteArrayOutputStream out=new ByteArrayOutputStream();try{byte[] b=new byte[4096];int n;while((n=in.read(b))>=0){if(out.size()+n>65536)throw new IOException("shader budget");out.write(b,0,n);}}finally{in.close();}
        StringBuilder hash=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(out.toByteArray()))hash.append(String.format(Locale.ROOT,"%02x",b&255));System.out.println("AMCL_DH_SOURCE path="+name+" sha256="+hash);return new String(out.toByteArray(),StandardCharsets.UTF_8);
    }
    private static int shader(int type,String text){int s=glCreateShader(type);glShaderSource(s,text);glCompileShader(s);if(glGetShaderi(s,GL_COMPILE_STATUS)==0)throw new AssertionError(glGetShaderInfoLog(s));return s;}
    static int program(String vertex,String fragment){int p=glCreateProgram(),v=shader(GL_VERTEX_SHADER,vertex),f=shader(GL_FRAGMENT_SHADER,fragment);glAttachShader(p,v);glAttachShader(p,f);glBindAttribLocation(p,0,"vPosition");glLinkProgram(p);if(glGetProgrami(p,GL_LINK_STATUS)==0)throw new AssertionError(glGetProgramInfoLog(p));glDeleteShader(v);glDeleteShader(f);if(glGetAttribLocation(p,"vPosition")!=0)throw new AssertionError("quad binding");return p;}
    private static void one(int p,String name,int v){int at=glGetUniformLocation(p,name);if(at<0)throw new AssertionError("missing uniform "+name);glUniform1i(at,v);}
    static void bind(int unit,int texture){glActiveTexture(GL_TEXTURE0+unit);glBindTexture(GL_TEXTURE_2D,texture);glBindSampler(unit,0);}
    static int color(int r,int g,int b,int a){int t=glGenTextures();glBindTexture(GL_TEXTURE_2D,t);ByteBuffer data=BufferUtils.createByteBuffer(16*16*4);for(int i=0;i<256;i++)data.put((byte)r).put((byte)g).put((byte)b).put((byte)a);data.flip();glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,16,16,0,GL_RGBA,GL_UNSIGNED_BYTE,data);parameters();return t;}
    private static void parameters(){glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,0);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_COMPARE_MODE,GL_NONE);}
    /** 同一GPU图像分别由CPU上传、GPU全清+带scissor局部清产生；采样前不插入读回。 */
    private static void pattern(boolean gpu,float clear,float written){
        glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,depth);
        if(!gpu){FloatBuffer data=BufferUtils.createFloatBuffer(256);for(int y=0;y<16;y++)for(int x=0;x<16;x++)data.put(x<8?clear:written);data.flip();glTexImage2D(GL_TEXTURE_2D,0,GL_DEPTH_COMPONENT32F,16,16,0,GL_DEPTH_COMPONENT,GL_FLOAT,data);}
        else{glBindFramebuffer(GL_FRAMEBUFFER,depthFbo);glDepthMask(true);glDisable(GL_SCISSOR_TEST);glClearDepth(clear);glClear(GL_DEPTH_BUFFER_BIT);glEnable(GL_SCISSOR_TEST);glScissor(8,0,8,16);glClearDepth(written);glClear(GL_DEPTH_BUFFER_BIT);glDisable(GL_SCISSOR_TEST);}
    }
    private static void target(boolean attach){
        glBindFramebuffer(GL_FRAMEBUFFER,outputFbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_TEXTURE_2D,attach?depth:0,0);glDrawBuffer(GL_COLOR_ATTACHMENT0);glReadBuffer(GL_COLOR_ATTACHMENT0);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw new AssertionError("output FBO");glViewport(0,0,16,16);glDisable(GL_SCISSOR_TEST);glDisable(GL_DEPTH_TEST);glDisable(GL_STENCIL_TEST);glDisable(GL_BLEND);glColorMask(true,true,true,true);glClearColor(0,0,1,1);glClear(GL_COLOR_BUFFER_BIT);
    }
    private static void draw(int vao){glBindVertexArray(vao);if(vao==separate)glBindVertexBuffer(0,vbo,0L,8);glDrawArrays(GL_TRIANGLES,0,6);}
    /** undefined的原reverse smoothstep只观察；有序参考与合法fog/copy按明确像素断言。 */
    private static int[] pixel(String label,int x,int[] expected,boolean asserted){ByteBuffer b=BufferUtils.createByteBuffer(4);glReadPixels(x,8,1,1,GL_RGBA,GL_UNSIGNED_BYTE,b);int error=glGetError();int[] actual=new int[4];boolean same=error==0;for(int i=0;i<4;i++){actual[i]=b.get(i)&255;same&=Math.abs(actual[i]-expected[i])<=1;}if(asserted){checks++;if(!same)failures++;}else if(error!=0){checks++;failures++;}System.out.println("AMCL_DH_PIXEL label="+label+" asserted="+asserted+" matchesReference="+same+" error="+error+" reference="+Arrays.toString(expected)+" actual="+Arrays.toString(actual));return actual;}
    public static void main(String[] args){long window=0;try{
        if(!GLFW.glfwInit())throw new AssertionError("GLFW init");GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MAJOR,3);GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR,3);GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_PROFILE,GLFW.GLFW_OPENGL_CORE_PROFILE);window=GLFW.glfwCreateWindow(64,64,"DH composite QA",0,0);if(window==0)throw new AssertionError("GLFW window");GLFW.glfwMakeContextCurrent(window);GL.createCapabilities();System.out.println("AMCL_DH_IDENTITY "+glGetString(GL_VERSION));if(!GL.getCapabilities().OpenGL43)throw new AssertionError("actual DH GL43 path unavailable");
        String vertex=source("shared/gl/quad_apply.vert"),fogSource=source("fog/gl/apply.frag"),fadeSource=source("fade/gl/dh_fade.frag"),needle="smoothstep(startFade, endFade, dhFragmentDistance)";if(fadeSource.indexOf(needle)!=fadeSource.lastIndexOf(needle)||!fadeSource.contains(needle))throw new AssertionError("fade source identity");
        int fog=program(vertex,fogSource),copy=program(vertex,source("copy/gl/apply.frag")),original=program(vertex,fadeSource),ordered=program(vertex,fadeSource.replace(needle,"(1.0 - smoothstep(endFade, startFade, dhFragmentDistance))"));
        vbo=glGenBuffers();glBindBuffer(GL_ARRAY_BUFFER,vbo);glBufferData(GL_ARRAY_BUFFER,new float[]{-1,-1,1,-1,1,1,-1,-1,1,1,-1,1},GL_STATIC_DRAW);
        legacy=glGenVertexArrays();glBindVertexArray(legacy);glVertexAttribPointer(0,2,GL_FLOAT,false,8,0L);glEnableVertexAttribArray(0);separate=glGenVertexArrays();glBindVertexArray(separate);glVertexAttribFormat(0,2,GL_FLOAT,false,0);glVertexAttribBinding(0,0);glEnableVertexAttribArray(0);glBindVertexBuffer(0,vbo,0L,8);
        colorTarget=color(0,0,1,255);green=color(0,255,0,255);red=color(255,0,0,255);transparent=color(0,255,0,0);depth=glGenTextures();glBindTexture(GL_TEXTURE_2D,depth);glTexImage2D(GL_TEXTURE_2D,0,GL_DEPTH_COMPONENT32F,16,16,0,GL_DEPTH_COMPONENT,GL_FLOAT,(ByteBuffer)null);parameters();
        outputFbo=glGenFramebuffers();glBindFramebuffer(GL_FRAMEBUFFER,outputFbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,colorTarget,0);depthFbo=glGenFramebuffers();glBindFramebuffer(GL_FRAMEBUFFER,depthFbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_TEXTURE_2D,depth,0);glDrawBuffer(GL_NONE);glReadBuffer(GL_NONE);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw new AssertionError("depth FBO");glDisable(GL_CULL_FACE);
        // 查询能力只记录，不把未实现查询当成可用，也不让它的错误污染后面的像素断言。
        int setupError=glGetError();if(setupError!=0)throw new AssertionError("setup GL error "+setupError);
        IntBuffer formatSupport=BufferUtils.createIntBuffer(1);glGetInternalformativ(GL_TEXTURE_2D,GL_DEPTH_COMPONENT32F,GL_SIMULTANEOUS_TEXTURE_AND_DEPTH_TEST,formatSupport);System.out.println("AMCL_DH_DEPTH_CAP value="+formatSupport.get(0)+" error="+glGetError());
        for(int vao:new int[]{legacy,separate}){
            target(false);bind(0,green);glUseProgram(copy);one(copy,"uCopyTexture",0);draw(vao);pixel("copy-binding-"+(vao==separate),8,new int[]{0,255,0,255},true);
            for(boolean gpu:new boolean[]{false,true})for(boolean reverse:new boolean[]{false,true})for(boolean attached:new boolean[]{false,true})for(boolean blend:new boolean[]{false,true}){
                pattern(gpu,reverse?0:1,.75f);target(attached);if(blend){glEnable(GL_BLEND);glBlendEquation(GL_FUNC_ADD);glBlendFuncSeparate(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA,GL_ONE,GL_ONE_MINUS_SRC_ALPHA);}bind(0,green);bind(1,depth);glUseProgram(fog);one(fog,"uColorTexture",0);one(fog,"uDepthTexture",1);one(fog,"uIsReverseZDepth",reverse?1:0);draw(vao);
                String label="fog-binding="+(vao==separate)+"-gpu="+gpu+"-reverse="+reverse+"-attached="+attached+"-blend="+blend;
                pixel(label+"-clear",4,blend?new int[]{0,0,255,255}:new int[]{0,0,0,0},true);pixel(label+"-written",12,new int[]{0,255,0,255},true);
            }
            for(float distance:new float[]{.25f,.7f,.95f})for(boolean empty:new boolean[]{false,true})for(int p:new int[]{original,ordered}){
                // 实际uDepthIsZeroToPositiveOne=false。受控逆矩阵消去XY，仅留下可计算的正Z距离。
                float encoded=(distance+1)/2;pattern(false,encoded,encoded);target(false);bind(0,depth);bind(1,red);bind(2,empty?transparent:green);glUseProgram(p);one(p,"uDhDepthTexture",0);one(p,"uMcColorTexture",1);one(p,"uDhColorTexture",2);one(p,"uDepthIsZeroToPositiveOne",0);glUniform1f(glGetUniformLocation(p,"uStartFadeBlockDistance"),.5f);glUniform1f(glGetUniformLocation(p,"uEndFadeBlockDistance"),.9f);glUniformMatrix4fv(glGetUniformLocation(p,"uDhInvMvmProj"),false,new float[]{0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,1});draw(vao);
                int[] expected=empty?new int[]{255,0,0,255}:distance<.5f?new int[]{0,255,0,255}:distance>.9f?new int[]{255,0,0,255}:new int[]{128,128,0,255};pixel("fade-binding="+(vao==separate)+"-distance="+distance+"-empty="+empty+"-ordered="+(p==ordered),8,expected,p==ordered);
            }
        }
        for(int p:new int[]{fog,copy,original,ordered})glDeleteProgram(p);for(int t:new int[]{colorTarget,green,red,transparent,depth})glDeleteTextures(t);glDeleteFramebuffers(outputFbo);glDeleteFramebuffers(depthFbo);glDeleteBuffers(vbo);glDeleteVertexArrays(legacy);glDeleteVertexArrays(separate);
    }catch(Throwable error){failures++;error.printStackTrace();}finally{if(window!=0)GLFW.glfwDestroyWindow(window);GLFW.glfwTerminate();}System.out.println("AMCL_DH_RESULT checks="+checks+" failures="+failures+" passed="+(failures==0));System.exit(failures==0?0:1);}
}
