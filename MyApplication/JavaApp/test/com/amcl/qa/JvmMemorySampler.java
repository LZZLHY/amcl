package com.amcl.qa;

import java.io.*;
import java.lang.instrument.Instrumentation;
import java.lang.management.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import com.sun.management.HotSpotDiagnosticMXBean;

/**
 * 自愿启用的QA内存观测agent：不注册transformer、不修改模组或VM参数，每5秒同窗采Java堆与self proc。
 * 仅写Native已经准备的TMPDIR中的独占新文件；缺少proc字段明确记录不可用，不按RSS差额猜某个库。
 * daemon线程不参与游戏退出，逐点flush/fsync，系统kill时最后不足一个采样窗的数据仍可能缺失。
 */
public final class JvmMemorySampler {
    private JvmMemorySampler() { }
    private static final String[] PROC_KEYS={"VmPeak","VmSize","VmHWM","VmRSS","RssAnon","RssFile","RssShmem","VmData","VmStk","VmExe","VmLib","VmPTE","VmSwap","Threads"};

    /** premain失败只报告观测不可用，不改变被测游戏是否启动；不申请attach或其他进程权限。 */
    public static void premain(String arguments, Instrumentation instrumentation) {
        try {
            String temp=System.getenv("TMPDIR");if(temp==null)throw new IOException("missing native TMPDIR");
            File root=new File(temp);if(!root.isAbsolute()||!root.isDirectory())throw new IOException("invalid native TMPDIR");
            String process=ManagementFactory.getRuntimeMXBean().getName().split("@",2)[0];if(!process.matches("[0-9]+"))throw new IOException("invalid PID");
            File file=File.createTempFile("amcl-memory-"+process+"-",".jsonl",root);
            System.err.println("AMCL_MEMORY_SAMPLER path="+file.getCanonicalPath()+" intervalMs=5000 transforms=none");
            Thread sampler=new Thread(new Runnable(){public void run(){sample(file,process);}},"AMCL-memory-sampler");sampler.setDaemon(true);sampler.start();
        } catch(OutOfMemoryError exhausted){
            // 观测器自身分配失败时静默撤出，不能触发模组安装的全局未捕获异常处理器；不声称游戏内存已恢复。
        } catch(Exception failure){System.err.println("AMCL_MEMORY_SAMPLER unavailable="+failure.getClass().getSimpleName());}
    }

    /** 诊断文件为本进程亲建；大小和时长有上限，不创建shutdown hook延迟正常退出。 */
    private static void sample(File file,String pid) {
        try(FileOutputStream stream=new FileOutputStream(file);Writer writer=new OutputStreamWriter(stream,StandardCharsets.UTF_8)){
            writer.write("{\"kind\":\"header\",\"pid\":"+pid+",\"at\":"+System.currentTimeMillis()+",\"vmOptions\":"+vmOptions()+",\"heapMappings\":"+heapMappings()+"}\n");writer.flush();stream.getFD().sync();
            int errors=0;
            for(int sequence=0;sequence<1800 && file.length()<8L*1024*1024;sequence++){
                try{
                    long begin=System.currentTimeMillis();MemoryUsage heap=ManagementFactory.getMemoryMXBean().getHeapMemoryUsage();MemoryUsage nonHeap=ManagementFactory.getMemoryMXBean().getNonHeapMemoryUsage();
                    TreeMap<String,Long> proc=new TreeMap<String,Long>();String statusError=readProc("/proc/self/status",proc,Arrays.asList(PROC_KEYS),"status.");
                    String rollupError=readProc("/proc/self/smaps_rollup",proc,Arrays.asList("Rss","Pss","Shared_Clean","Shared_Dirty","Private_Clean","Private_Dirty","Swap","SwapPss"),"rollup.");
                    long direct=0,mapped=0;for(BufferPoolMXBean pool:ManagementFactory.getPlatformMXBeans(BufferPoolMXBean.class)){if(pool.getName().equals("direct"))direct=pool.getMemoryUsed();if(pool.getName().equals("mapped"))mapped=pool.getMemoryUsed();}
                    StringBuilder gc=new StringBuilder("[");boolean first=true;for(GarbageCollectorMXBean collector:ManagementFactory.getGarbageCollectorMXBeans()){if(!first)gc.append(',');first=false;gc.append("{\"name\":").append(quote(collector.getName())).append(",\"count\":").append(collector.getCollectionCount()).append(",\"timeMs\":").append(collector.getCollectionTime()).append('}');}gc.append(']');
                    StringBuilder record=new StringBuilder("{\"kind\":\"sample\",\"pid\":").append(pid).append(",\"sequence\":").append(sequence).append(",\"beginEpochMs\":").append(begin).append(",\"endEpochMs\":").append(System.currentTimeMillis());
                    record.append(",\"uptimeMs\":").append(ManagementFactory.getRuntimeMXBean().getUptime()).append(",\"heapUsedBytes\":").append(heap.getUsed()).append(",\"heapCommittedBytes\":").append(heap.getCommitted()).append(",\"heapMaxBytes\":").append(heap.getMax()).append(",\"nonHeapUsedBytes\":").append(nonHeap.getUsed()).append(",\"directBytes\":").append(direct).append(",\"mappedBytes\":").append(mapped).append(",\"javaThreads\":").append(ManagementFactory.getThreadMXBean().getThreadCount()).append(",\"procKB\":{");
                    first=true;for(Map.Entry<String,Long> entry:proc.entrySet()){if(!first)record.append(',');first=false;record.append(quote(entry.getKey())).append(':').append(entry.getValue());}
                    record.append("},\"statusError\":").append(quote(statusError)).append(",\"rollupError\":").append(quote(rollupError)).append(",\"gc\":").append(gc).append("}\n");
                    writer.write(record.toString());writer.flush();stream.getFD().sync();errors=0;
                }catch(Exception failure){writer.write("{\"kind\":\"error\",\"at\":"+System.currentTimeMillis()+",\"type\":"+quote(failure.getClass().getSimpleName())+"}\n");writer.flush();if(++errors>=3)break;}
                try{Thread.sleep(5000);}catch(InterruptedException stop){break;}
            }
        }catch(OutOfMemoryError exhausted){
            // 堆耗尽本身由原游戏日志取证。此处不再拼接字符串、申请缓冲区或启动重试线程。
        }catch(Exception failure){System.err.println("AMCL_MEMORY_SAMPLER stopped="+failure.getClass().getSimpleName());}
    }
    /** 只读本进程，小型proc接口最多256行；Threads是数量，单独保留键名，不能当KB相加。 */
    private static String readProc(String path,Map<String,Long> result,List<String> keys,String prefix){
        try(BufferedReader reader=new BufferedReader(new FileReader(path))){
            for(int i=0;i<256;i++){String line=reader.readLine();if(line==null)return "";int colon=line.indexOf(':');if(colon<0)continue;String key=line.substring(0,colon);if(!keys.contains(key))continue;String value=line.substring(colon+1).trim().split("\\s+")[0];if(value.matches("[0-9]+"))result.put(prefix+key,Long.parseLong(value));}
            return "line-budget";
        }catch(Exception failure){return failure.getClass().getSimpleName();}
    }
    private static String vmOptions(){
        try{HotSpotDiagnosticMXBean bean=ManagementFactory.getPlatformMXBean(HotSpotDiagnosticMXBean.class);StringBuilder result=new StringBuilder("{");boolean first=true;for(String name:new String[]{"UseG1GC","UseParallelGC","UseCompressedOops","UseCompressedClassPointers","MaxHeapSize","InitialHeapSize","G1HeapRegionSize","AllocateHeapAt","IgnoreUnrecognizedVMOptions"}){if(!first)result.append(',');first=false;String value;try{value=bean.getVMOption(name).getValue();}catch(Exception missing){value="unavailable:"+missing.getClass().getSimpleName();}result.append(quote(name)).append(':').append(quote(value));}return result.append('}').toString();}
        catch(Exception unavailable){return "{}";}
    }
    /** 启动时仅记录本进程私有文件堆映射，最多8192行/2MiB/64条；不打印无关库路径。
     * 映射字节是地址范围，不等于RSS。缺失或截断明确记录，不能把空目录视为未启用。
     */
    private static String heapMappings(){
        StringBuilder rows=new StringBuilder("[");long bytes=0;int count=0,characters=0;String error="";
        try(BufferedReader reader=new BufferedReader(new FileReader("/proc/self/maps"))){
            for(int i=0;i<8192;i++){
                String line=reader.readLine();if(line==null)break;
                characters+=line.length();if(characters>2*1024*1024){error="byte-budget";break;}
                String[] fields=line.trim().split("\\s+",6);
                if(fields.length==6 && fields[1].length()==4 && fields[1].charAt(3)=='s' && fields[5].contains("/jvm-heap/")){
                    if(count>=64){error="entry-budget";break;}
                    String[] range=fields[0].split("-");long span=Long.parseUnsignedLong(range[1],16)-Long.parseUnsignedLong(range[0],16);
                    if(span<=0)throw new IOException("invalid range");bytes+=span;
                    if(count++>0)rows.append(',');rows.append("{\"range\":").append(quote(fields[0])).append(",\"permissions\":").append(quote(fields[1])).append(",\"device\":").append(quote(fields[3])).append(",\"inode\":").append(quote(fields[4])).append(",\"path\":").append(quote(fields[5])).append('}');
                }
                if(i==8191)error="line-budget";
            }
        }catch(Exception failure){error=failure.getClass().getSimpleName();}
        return "{\"mappedSharedBytes\":"+bytes+",\"ranges\":"+rows.append(']')+",\"error\":"+quote(error)+"}";
    }
    private static String quote(String value){return '"'+value.replace("\\","\\\\").replace("\"","\\\"").replace("\n","\\n").replace("\r","\\r")+'"';}
}
