package com.amcl.qa;
import java.nio.*;
import java.util.Arrays;
import org.lwjgl.BufferUtils;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.GL;
import static org.lwjgl.opengl.GL43C.*;

/** 使用DH生产VanillaFade原shader验证四sampler、两矩阵、三float/三bool及近景保留分支。 */
public final class DistantVanillaFadeProbe {
    private static int checks,failures;
    private DistantVanillaFadeProbe() { }
    private static int depth(){int t=glGenTextures();glBindTexture(GL_TEXTURE_2D,t);glTexImage2D(GL_TEXTURE_2D,0,GL_DEPTH_COMPONENT32F,16,16,0,GL_DEPTH_COMPONENT,GL_FLOAT,(ByteBuffer)null);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_COMPARE_MODE,GL_NONE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,0);return t;}
    private static void fill(int texture,float value){glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,texture);FloatBuffer p=BufferUtils.createFloatBuffer(256);for(int i=0;i<256;i++)p.put(value);p.flip();glTexSubImage2D(GL_TEXTURE_2D,0,0,0,16,16,GL_DEPTH_COMPONENT,GL_FLOAT,p);}
    private static int location(int p,String name){int n=glGetUniformLocation(p,name);if(n<0)throw new AssertionError("inactive "+name);return n;}
    private static void pixel(String name,int[] expected){ByteBuffer b=BufferUtils.createByteBuffer(4);glReadPixels(8,8,1,1,GL_RGBA,GL_UNSIGNED_BYTE,b);int error=glGetError();boolean pass=error==0;int[] actual=new int[4];for(int i=0;i<4;i++){actual[i]=b.get(i)&255;pass&=Math.abs(actual[i]-expected[i])<=1;}checks++;if(!pass)failures++;System.out.println("AMCL_VANILLA_FADE_PIXEL label="+name+" passed="+pass+" error="+error+" expected="+Arrays.toString(expected)+" actual="+Arrays.toString(actual));}
    public static void main(String[] args){long window=0;try{
        if(!GLFW.glfwInit())throw new AssertionError("GLFW");GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MAJOR,3);GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR,3);GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_PROFILE,GLFW.GLFW_OPENGL_CORE_PROFILE);window=GLFW.glfwCreateWindow(64,64,"DH vanilla fade QA",0,0);if(window==0)throw new AssertionError("window");GLFW.glfwMakeContextCurrent(window);GL.createCapabilities();System.out.println("AMCL_VANILLA_FADE_IDENTITY "+glGetString(GL_VERSION));if(!GL.getCapabilities().OpenGL43)throw new AssertionError("GL43 binding unavailable");
        int p=DistantCompositeProbe.program(DistantCompositeProbe.source("shared/gl/quad_apply.vert"),DistantCompositeProbe.source("fade/gl/vanilla_fade.frag"));
        int vbo=glGenBuffers();glBindBuffer(GL_ARRAY_BUFFER,vbo);glBufferData(GL_ARRAY_BUFFER,new float[]{-1,-1,1,-1,1,1,-1,-1,1,1,-1,1},GL_STATIC_DRAW);
        int[] vaos={glGenVertexArrays(),glGenVertexArrays()};glBindVertexArray(vaos[0]);glVertexAttribPointer(0,2,GL_FLOAT,false,8,0L);glEnableVertexAttribArray(0);glBindVertexArray(vaos[1]);glVertexAttribFormat(0,2,GL_FLOAT,false,0);glVertexAttribBinding(0,0);glEnableVertexAttribArray(0);glBindVertexBuffer(0,vbo,0,8);
        int target=DistantCompositeProbe.color(0,0,1,255),red=DistantCompositeProbe.color(255,0,0,255),green=DistantCompositeProbe.color(0,255,0,255),empty=DistantCompositeProbe.color(0,255,0,0),mcDepth=depth(),dhDepth=depth();fill(dhDepth,.75f);
        int fbo=glGenFramebuffers();glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,target,0);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw new AssertionError("FBO");glViewport(0,0,16,16);glDisable(GL_DEPTH_TEST);glDisable(GL_STENCIL_TEST);glDisable(GL_CULL_FACE);glDisable(GL_BLEND);glDisable(GL_SCISSOR_TEST);
        for(int mode=0;mode<2;mode++)for(boolean reverse:new boolean[]{false,true})for(boolean absent:new boolean[]{false,true})for(boolean only:new boolean[]{false,true})for(boolean high:new boolean[]{false,true})for(int scene=0;scene<4;scene++){
            float distance=scene==0?1:scene==1?1.7f:2.5f;fill(mcDepth,scene==3?(reverse?0:1):(distance/3+1)/2);
            DistantCompositeProbe.bind(0,mcDepth);DistantCompositeProbe.bind(1,dhDepth);DistantCompositeProbe.bind(2,red);DistantCompositeProbe.bind(3,absent?empty:green);glUseProgram(p);
            String[] samplers={"uMcDepthTexture","uDhDepthTexture","uCombinedMcDhColorTexture","uDhColorTexture"};for(int i=0;i<4;i++)glUniform1i(location(p,samplers[i]),i);
            glUniform1i(location(p,"uOnlyRenderLods"),only?1:0);glUniform1i(location(p,"uIsMcReverseZDepth"),reverse?1:0);glUniform1i(location(p,"uDepthIsZeroToPositiveOne"),0);
            // actual阈值比例1.5/1.9，矩阵把受控NDC z映射到已知距离，不模拟整包相机全部自由度。
            glUniform1f(location(p,"uStartFadeBlockDistance"),1.5f);glUniform1f(location(p,"uEndFadeBlockDistance"),1.9f);glUniform1f(location(p,"uMaxLevelHeight"),512);
            glUniformMatrix4fv(location(p,"uMcInvMvmProj"),false,new float[]{0,0,0,0,0,0,0,0,0,0,3,0,0,0,0,1});glUniformMatrix4fv(location(p,"uDhInvMvmProj"),false,new float[]{0,0,0,0,0,0,0,0,0,0,3,0,0,high?600:0,0,1});
            glBindVertexArray(vaos[mode]);if(mode==1)glBindVertexBuffer(0,vbo,0,8);glDrawArrays(GL_TRIANGLES,0,6);
            int[] expected=only?new int[]{0,255,0,absent?0:255}:(high||scene==3)?new int[]{255,0,0,0}:absent||scene==0?new int[]{255,0,0,255}:scene==2?new int[]{0,255,0,255}:new int[]{128,128,0,255};
            pixel("binding="+mode+"-reverse="+reverse+"-absent="+absent+"-only="+only+"-high="+high+"-scene="+scene,expected);
        }
        for(int t:new int[]{target,red,green,empty,mcDepth,dhDepth})glDeleteTextures(t);for(int vao:vaos)glDeleteVertexArrays(vao);glDeleteBuffers(vbo);glDeleteFramebuffers(fbo);glDeleteProgram(p);
    }catch(Throwable error){failures++;error.printStackTrace();}finally{if(window!=0)GLFW.glfwDestroyWindow(window);GLFW.glfwTerminate();}System.out.println("AMCL_VANILLA_FADE_RESULT checks="+checks+" failures="+failures+" passed="+(failures==0));System.exit(failures==0?0:1);}
}
