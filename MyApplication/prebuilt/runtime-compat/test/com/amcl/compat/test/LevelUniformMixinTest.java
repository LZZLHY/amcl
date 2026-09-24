package com.amcl.compat.test;

import com.amcl.compat.CompatMixinPlugin;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.util.ArrayList;
import java.util.List;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.*;
import org.spongepowered.asm.launch.MixinBootstrap;
import org.spongepowered.asm.mixin.MixinEnvironment;
import org.spongepowered.asm.mixin.Mixins;
import org.spongepowered.asm.mixin.transformer.IMixinTransformer;

/** 从真实类推导写入边界，再验证实际Mixin把该容量送进原构造器；不加载Minecraft或GPU。 */
public final class LevelUniformMixinTest implements Opcodes {
    private static byte[] bytes(String name) throws Exception {
        try(InputStream input=LevelUniformMixinTest.class.getClassLoader().getResourceAsStream(name.replace('.','/')+".class")) {
            if(input==null)throw new AssertionError("missing fixture "+name);
            return input.readAllBytes();
        }
    }
    private static ClassNode read(byte[] bytes) { ClassNode node=new ClassNode();new ClassReader(bytes).accept(node,0);return node; }
    private static void require(boolean condition,String text) {if(!condition)throw new AssertionError(text);}

    /** 只解释真实writer的指针加载/加法/原生4字节写入；出现未审查指令便失败，不能猜宽度。 */
    private static List<Integer> writes(MethodNode method) {
        List<Long> stack=new ArrayList<>();List<Integer> stores=new ArrayList<>();
        for(AbstractInsnNode instruction:method.instructions){
            int op=instruction.getOpcode();if(op<0)continue;
            if(instruction instanceof VarInsnNode variable){
                require(op==LLOAD||op==FLOAD||op==ILOAD,"unexpected writer local");
                stack.add(0L); // ptr相对基址为0，值参数不参与寻址。
            }else if(instruction instanceof LdcInsnNode constant)stack.add(((Number)constant.cst).longValue());
            else if(op==FCONST_0||op==LCONST_0||op==ICONST_0)stack.add(0L);
            else if(op==LADD){long right=stack.remove(stack.size()-1);long left=stack.remove(stack.size()-1);stack.add(left+right);}
            else if(instruction instanceof MethodInsnNode call){
                require(call.owner.equals("org/lwjgl/system/MemoryUtil")&&(call.name.equals("memPutInt")||call.name.equals("memPutFloat")),"unexpected writer call");
                stack.remove(stack.size()-1);stores.add(Math.toIntExact(stack.remove(stack.size()-1)));
            }else if(op==LRETURN){stores.add(-Math.toIntExact(stack.remove(stack.size()-1)));}
            else throw new AssertionError("unexpected writer opcode "+op);
        }
        return stores;
    }
    private static final class ByteLoader extends ClassLoader {
        Class<?> define(byte[] value){return defineClass(null,value,0,value.length);}
    }
    public static void main(String[] ignored) throws Exception {
        byte[] level=bytes(CompatMixinPlugin.LEVEL_TARGET),writer=bytes(CompatMixinPlugin.WRITER_TARGET),buffer=bytes(CompatMixinPlugin.BUFFER_TARGET);
        require(CompatMixinPlugin.matchesLevelUniforms(level,writer,buffer),"known layout rejected");
        byte[][] fixtures={level,writer,buffer};
        for(int i=0;i<3;i++){
            byte[][] changed={level,writer,buffer};changed[i]=fixtures[i].clone();changed[i][changed[i].length-1]^=1;
            require(!CompatMixinPlugin.matchesLevelUniforms(changed[0],changed[1],changed[2]),"changed layout admitted");
            changed[i]=null;require(!CompatMixinPlugin.matchesLevelUniforms(changed[0],changed[1],changed[2]),"missing layout admitted");
        }

        ClassNode old=read(level),helpers=read(writer);
        int cursor=0,extent=0,oldSize=-1,scalarWrites=0,vectorWrites=0;
        for(MethodNode method:old.methods){
            for(AbstractInsnNode instruction:method.instructions){
                if(!(instruction instanceof MethodInsnNode call))continue;
                if(method.name.equals("<clinit>")&&call.name.equals("<init>")&&call.owner.endsWith("/UniformBuffer")){
                    AbstractInsnNode previous=call.getPrevious();
                    require(previous instanceof IntInsnNode,"fixture allocation shape changed");oldSize=((IntInsnNode)previous).operand;
                }
                if(!method.name.equals("update")||!method.desc.contains("RenderContext;")||!call.name.startsWith("write"))continue;
                MethodNode helper=helpers.methods.stream().filter(m->m.name.equals(call.name)&&m.desc.equals(call.desc)).findFirst().orElseThrow();
                List<Integer> positions=writes(helper);int advance=0;
                for(int position:positions){if(position<0)advance=-position;else extent=Math.max(extent,cursor+position+4);}
                require(advance>0,"missing writer advance");cursor+=advance;
                if(advance==4)scalarWrites++;else if(advance==16)vectorWrites++;else throw new AssertionError("unexpected width");
            }
        }
        require(oldSize==112&&extent==116&&cursor==116&&scalarWrites==13&&vectorWrites==4,"real layout no longer proves the four-byte overflow");

        MixinBootstrap.init();MixinEnvironment.getDefaultEnvironment().setSide(MixinEnvironment.Side.CLIENT);
        Mixins.addConfiguration("amcl-runtime-compat.mixins.json");
        Constructor<?> constructor=Class.forName("org.spongepowered.asm.mixin.transformer.MixinTransformer").getDeclaredConstructor();constructor.setAccessible(true);
        IMixinTransformer transformer=(IMixinTransformer)constructor.newInstance();
        ClassNode transformed=read(transformer.transformClassBytes(CompatMixinPlugin.LEVEL_TARGET,CompatMixinPlugin.LEVEL_TARGET,level));
        MethodNode capacity=transformed.methods.stream().filter(m->m.name.contains("amcl$levelUniformCapacity")).findFirst().orElseThrow();
        boolean passedToConstructor=false;
        for(MethodNode method:transformed.methods)if(method.name.equals("<clinit>"))for(AbstractInsnNode instruction:method.instructions){
            if(instruction instanceof MethodInsnNode call&&call.name.equals("<init>")&&call.owner.endsWith("/UniformBuffer"))
                passedToConstructor=call.getPrevious() instanceof MethodInsnNode arg&&arg.name.equals(capacity.name);
        }
        require(passedToConstructor,"changed size not consumed by actual allocation");
        // 执行实际变换后的纯容量方法，避免测试另写一份Math.max逻辑却没有覆盖生产方法。
        ClassWriter generated=new ClassWriter(ClassWriter.COMPUTE_FRAMES|ClassWriter.COMPUTE_MAXS);
        generated.visit(V21,ACC_PUBLIC,"com/amcl/compat/test/GeneratedLevelCapacity",null,"java/lang/Object",null);
        capacity.access=ACC_PUBLIC|ACC_STATIC;capacity.name="capacity";capacity.accept(generated);generated.visitEnd();
        var apply=new ByteLoader().define(generated.toByteArray()).getMethod("capacity",int.class);
        int fixed=(Integer)apply.invoke(null,oldSize);
        require(fixed==128&&fixed%16==0&&extent<=fixed,"patched storage still too small");
        require((Integer)apply.invoke(null,256)==256,"larger compatible allocation was shrunk");
        System.out.println("[level-uniform-mixin] PASS actual bytecode: 4 vectors + 13 scalars = 116 bytes; original 112 overflows by 4; actual Mixin allocation 128; all three fingerprint negatives rejected");
    }
}
