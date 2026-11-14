package com.amcl.qa;

import java.nio.*;
import org.lwjgl.BufferUtils;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.GL;
import static org.lwjgl.opengl.GL33C.*;

/**
 * 在实际游戏GLFW/provider上下文内绘制已知像素，区分UV输入、纹理/mip/绑定和逐draw uniform上传。
 * 本类只供独立QA实例，不进入启动JAR、不修改任何模组。失败逐项记录，最终非零退出；
 * 宿主能够编译不代表设备像素通过，也不据单个场景授予全部OpenGL资格。
 */
public final class GraphicsTextureProbe {
    private static int checks, failures, vao, vbo, fbo, color;
    private static final int SIZE = 64;
    private static final int[] RED={255,0,0,255}, GREEN={0,255,0,255}, BLUE={0,0,255,255}, WHITE={255,255,255,255}, CYAN={0,255,255,255};
    private static final String VERTEX = "#version 330 core\nlayout(location=0) in vec2 Position;\nUV_DECL\nlayout(location=2) in vec4 Color;\nuniform mat4 ModelViewMat;uniform mat4 ProjMat;out vec2 uv;out vec4 color;out float distanceValue;\nvoid main(){vec4 p=ModelViewMat*vec4(Position,0,1);gl_Position=ProjMat*p;uv=UV_EXPR;color=Color;distanceValue=abs(p.z);}";
    private static final String FRAGMENT = "#version 330 core\nin vec2 uv;in vec4 color;in float distanceValue;uniform sampler2D Sampler0;uniform float Lod;uniform int Mode;uniform vec4 ColorModulator;uniform float FogStart;uniform float FogEnd;uniform vec4 FogColor;out vec4 outputColor;\nvoid main(){if(Mode==0){outputColor=vec4(uv,0,1)*color;}else{vec4 c=textureLod(Sampler0,uv,Lod)*ColorModulator*color;float f=clamp((distanceValue-FogStart)/(FogEnd-FogStart),0,1);outputColor=Mode==2?mix(c,FogColor,f):c;}}";

    /** 编译真实桌面GLSL；失败打印真实驱动日志后中止，不替换成始终成功的shader。 */
    private static int shader(int kind, String source) {
        int shader=glCreateShader(kind);glShaderSource(shader,source);glCompileShader(shader);
        if(glGetShaderi(shader,GL_COMPILE_STATUS)==0)throw new AssertionError(glGetShaderInfoLog(shader));return shader;
    }
    private static int program(boolean integer) {
        String vertex=VERTEX.replace("UV_DECL",integer?"layout(location=1) in uvec2 UV;":"layout(location=1) in vec2 UV;").replace("UV_EXPR",integer?"vec2(UV)/65535.0":"UV");
        int vs=shader(GL_VERTEX_SHADER,vertex),fs=shader(GL_FRAGMENT_SHADER,FRAGMENT),p=glCreateProgram();glAttachShader(p,vs);glAttachShader(p,fs);glLinkProgram(p);
        if(glGetProgrami(p,GL_LINK_STATUS)==0)throw new AssertionError(glGetProgramInfoLog(p));glDeleteShader(vs);glDeleteShader(fs);return p;
    }

    /** 相同20字节交错布局分别交付float、normalized ushort和integer ushort UV，颜色为真正byte属性。 */
    private static void geometry(int variant) {
        float[][] vertices={{-1,-1,0,0},{1,-1,1,0},{1,1,1,1},{-1,-1,0,0},{1,1,1,1},{-1,1,0,1}};
        ByteBuffer data=BufferUtils.createByteBuffer(120).order(ByteOrder.nativeOrder());
        for(float[] v:vertices){data.putFloat(v[0]).putFloat(v[1]).putInt(-1);if(variant==0)data.putFloat(v[2]).putFloat(v[3]);else data.putShort((short)(v[2]*65535)).putShort((short)(v[3]*65535)).putInt(0);}
        data.flip();glBindVertexArray(vao);glBindBuffer(GL_ARRAY_BUFFER,vbo);glBufferData(GL_ARRAY_BUFFER,data,GL_STATIC_DRAW);
        glVertexAttribPointer(0,2,GL_FLOAT,false,20,0L);glEnableVertexAttribArray(0);
        if(variant==2)glVertexAttribIPointer(1,2,GL_UNSIGNED_SHORT,20,12L);else glVertexAttribPointer(1,2,variant==0?GL_FLOAT:GL_UNSIGNED_SHORT,variant!=0,20,12L);
        glEnableVertexAttribArray(1);glVertexAttribPointer(2,4,GL_UNSIGNED_BYTE,true,20,8L);glEnableVertexAttribArray(2);
    }
    private static void one(int p,String name,int value){glUniform1i(glGetUniformLocation(p,name),value);}
    private static void scalar(int p,String name,float value){glUniform1f(glGetUniformLocation(p,name),value);}
    private static void vector(int p,String name,float r,float g,float b,float a){glUniform4f(glGetUniformLocation(p,name),r,g,b,a);}
    /** 显式设置每个应用可见uniform；使用真实透视除法，并按平面距离同步缩放XY，使测试仍覆盖整个FBO。 */
    private static void uniforms(int p,int mode,int unit,float lod,float distance,float r,float g,float b) {
        glUseProgram(p);one(p,"Mode",mode);one(p,"Sampler0",unit);scalar(p,"Lod",lod);
        vector(p,"ColorModulator",r,g,b,1);scalar(p,"FogStart",10);scalar(p,"FogEnd",30);vector(p,"FogColor",.2f,.4f,.6f,1);
        float plane=distance==0?2:distance;
        float[] model={plane,0,0,0,0,plane,0,0,0,0,1,0,0,0,-plane,1};
        float[] projection={1,0,0,0,0,1,0,0,0,0,-100.1f/99.9f,-1,0,0,-20f/99.9f,0};
        glUniformMatrix4fv(glGetUniformLocation(p,"ModelViewMat"),false,model);glUniformMatrix4fv(glGetUniformLocation(p,"ProjMat"),false,projection);
    }
    private static void upload(int level,int size,int[] rgba,boolean quadrants) {
        ByteBuffer pixels=BufferUtils.createByteBuffer(size*size*4);
        for(int y=0;y<size;y++)for(int x=0;x<size;x++){
            int[] value=quadrants?(y<size/2?(x<size/2?RED:GREEN):(x<size/2?BLUE:WHITE)):rgba;
            for(int v:value)pixels.put((byte)v);
        }
        pixels.flip();glTexImage2D(GL_TEXTURE_2D,level,GL_RGBA8,size,size,0,GL_RGBA,GL_UNSIGNED_BYTE,pixels);
    }
    private static int texture(boolean quadrants,int[] rgba) {
        int t=glGenTextures();glBindTexture(GL_TEXTURE_2D,t);upload(0,8,rgba,quadrants);upload(1,4,GREEN,false);upload(2,2,BLUE,false);upload(3,1,WHITE,false);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST_MIPMAP_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,3);return t;
    }
    /** 每项读取真实FBO；允许UNORM转换的一字节舍入，不能把getter一致当成像素正确。 */
    private static void pixel(String label,int x,int y,int[] expected,int tolerance) {
        ByteBuffer data=BufferUtils.createByteBuffer(4);glReadPixels(x,y,1,1,GL_RGBA,GL_UNSIGNED_BYTE,data);int error=glGetError();int[] actual=new int[4];boolean ok=error==GL_NO_ERROR;
        for(int i=0;i<4;i++){actual[i]=data.get(i)&255;ok&=Math.abs(actual[i]-expected[i])<=tolerance;}
        checks++;if(!ok)failures++;
        System.out.println("AMCL_GL_PIXEL label="+label+" passed="+ok+" error="+error+" expected="+java.util.Arrays.toString(expected)+" actual="+java.util.Arrays.toString(actual));
    }
    private static void draw(){glDrawArrays(GL_TRIANGLES,0,6);}

    public static void main(String[] args) {
        long window=0;
        try {
            if(!GLFW.glfwInit())throw new AssertionError("glfwInit failed");
            GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MAJOR,3);GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR,3);GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_PROFILE,GLFW.GLFW_OPENGL_CORE_PROFILE);
            window=GLFW.glfwCreateWindow(SIZE,SIZE,"AMCL texture diagnostics",0,0);if(window==0)throw new AssertionError("no GLFW context");
            GLFW.glfwMakeContextCurrent(window);GL.createCapabilities();
            System.out.println("AMCL_GL_IDENTITY version="+glGetString(GL_VERSION)+" renderer="+glGetString(GL_RENDERER));
            vao=glGenVertexArrays();vbo=glGenBuffers();fbo=glGenFramebuffers();color=glGenTextures();glBindTexture(GL_TEXTURE_2D,color);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,SIZE,SIZE,0,GL_RGBA,GL_UNSIGNED_BYTE,(ByteBuffer)null);
            glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,color,0);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw new AssertionError("FBO incomplete");
            glDisable(GL_DEPTH_TEST);glDisable(GL_BLEND);glDisable(GL_CULL_FACE);glDisable(GL_SCISSOR_TEST);glViewport(0,0,SIZE,SIZE);
            int[] programs={program(false),program(false),program(true)};int a=texture(true,WHITE),b=texture(false,CYAN),white=texture(false,WHITE);
            // 先验证UV本身；四个采样点避开三角接缝与边缘。
            for(int variant=0;variant<3;variant++){
                geometry(variant);uniforms(programs[variant==2?2:0],0,0,0,0,1,1,1);draw();
                for(int y:new int[]{16,48})for(int x:new int[]{16,48})pixel("uv-"+variant+"-"+x+"-"+y,x,y,new int[]{Math.round((x+.5f)/SIZE*255),Math.round((y+.5f)/SIZE*255),0,255},1);
            }
            geometry(0);int sampler=glGenSamplers();glSamplerParameteri(sampler,GL_TEXTURE_MIN_FILTER,GL_NEAREST_MIPMAP_NEAREST);glSamplerParameteri(sampler,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
            for(int frame=0;frame<2;frame++)for(int unit:new int[]{0,1,3})for(int index=0;index<2;index++){
                glActiveTexture(GL_TEXTURE0+unit);glBindTexture(GL_TEXTURE_2D,index==0?a:b);glBindSampler(unit,frame==0?sampler:0);
                for(int lod=0;lod<3;lod++){
                    uniforms(programs[index],1,unit,lod,0,1,1,1);draw();
                    for(int y:new int[]{16,48})for(int x:new int[]{16,48}){
                        int[] expected=lod==1?GREEN:lod==2?BLUE:index==1?CYAN:y<32?(x<32?RED:GREEN):(x<32?BLUE:WHITE);
                        pixel("texture-"+frame+"-"+unit+"-"+index+"-"+lod+"-"+x+"-"+y,x,y,expected,0);
                    }
                }
            }
            // 32次draw先全部提交，再统一读回；逐draw的buffer/descriptor快照不得借用最后一组uniform。
            glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,white);glBindSampler(0,0);
            for(int frame=0;frame<2;frame++){
                for(int tile=0;tile<32;tile++){
                    int index=(tile+frame)%2;float distance=(tile%3)*20;float r=index==0?1:.1f,g=index==0?.1f:1,bv=.2f;
                    glViewport((tile%8)*8,(tile/8)*8,8,8);uniforms(programs[index],2,0,0,distance,r,g,bv);draw();
                }
                for(int tile=0;tile<32;tile++){
                    int index=(tile+frame)%2;float factor=tile%3==0?0:tile%3==1?.5f:1;float r=index==0?1:.1f,g=index==0?.1f:1;
                    pixel("uniform-batch-"+frame+"-"+tile,(tile%8)*8+4,(tile/8)*8+4,new int[]{Math.round((r*(1-factor)+.2f*factor)*255),Math.round((g*(1-factor)+.4f*factor)*255),Math.round((.2f*(1-factor)+.6f*factor)*255),255},1);
                }
            }
            glFinish();for(int p:programs)glDeleteProgram(p);glDeleteSamplers(sampler);glDeleteTextures(a);glDeleteTextures(b);glDeleteTextures(white);glDeleteTextures(color);glDeleteFramebuffers(fbo);glDeleteBuffers(vbo);glDeleteVertexArrays(vao);
            System.out.println("AMCL_GL_TEXTURE_RESULT checks="+checks+" failures="+failures+" passed="+(failures==0));
        } catch(Throwable failure){failures++;failure.printStackTrace();}
        finally{if(window!=0)GLFW.glfwDestroyWindow(window);GLFW.glfwTerminate();}
        System.exit(failures==0?0:1);
    }
}
