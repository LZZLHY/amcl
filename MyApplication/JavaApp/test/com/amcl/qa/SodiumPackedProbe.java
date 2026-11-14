package com.amcl.qa;

import java.io.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import org.lwjgl.BufferUtils;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.GL;
import static org.lwjgl.opengl.GL33C.*;

/** 原Sodium0.8.13着色器+Compact20输入，与原1.21.1实体着色器交替；只用于独立QA实例。 */
public final class SodiumPackedProbe {
    private static final int[][] COLORS={{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,255,255}};
    private static int checks,failures,program;
    private static final List<Integer> buffers=new ArrayList<Integer>(),vaos=new ArrayList<Integer>(),textures=new ArrayList<Integer>();
    private SodiumPackedProbe() { }
    /** 仅展开原JAR的import；资源在制备阶段逐条与固定官方JAR核同，不改原包shader。 */
    private static String source(String path,int depth)throws Exception{
        if(depth>8)throw new IOException("include depth");InputStream in=SodiumPackedProbe.class.getResourceAsStream("/assets/sodium/shaders/"+path);if(in==null)throw new IOException(path);
        ByteArrayOutputStream out=new ByteArrayOutputStream();try{byte[] b=new byte[4096];int n;while((n=in.read(b))>=0){if(out.size()+n>65536)throw new IOException("shader budget");out.write(b,0,n);}}finally{in.close();}
        StringBuilder hash=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(out.toByteArray()))hash.append(String.format(Locale.ROOT,"%02x",b&255));System.out.println("AMCL_SODIUM_SOURCE path="+path+" sha256="+hash);
        StringBuilder text=new StringBuilder();for(String line:new String(out.toByteArray(),StandardCharsets.UTF_8).split("\\r?\\n")){
            String t=line.trim();if(t.startsWith("#import <sodium:")&&t.endsWith(">")){String name=t.substring(16,t.length()-1);if(!name.matches("[A-Za-z0-9_./-]+")||name.contains(".."))throw new IOException("include name");text.append(source(name,depth+1));}else text.append(line).append('\n');
        }return text.toString();
    }
    private static int shader(int kind,String text){int s=glCreateShader(kind);glShaderSource(s,text);glCompileShader(s);if(glGetShaderi(s,GL_COMPILE_STATUS)==0)throw new AssertionError(glGetShaderInfoLog(s));return s;}
    private static int sodiumProgram()throws Exception{
        float maxBias=glGetFloat(GL_MAX_TEXTURE_LOD_BIAS);if(!(maxBias>=2&&maxBias<1000))throw new AssertionError("MAX_TEXTURE_LOD_BIAS "+maxBias);
        String define="\n#define USE_VERTEX_COMPRESSION\n#define USE_FOG\n#define MAX_TEXTURE_LOD_BIAS "+maxBias+"\n";
        String vs=source("blocks/block_layer_opaque.vsh",0).replace("#version 330 core","#version 330 core"+define),fs=source("blocks/block_layer_opaque.fsh",0).replace("#version 330 core","#version 330 core"+define);
        int v=shader(GL_VERTEX_SHADER,vs),f=shader(GL_FRAGMENT_SHADER,fs),p=glCreateProgram();glAttachShader(p,v);glAttachShader(p,f);
        String[] names={"a_Position","a_Color","a_TexCoord","a_LightAndData"};for(int i=0;i<4;i++)glBindAttribLocation(p,i,names[i]);glLinkProgram(p);if(glGetProgrami(p,GL_LINK_STATUS)==0)throw new AssertionError(glGetProgramInfoLog(p));
        for(int i=0;i<4;i++)if(glGetAttribLocation(p,names[i])!=i)throw new AssertionError("Sodium attribute "+names[i]);glDeleteShader(v);glDeleteShader(f);return p;
    }
    /** 与CompactChunkVertex完全相同的20bit高/低10bit拆分；每顶点20字节，属性整数/归一化严格区分。 */
    private static int vao(int material,float leftW,float rightW){
        int vao=glGenVertexArrays(),vbo=glGenBuffers(),ebo=glGenBuffers();vaos.add(vao);buffers.add(vbo);buffers.add(ebo);glBindVertexArray(vao);glBindBuffer(GL_ARRAY_BUFFER,vbo);
        ByteBuffer data=BufferUtils.createByteBuffer(80).order(ByteOrder.nativeOrder());float[][] corners={{-1,-1,0,0},{1,-1,1,0},{1,1,1,1},{-1,1,0,1}};
        for(float[] c:corners){float w=c[0]<0?leftW:rightW;float[] xyz={c[0]*w,c[1]*w,-w};int hi=0,lo=0;for(int axis=0;axis<3;axis++){int q=Math.round((xyz[axis]+8)*32768);if(q<0||q>=1048576)throw new AssertionError("position range");hi|=(q>>>10)<<(axis*10);lo|=(q&1023)<<(axis*10);}data.putInt(hi).putInt(lo).putInt(-1);data.putShort((short)(c[2]==0?32768:32767)).putShort((short)(c[3]==0?32768:32767));data.put((byte)128).put((byte)128).put((byte)material).put((byte)0);}
        data.flip();glBufferData(GL_ARRAY_BUFFER,data,GL_STATIC_DRAW);glVertexAttribIPointer(0,2,GL_UNSIGNED_INT,20,0L);glVertexAttribPointer(1,4,GL_UNSIGNED_BYTE,true,20,8L);glVertexAttribIPointer(2,2,GL_UNSIGNED_SHORT,20,12L);glVertexAttribIPointer(3,4,GL_UNSIGNED_BYTE,20,16L);for(int i=0;i<4;i++)glEnableVertexAttribArray(i);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,ebo);ShortBuffer indices=BufferUtils.createShortBuffer(6);indices.put(new short[]{0,1,2,0,2,3}).flip();glBufferData(GL_ELEMENT_ARRAY_BUFFER,indices,GL_STATIC_DRAW);return vao;
    }
    private static int texture(int size,int[] solid){
        int t=glGenTextures();textures.add(t);glBindTexture(GL_TEXTURE_2D,t);int levels=solid==null?Integer.numberOfTrailingZeros(size)+1:1;
        for(int level=0;level<levels;level++){int n=size>>level;ByteBuffer data=BufferUtils.createByteBuffer(n*n*4);for(int y=0;y<n;y++)for(int x=0;x<n;x++){int[] c=solid!=null?solid:level>0?COLORS[level%4]:COLORS[(y>=n/2?2:0)+(x>=n/2?1:0)];for(int value:c)data.put((byte)value);}data.flip();glTexImage2D(GL_TEXTURE_2D,level,GL_RGBA8,n,n,0,GL_RGBA,GL_UNSIGNED_BYTE,data);}
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,solid==null?GL_NEAREST_MIPMAP_NEAREST:GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,levels-1);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);return t;
    }
    private static void bind(int unit,int texture){glActiveTexture(GL_TEXTURE0+unit);glBindTexture(GL_TEXTURE_2D,texture);glBindSampler(unit,0);}
    private static void uniforms(){
        glUseProgram(program);float[] identity={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1},projection={1,0,0,0,0,1,0,0,0,0,-100.1f/99.9f,-1,0,0,-20f/99.9f,0};glUniformMatrix4fv(glGetUniformLocation(program,"u_ModelViewMatrix"),false,identity);glUniformMatrix4fv(glGetUniformLocation(program,"u_ProjectionMatrix"),false,projection);glUniform3f(glGetUniformLocation(program,"u_RegionOffset"),0,0,0);glUniform2f(glGetUniformLocation(program,"u_TexCoordShrink"),0,0);glUniform1i(glGetUniformLocation(program,"u_LightTex"),1);glUniform1i(glGetUniformLocation(program,"u_BlockTex"),0);glUniform1i(glGetUniformLocation(program,"u_FogShape"),0);glUniform1f(glGetUniformLocation(program,"u_FogStart"),1000);glUniform1f(glGetUniformLocation(program,"u_FogEnd"),2000);glUniform4f(glGetUniformLocation(program,"u_FogColor"),0,0,0,1);
    }
    private static void draw(int vao){glBindVertexArray(vao);glDrawElements(GL_TRIANGLES,6,GL_UNSIGNED_SHORT,0L);}
    private static void pixel(String name,int x,int y,int[] expected){ByteBuffer b=BufferUtils.createByteBuffer(4);glReadPixels(x,y,1,1,GL_RGBA,GL_UNSIGNED_BYTE,b);int error=glGetError();boolean ok=error==0;int[] actual=new int[4];for(int i=0;i<4;i++){actual[i]=b.get(i)&255;ok&=Math.abs(actual[i]-expected[i])<=1;}checks++;if(!ok)failures++;System.out.println("AMCL_SODIUM_PIXEL label="+name+" passed="+ok+" error="+error+" expected="+Arrays.toString(expected)+" actual="+Arrays.toString(actual));}
    public static void main(String[] args){long window=0;try{
        if(!GLFW.glfwInit())throw new AssertionError("GLFW init");GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MAJOR,3);GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR,3);GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_PROFILE,GLFW.GLFW_OPENGL_CORE_PROFILE);window=GLFW.glfwCreateWindow(64,64,"Sodium packed QA",0,0);if(window==0)throw new AssertionError("GLFW window");GLFW.glfwMakeContextCurrent(window);GL.createCapabilities();System.out.println("AMCL_SODIUM_IDENTITY "+glGetString(GL_VERSION));
        int fbo=glGenFramebuffers(),color=texture(64,COLORS[3]),depth=glGenTextures();textures.add(depth);glBindTexture(GL_TEXTURE_2D,depth);glTexImage2D(GL_TEXTURE_2D,0,GL_DEPTH_COMPONENT32F,64,64,0,GL_DEPTH_COMPONENT,GL_FLOAT,(ByteBuffer)null);glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,color,0);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_TEXTURE_2D,depth,0);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw new AssertionError("FBO");glDisable(GL_DEPTH_TEST);glDisable(GL_BLEND);glDisable(GL_CULL_FACE);glDisable(GL_SCISSOR_TEST);
        program=sodiumProgram();int entity=VanillaEntityProbe.program(VanillaEntityProbe.source("core/rendertype_entity_solid.vsh",true,0),VanillaEntityProbe.source("core/rendertype_entity_solid.fsh",true,0),false);int evbo=glGenBuffers(),eebo=glGenBuffers();buffers.add(evbo);buffers.add(eebo);int entityVao=VanillaEntityProbe.vao(false,true,evbo,eebo);vaos.add(entityVao);
        int[] geometry={vao(1,2,2),vao(0,2,2),vao(1,2,6),vao(0,2,6)};int far=vao(1,8,8);int small=texture(2,null),large=texture(16,null),white=texture(16,COLORS[3]),red=texture(16,COLORS[0]),blue=texture(16,COLORS[2]),green=texture(16,COLORS[1]);
        // 16x16到8x8的已知缩小：material1选绿色mip1，material0的负bias选基级四象限。
        for(int mode=0;mode<2;mode++){glViewport(0,0,8,8);bind(0,large);bind(1,white);uniforms();draw(geometry[mode]);for(int y:new int[]{1,6})for(int x:new int[]{1,6})pixel("material-bias-"+mode+"-"+x+"-"+y,x,y,mode==0?COLORS[1]:COLORS[(y>4?2:0)+(x>4?1:0)]);}
        // 两种实际shader/顶点格式和不同stage资源交替32draw，末尾才读回；不靠每draw读回清缓存。
        for(int round=0;round<3;round++){
            for(int tile=0;tile<32;tile++){glViewport((tile%8)*8,(tile/8)*8,8,8);bind(0,small);bind(2,white);if((tile&1)==0){bind(1,tile%4==0?red:white);uniforms();draw(geometry[(tile/2+round)%4]);}else{bind(1,blue);VanillaEntityProbe.uniforms(entity,1);draw(entityVao);}}
            for(int tile=0;tile<32;tile++)for(int y:new int[]{1,6})for(int x:new int[]{1,6}){int[] c=COLORS[(y>4?2:0)+(x>4?1:0)].clone();if(tile%4==0){c[1]=0;c[2]=0;}pixel("mixed-"+round+"-"+tile+"-"+x+"-"+y,(tile%8)*8+x,(tile/8)*8+y,c);}
        }
        // 世界近面 -> active pass仅clear depth -> 实体远面 -> 更远面：只在末尾检查最终红色。
        glEnable(GL_DEPTH_TEST);glDepthFunc(GL_LESS);glDepthMask(true);glViewport(0,0,64,64);glClearDepth(1);glClear(GL_DEPTH_BUFFER_BIT);bind(0,blue);bind(1,white);uniforms();draw(geometry[0]);glClear(GL_DEPTH_BUFFER_BIT);
        bind(0,red);bind(1,blue);bind(2,white);VanillaEntityProbe.uniforms(entity,1);float[] farther={2,0,0,0,0,2,0,0,0,0,1,0,0,0,-2,1};glUniformMatrix4fv(glGetUniformLocation(entity,"ModelViewMat"),false,farther);draw(entityVao);
        bind(0,green);bind(1,white);uniforms();draw(far);for(int y:new int[]{16,48})for(int x:new int[]{16,48})pixel("depth-only-clear-"+x+"-"+y,x,y,COLORS[0]);
        glDeleteProgram(program);glDeleteProgram(entity);for(int v:vaos)glDeleteVertexArrays(v);for(int b:buffers)glDeleteBuffers(b);for(int t:textures)glDeleteTextures(t);glDeleteFramebuffers(fbo);
    }catch(Throwable error){failures++;error.printStackTrace();}finally{if(window!=0)GLFW.glfwDestroyWindow(window);GLFW.glfwTerminate();}System.out.println("AMCL_SODIUM_RESULT checks="+checks+" failures="+failures+" passed="+(failures==0));System.exit(failures==0?0:1);}
}
