package com.amcl.qa;

import com.sun.management.HotSpotDiagnosticMXBean;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.Paths;

/** 实际目标JDK的文件堆资格探针：核VM flag、文件共享映射及分配后数据；不代替整包长测。 */
public final class HeapBackingProbe {
    private static volatile long sink;
    public static void main(String[] args) throws Exception {
        HotSpotDiagnosticMXBean bean=ManagementFactory.getPlatformMXBean(HotSpotDiagnosticMXBean.class);
        String directory=bean.getVMOption("AllocateHeapAt").getValue();
        long maximum=Long.parseLong(bean.getVMOption("MaxHeapSize").getValue());
        if(directory.isEmpty() || !"false".equals(bean.getVMOption("IgnoreUnrecognizedVMOptions").getValue()))
            throw new AssertionError("File heap/strict options did not take effect");
        long mapped=0;int mappings=0;
        // O_TMPFILE/立即unlink的堆仍应出现在self maps；不靠目录内是否有文件判断。
        // 只汇总当前应用私有堆目录，不打印其他库/账户/映射路径。
        for(String line:Files.readAllLines(Paths.get("/proc/self/maps"))) {
            String[] fields=line.trim().split("\\s+",6);
            if(fields.length==6 && fields[1].length()==4 && fields[1].charAt(3)=='s' &&
                    fields[5].contains("/jvm-heap/")) {
                String[] range=fields[0].split("-");
                mapped+=Long.parseUnsignedLong(range[1],16)-Long.parseUnsignedLong(range[0],16);mappings++;
            }
        }
        if(mappings==0 || mapped<maximum)throw new AssertionError("No complete private file-backed heap mapping");
        int checks=0;
        for(int round=0;round<3;round++) {
            byte[][] blocks=new byte[24][];
            for(int b=0;b<blocks.length;b++) {
                blocks[b]=new byte[1024*1024];
                for(int p=0;p<blocks[b].length;p+=4096)blocks[b][p]=(byte)(b+round+1);
            }
            System.gc();
            for(int b=0;b<blocks.length;b++)for(int p=0;p<blocks[b].length;p+=4096) {
                if(blocks[b][p]!=(byte)(b+round+1))throw new AssertionError("Heap data changed");
                sink+=blocks[b][p];checks++;
            }
        }
        System.out.println("AMCL_HEAP_BACKING PASS maximum="+maximum+" mappedSharedBytes="+mapped+
            " mappings="+mappings+" dataChecks="+checks+" strict=true sink="+sink);
    }
}
