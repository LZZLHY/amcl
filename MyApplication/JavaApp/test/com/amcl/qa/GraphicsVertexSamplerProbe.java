package com.amcl.qa;
import java.nio.*;
import java.util.Arrays;
import org.lwjgl.BufferUtils;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.GL;
import static org.lwjgl.opengl.GL33C.*;

/**
 * 原Aged的地形/手部均在顶点阶段采光照或覆盖纹理，而HUD主要在片元阶段采样。
 * 本独立探针对照同程序中两个阶段的真实纹理绑定；不替换或修改原模组，不推定完整shader合格。
 */
public final class GraphicsVertexSamplerProbe {
    private static int count, failed;
    private static final int[][] COLORS={{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,255,255}};
    private static int compile(int kind,String source){int s=glCreateShader(kind);glShaderSource(s,source);glCompileShader(s);if(glGetShaderi(s,GL_COMPILE_STATUS)==0)throw new AssertionError(glGetShaderInfoLog(s));return s;}
    /** 四个变体仅改变顶点纹理消费：不采样、texture、texelFetch，以及两者共用。 */
    private static int program(int mode){
        String sample=mode==0?"vec4(1)":mode==1?"texture(LightTex,vec2(.5))":mode==2?"texelFetch(LightTex,ivec2(1),0)":"texture(LightTex,vec2(.5))*texelFetch(OverlayTex,ivec2(1),0)";
        String vertex="#version 330 core\nlayout(location=0) in vec2 Position;layout(location=1) in vec2 UV;uniform sampler2D LightTex;uniform sampler2D OverlayTex;out vec2 uv;out vec4 lighting;void main(){gl_Position=vec4(Position,0,1);uv=UV;lighting="+sample+";}";
        String fragment="#version 330 core\nin vec2 uv;in vec4 lighting;uniform sampler2D Atlas;out vec4 outputColor;void main(){outputColor=texture(Atlas,uv)*lighting;}";
        int vs=compile(GL_VERTEX_SHADER,vertex),fs=compile(GL_FRAGMENT_SHADER,fragment),p=glCreateProgram();glAttachShader(p,vs);glAttachShader(p,fs);glLinkProgram(p);if(glGetProgrami(p,GL_LINK_STATUS)==0)throw new AssertionError(glGetProgramInfoLog(p));glDeleteShader(vs);glDeleteShader(fs);return p;
    }
    private static int texture(int[] solid){
        ByteBuffer bytes=BufferUtils.createByteBuffer(8*8*4);
        for(int y=0;y<8;y++)for(int x=0;x<8;x++)for(int c:(solid==null?COLORS[(y>=4?2:0)+(x>=4?1:0)]:solid))bytes.put((byte)c);
        bytes.flip();int t=glGenTextures();glBindTexture(GL_TEXTURE_2D,t);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,8,8,0,GL_RGBA,GL_UNSIGNED_BYTE,bytes);
        // 原单级纹理会触发MobileGL的ExplicitLod0Sampling等价变体。atlas必须有完整多级，
        // 才能测到真正隐式LOD路径；当前8像素atlas在64像素FBO放大，正确结果仍应采mip0。
        if(solid==null)for(int level=1;level<=3;level++){
            int size=8>>level;ByteBuffer mip=BufferUtils.createByteBuffer(size*size*4);
            for(int i=0;i<size*size;i++)for(int c:COLORS[level])mip.put((byte)c);mip.flip();
            glTexImage2D(GL_TEXTURE_2D,level,GL_RGBA8,size,size,0,GL_RGBA,GL_UNSIGNED_BYTE,mip);
        }
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,solid==null?GL_NEAREST_MIPMAP_NEAREST:GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,solid==null?3:0);return t;
    }
    /** 同时读回uniform的unit和最终像素；getter正确但像素错误仍判失败。 */
    private static void sampler(int p,String name,int unit,int texture){
        glActiveTexture(GL_TEXTURE0+unit);glBindTexture(GL_TEXTURE_2D,texture);int at=glGetUniformLocation(p,name);glUniform1i(at,unit);
        if(at>=0&&glGetUniformi(p,at)!=unit)throw new AssertionError("sampler unit readback "+name);
        System.out.println("AMCL_GL_STAGE_BIND program="+p+" name="+name+" location="+at+" unit="+unit+" texture="+texture);
    }
    private static void pixels(String label,int mode,boolean colored){
        for(int y:new int[]{16,48})for(int x:new int[]{16,48}){
            ByteBuffer bytes=BufferUtils.createByteBuffer(4);glReadPixels(x,y,1,1,GL_RGBA,GL_UNSIGNED_BYTE,bytes);int error=glGetError();boolean ok=error==0;
            int[] original=COLORS[(y>=32?2:0)+(x>=32?1:0)],actual=new int[4],expected=original.clone();
            int[] light={128,255,64,255},overlay={255,128,255,255};
            for(int c=0;c<4;c++){
                if(colored&&mode>0)expected[c]=Math.round(expected[c]*light[c]/255f);
                if(colored&&mode==3)expected[c]=Math.round(expected[c]*overlay[c]/255f);
                actual[c]=bytes.get(c)&255;ok&=Math.abs(actual[c]-expected[c])<=1;
            }
            count++;if(!ok)failed++;
            System.out.println("AMCL_GL_STAGE_PIXEL label="+label+" x="+x+" y="+y+" passed="+ok+" error="+error+" expected="+Arrays.toString(expected)+" actual="+Arrays.toString(actual));
        }
    }
    public static void main(String[] args){
        long window=0;
        try{
            if(!GLFW.glfwInit())throw new AssertionError("glfwInit");GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MAJOR,3);GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR,3);GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_PROFILE,GLFW.GLFW_OPENGL_CORE_PROFILE);
            window=GLFW.glfwCreateWindow(64,64,"AMCL vertex samplers",0,0);if(window==0)throw new AssertionError("context");GLFW.glfwMakeContextCurrent(window);GL.createCapabilities();System.out.println("AMCL_GL_STAGE_IDENTITY "+glGetString(GL_VERSION)+" "+glGetString(GL_RENDERER));
            int vao=glGenVertexArrays(),vbo=glGenBuffers();glBindVertexArray(vao);glBindBuffer(GL_ARRAY_BUFFER,vbo);FloatBuffer v=BufferUtils.createFloatBuffer(24);v.put(new float[]{-1,-1,0,0,1,-1,1,0,1,1,1,1,-1,-1,0,0,1,1,1,1,-1,1,0,1}).flip();glBufferData(GL_ARRAY_BUFFER,v,GL_STATIC_DRAW);glVertexAttribPointer(0,2,GL_FLOAT,false,16,0L);glEnableVertexAttribArray(0);glVertexAttribPointer(1,2,GL_FLOAT,false,16,8L);glEnableVertexAttribArray(1);
            int fbo=glGenFramebuffers(),attachment=glGenTextures();glBindTexture(GL_TEXTURE_2D,attachment);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,64,64,0,GL_RGBA,GL_UNSIGNED_BYTE,(ByteBuffer)null);glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,attachment,0);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw new AssertionError("FBO");
            glViewport(0,0,64,64);glDisable(GL_DEPTH_TEST);glDisable(GL_BLEND);glDisable(GL_CULL_FACE);glDisable(GL_SCISSOR_TEST);
            int atlas=texture(null),white=texture(new int[]{255,255,255,255}),light=texture(new int[]{128,255,64,255}),overlay=texture(new int[]{255,128,255,255});
            int[] programs={program(0),program(1),program(2),program(3)};int[][] units={{0,1,3},{3,0,1},{1,3,0}};
            for(boolean colored:new boolean[]{false,true})for(int permutation=0;permutation<units.length;permutation++)for(int mode=0;mode<4;mode++){
                int p=programs[mode];glUseProgram(p);sampler(p,"Atlas",units[permutation][0],atlas);sampler(p,"LightTex",units[permutation][1],colored?light:white);sampler(p,"OverlayTex",units[permutation][2],colored?overlay:white);
                glDrawArrays(GL_TRIANGLES,0,6);pixels("stage-"+mode+"-"+permutation+"-"+colored,mode,colored);
            }
            glFinish();for(int p:programs)glDeleteProgram(p);for(int t:new int[]{atlas,white,light,overlay,attachment})glDeleteTextures(t);glDeleteFramebuffers(fbo);glDeleteBuffers(vbo);glDeleteVertexArrays(vao);
            System.out.println("AMCL_GL_STAGE_RESULT checks="+count+" failures="+failed+" passed="+(failed==0));
        }catch(Throwable error){failed++;error.printStackTrace();}
        finally{if(window!=0)GLFW.glfwDestroyWindow(window);GLFW.glfwTerminate();}
        System.exit(failed==0?0:1);
    }
}
