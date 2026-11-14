package com.amcl.qa;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.*;
import java.security.MessageDigest;
import java.util.*;

/** Java 8 文件系统能力夹具：只写本轮独占目录，不修改现有游戏实例，不替生产代码吞错。 */
public final class FileMoveProbe {
    private interface Action { void run() throws Exception; }
    private static final List<Path> owned = new ArrayList<Path>();
    private static int operations, failures;
    private static boolean retainFixtures;
    private static final FileTime FIXED = FileTime.fromMillis(1600000000000L);
    private static final byte[] DATA = new byte[4096];
    static { for (int i=0;i<DATA.length;i++) DATA[i]=(byte)(i*31+7); }

    /** 以固定顺序生成小型观测对象，便于逐行核对。 */
    private static Map<String,Object> map(Object... entries) {
        Map<String,Object> value=new LinkedHashMap<String,Object>();
        for(int i=0;i<entries.length;i+=2) value.put((String)entries[i],entries[i+1]);
        return value;
    }
    /** 不引入额外运行库；为字符串控制字符作JSON转义。 */
    private static String json(Object value) {
        if(value==null)return "null";
        if(value instanceof Number || value instanceof Boolean)return value.toString();
        if(value instanceof Map) {
            StringBuilder s=new StringBuilder("{"); boolean first=true;
            for(Object raw:((Map<?,?>)value).entrySet()) {
                Map.Entry<?,?> e=(Map.Entry<?,?>)raw;
                if(!first)s.append(','); first=false;
                s.append(json(e.getKey().toString())).append(':').append(json(e.getValue()));
            }
            return s.append('}').toString();
        }
        if(value instanceof Iterable) {
            StringBuilder s=new StringBuilder("["); boolean first=true;
            for(Object item:(Iterable<?>)value) { if(!first)s.append(',');first=false;s.append(json(item)); }
            return s.append(']').toString();
        }
        StringBuilder s=new StringBuilder("\"");
        for(char c:value.toString().toCharArray()) {
            if(c=='"'||c=='\\')s.append('\\').append(c);
            else if(c<32)s.append(String.format(Locale.ROOT,"\\u%04x",(int)c));
            else s.append(c);
        }
        return s.append('"').toString();
    }
    /** 仅写标准输出，由父任务的会话账本收集。 */
    private static void emit(Map<String,Object> event) { System.out.println(json(event));System.out.flush(); }
    /** 保留异常类型、原因和前五帧，不能把EPERM简化成成功。 */
    private static Map<String,Object> error(Exception e) {
        List<String> trace=new ArrayList<String>();
        for(int i=0;i<Math.min(5,e.getStackTrace().length);i++)trace.add(e.getStackTrace()[i].toString());
        Map<String,Object> result=map("class",e.getClass().getName(),"message",e.getMessage(),"stack",trace);
        if(e instanceof FileSystemException) {
            FileSystemException f=(FileSystemException)e;
            result.put("reason",f.getReason());result.put("file",f.getFile());result.put("otherFile",f.getOtherFile());
        }
        return result;
    }
    /** 摘要读取可能更新atime，快照会另记读取前后时间。 */
    private static String sha(Path path) throws Exception {
        MessageDigest d=MessageDigest.getInstance("SHA-256");
        byte[] buffer=new byte[4096];
        try(InputStream in=Files.newInputStream(path)) { int n;while((n=in.read(buffer))>=0)if(n>0)d.update(buffer,0,n); }
        StringBuilder s=new StringBuilder();for(byte b:d.digest())s.append(String.format(Locale.ROOT,"%02x",b&255));return s.toString();
    }
    /** 记录提供者实际返回的时间和文件身份。 */
    private static Map<String,Object> attrs(BasicFileAttributes a) {
        return map("size",a.size(),"mtimeMillis",a.lastModifiedTime().toMillis(),"atimeMillis",a.lastAccessTime().toMillis(),
            "creationMillis",a.creationTime().toMillis(),"regular",a.isRegularFile(),"fileKey",String.valueOf(a.fileKey()));
    }
    /** 先读属性再算摘要，明确区分文件不存在与观测失败。 */
    private static Map<String,Object> snapshot(Path path) {
        if(path==null)return null;
        Map<String,Object> result=map("path",path.toString());
        try {
            BasicFileAttributes a=Files.readAttributes(path,BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);
            result.put("exists",true);result.put("attributesBeforeHash",attrs(a));
            if(a.isRegularFile()&&!a.isSymbolicLink()) {
                result.put("sha256",sha(path));
                result.put("atimeAfterHashMillis",Files.readAttributes(path,BasicFileAttributes.class).lastAccessTime().toMillis());
            }
        } catch(NoSuchFileException e) { result.put("exists",false); }
        catch(Exception e) { result.put("observationError",error(e)); }
        return result;
    }
    /** 仅登记独占根内的固定文件名；清理不递归遍历外部目录。 */
    private static Path reserve(Path dir,String name) { Path p=dir.resolve(name);owned.add(p);return p; }
    /** 用CREATE_NEW保证样本不能覆盖同名旧文件。 */
    private static Path create(Path dir,String name) throws Exception {
        Path p=reserve(dir,name);Files.write(p,DATA,StandardOpenOption.CREATE_NEW,StandardOpenOption.WRITE);return p;
    }
    /** 父目录须已存在；本轮目录一旦重名就停止，不接管旧现场。 */
    private static Path root(String text,String nonce) throws Exception {
        Path parent=Paths.get(text);
        if(!parent.isAbsolute()||Files.isSymbolicLink(parent)||!Files.isDirectory(parent))throw new IOException("Root must be an existing absolute ordinary directory: "+parent);
        parent=parent.toRealPath();Path p=parent.resolve("amcl-nio-probe-"+nonce);
        Files.createDirectory(p);owned.add(p);return p;
    }
    /** 逐操作记录前后状态；null表示能力未知的纯观测，不把规范允许的拒绝算作错误。 */
    private static void operation(String name,Boolean expectedFailure,Path source,Path target,Action action) {
        Map<String,Object> event=map("event","operation","name",name,"expectedFailure",expectedFailure,
            "sourceBefore",snapshot(source),"targetBefore",snapshot(target));
        boolean succeeded=false;
        try { action.run();succeeded=true; } catch(Exception e) { event.put("exception",error(e)); }
        event.put("returnedNormally",succeeded);
        Map<String,Object> after=snapshot(source);
        event.put("sourceAfter",after);event.put("targetAfter",snapshot(target));
        event.put("expectedOutcome",expectedFailure==null?"unknown":(expectedFailure?"exception":"normal-return"));
        event.put("expectationMatched",expectedFailure==null?null:succeeded!=expectedFailure);
        if(expectedFailure!=null&&succeeded==expectedFailure)failures++;
        if(expectedFailure==null&&!succeeded)retainFixtures=true;
        if(name.endsWith(".setTimes.creation")&&succeeded&&after!=null) {
            Object attributes=after.get("attributesBeforeHash");
            Object observed=attributes instanceof Map?((Map<?,?>)attributes).get("creationMillis"):null;
            event.put("requestedCreationMillis",FIXED.toMillis());
            event.put("creationEffect",observed instanceof Number&&((Number)observed).longValue()==FIXED.toMillis()
                ?"requested-value-observed":"ignored-or-unsupported; normal return is not proof of modification");
        }
        operations++;emit(event);
    }
    /** basic视图存在不等于每一种时间可设置；同时保存真实FileStore与设备号。 */
    private static void describe(String label,Path dir) {
        Map<String,Object> event=map("event","root","name",label,"path",dir.toString());
        try {
            FileStore store=Files.getFileStore(dir);
            event.put("store",map("name",store.name(),"type",store.type(),"readOnly",store.isReadOnly(),
                "basic",store.supportsFileAttributeView("basic"),"posix",store.supportsFileAttributeView("posix")));
            event.put("provider",dir.getFileSystem().provider().getClass().getName());
            try { event.put("unixDev",Files.getAttribute(dir,"unix:dev")); }catch(Exception e){event.put("unixDevError",error(e));}
        } catch(Exception e){event.put("observationError",error(e));}
        emit(event);
    }
    /** 分开测修改时间、访问时间、两者及可选创建时间，避免混淆属性能力。 */
    private static void times(final String label,final Path dir) throws Exception {
        for(final String mode:Arrays.asList("same","mtime","atime","both","creation")) {
            final Path p=create(dir,"times-"+mode);
            operation(label+".setTimes."+mode,false,p,null,()->{
                BasicFileAttributeView v=Files.getFileAttributeView(p,BasicFileAttributeView.class);
                if(mode.equals("same")) {
                    BasicFileAttributes current=Files.readAttributes(p,BasicFileAttributes.class);
                    v.setTimes(current.lastModifiedTime(),current.lastAccessTime(),null);
                }
                if(mode.equals("mtime"))v.setTimes(FIXED,null,null);
                if(mode.equals("atime"))v.setTimes(null,FIXED,null);
                if(mode.equals("both"))v.setTimes(FIXED,FIXED,null);
                if(mode.equals("creation"))v.setTimes(null,null,FIXED);
            });
        }
    }
    /** 只有实际unix:dev可读时才判断跨卷；未知平台保持纯观测。 */
    private static Boolean differentDevice(Path from,Path to) {
        try {
            Object a=Files.getAttribute(from,"unix:dev");Object b=Files.getAttribute(to,"unix:dev");
            if(a instanceof Number&&b instanceof Number)return ((Number)a).longValue()!=((Number)b).longValue();
        }catch(Exception ignored){ /* 不从路径名字猜设备号。 */ }
        return null;
    }
    /** 四方向独立样本；目标同卷暂存仅作对照，不删原源、不替代生产move。 */
    private static void transfers(final String label,Path from,Path to) throws Exception {
        for(final String mode:Arrays.asList("copy","copy-attributes","move","move-atomic","sibling-stage-publish")) {
            final Path source=create(from,label+"-"+mode+"-source");
            final Path target=reserve(to,label+"-"+mode+"-target");
            final Path sibling=mode.equals("sibling-stage-publish")?reserve(to,label+"-sibling-stage"):null;
            final String original=sha(source);
            Boolean expectedFailure=mode.equals("move-atomic")?differentDevice(from,to):Boolean.FALSE;
            operation(label+"."+mode,expectedFailure,source,target,()->{
                if(mode.equals("copy"))Files.copy(source,target);
                else if(mode.equals("copy-attributes"))Files.copy(source,target,StandardCopyOption.COPY_ATTRIBUTES);
                else if(mode.equals("move"))Files.move(source,target);
                else if(mode.equals("move-atomic"))Files.move(source,target,StandardCopyOption.ATOMIC_MOVE);
                else { Files.copy(source,sibling);Files.move(sibling,target,StandardCopyOption.ATOMIC_MOVE); }
                if(!original.equals(sha(target)))throw new IOException("Target content hash mismatch");
                if(mode.startsWith("move")&&Files.exists(source))throw new IOException("Move returned but original still exists");
            });
            if(sibling!=null)emit(map("event","sibling-stage-after","name",label,"stage",snapshot(sibling)));
        }
        final Path source=create(from,label+"-existing-source");
        final Path target=reserve(to,label+"-existing-target");
        Files.write(target,"preserved target".getBytes(StandardCharsets.UTF_8),StandardOpenOption.CREATE_NEW);
        operation(label+".move-existing-no-replace",true,source,target,()->Files.move(source,target));
    }
    /** 严格解析启动器窗口尺寸；只接受可表示的正整数，不能靠忽略尾参数放宽入口。 */
    private static int windowDimension(String value) {
        if(!value.matches("[1-9][0-9]*"))throw new IllegalArgumentException("Window dimension must be a positive integer");
        try { return Integer.parseInt(value); }
        catch(NumberFormatException e) { throw new IllegalArgumentException("Window dimension exceeds positive int range",e); }
    }
    /** 执行完整矩阵后给出完成证明；仅接纳真实启动器的固定窗口尾参数，不用于文件测试。 */
    public static void main(String[] args) throws Exception {
        if((args.length!=3&&args.length!=7)||!args[2].matches("[a-z0-9-]{1,48}"))
            throw new IllegalArgumentException("private-parent external-parent unique-nonce [--width positive-int --height positive-int]");
        Map<String,Object> launcherWindow=null;
        if(args.length==7) {
            if(!args[3].equals("--width")||!args[5].equals("--height"))
                throw new IllegalArgumentException("Only --width positive-int --height positive-int is accepted after the three probe arguments");
            launcherWindow=map("width",windowDimension(args[4]),"height",windowDimension(args[6]),"usedByProbe",false);
        }
        emit(map("event","begin","schema",1,"javaVersion",System.getProperty("java.version"),
            "javaHome",System.getProperty("java.home"),"tmpdir",System.getProperty("java.io.tmpdir"),"nonce",args[2],
            "launcherWindow",launcherWindow,
            "note","Expected errors are observations; completion does not assert filesystem compatibility. Hash reads can update atime."));
        final Path internal=root(args[0],args[2]);
        final Path external=root(args[1],args[2]);
        describe("private",internal);describe("external",external);
        times("private",internal);times("external",external);
        transfers("private-private",internal,internal);transfers("external-external",external,external);
        transfers("private-external",internal,external);transfers("external-private",external,internal);
        final Path absent=reserve(internal,"never-created");
        operation("setTimes-missing",true,absent,null,()->Files.setLastModifiedTime(absent,FIXED));
        boolean cleaned=false;
        if(failures==0&&!retainFixtures) {
            for(int i=owned.size()-1;i>=0;i--) { Path p=owned.get(i);if(Files.isSymbolicLink(p))throw new IOException("Unexpected symlink, preserve fixture: "+p);Files.deleteIfExists(p); }
            cleaned=true;
        }
        emit(map("event","complete","completionProof",true,"operations",operations,"unexpectedResults",failures,
            "fixturesCleaned",cleaned,"privateDirectory",internal.toString(),"externalDirectory",external.toString(),
            "scope","Filesystem observations only; no errors swallowed in production; failed fixtures preserved."));
    }
}
