/* 执行真实原版/候选ZipFileSystem，真实ZIP字节走宿主文件系统；仅POSIX元数据边界由
 * 可控FileSystemProvider注入。该测试证明权限分支/原ZIP保留，不冒充宿主或OHOS挂载语义。
 */
import java.io.IOException;
import java.io.OutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.net.URI;
import java.nio.channels.SeekableByteChannel;
import java.nio.file.*;
import java.nio.file.attribute.*;
import java.nio.file.spi.FileSystemProvider;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.*;

public final class ZipfsPermissionRegression {
    static final class Scenario {
        final String name; final int original, temporary; final boolean deny, unsupported, changedKey, readDenied;
        Scenario(String n, int a, int b, boolean d, boolean u, boolean k, boolean r) {
            name=n; original=a; temporary=b; deny=d; unsupported=u; changedKey=k; readDenied=r;
        }
    }
    static Set<PosixFilePermission> permissions(int mode) {
        StringBuilder value=new StringBuilder();
        String letters="rwxrwxrwx";
        for(int index=0;index<9;++index) value.append((mode & (1 << (8-index)))!=0 ? letters.charAt(index) : '-');
        return PosixFilePermissions.fromString(value.toString());
    }
    static int bits(Set<PosixFilePermission> value) {
        String text=PosixFilePermissions.toString(value); int result=0;
        for(int index=0;index<9;++index) if(text.charAt(index)!='-') result |= 1 << (8-index);
        return result;
    }
    static void require(boolean yes,String reason) { if(!yes) throw new AssertionError(reason); }

    /** 路径仍指向真实独占测试目录；委托真实读写，只在attribute边界提供可控权限行为。 */
    static final class TestProvider extends FileSystemProvider {
        final TestFileSystem fs=new TestFileSystem(this);
        final FileSystemProvider real=FileSystems.getDefault().provider();
        final Scenario scenario;
        final Map<Path,Integer> modes=new HashMap<Path,Integer>();
        final Map<Path,Object> keys=new HashMap<Path,Object>();
        int setCalls, openChannels;
        TestProvider(Scenario s) { scenario=s; }
        TestPath wrap(Path p) { return new TestPath(fs,p); }
        Path unwrap(Path p) {
            if(!(p instanceof TestPath) || ((TestPath)p).fs!=fs) throw new ProviderMismatchException();
            return ((TestPath)p).path;
        }
        boolean temporary(Path p) { return p.getFileName().toString().startsWith("zipfstmp"); }
        int mode(Path p) { Integer value=modes.get(p.toAbsolutePath()); return value==null ? scenario.original : value; }
        Object key(Path p) {
            if(scenario.name.equals("missing-key")) return null;
            Path absolute=p.toAbsolutePath(); Object value=keys.get(absolute);
            if(value==null){value=new Object();keys.put(absolute,value);}return value;
        }
        PosixFileAttributes attributes(final Path p) throws IOException {
            final BasicFileAttributes actual=Files.readAttributes(p,BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);
            final int value=mode(p);
            return new PosixFileAttributes() {
                public FileTime lastModifiedTime(){return actual.lastModifiedTime();}
                public FileTime lastAccessTime(){return actual.lastAccessTime();}
                public FileTime creationTime(){return actual.creationTime();}
                public boolean isRegularFile(){return actual.isRegularFile();}
                public boolean isDirectory(){return actual.isDirectory();}
                public boolean isSymbolicLink(){return actual.isSymbolicLink();}
                public boolean isOther(){return actual.isOther();}
                public long size(){return actual.size();}
                public Object fileKey(){return key(p);}
                public UserPrincipal owner(){return new UserPrincipal(){public String getName(){return "fixture-owner";}};}
                public GroupPrincipal group(){return new GroupPrincipal(){public String getName(){return "fixture-group";}};}
                public Set<PosixFilePermission> permissions(){return ZipfsPermissionRegression.permissions(value);}
            };
        }
        void set(Path p,Set<PosixFilePermission> value) throws IOException {
            if(temporary(p)) {
                ++setCalls;
                if(scenario.deny) throw new AccessDeniedException(p.toString(),null,"injected-permission-denial");
            }
            modes.put(p.toAbsolutePath(),bits(value));
        }
        public String getScheme(){return "permission-fixture";}
        public FileSystem newFileSystem(URI uri,Map<String,?> env){throw new UnsupportedOperationException();}
        public FileSystem getFileSystem(URI uri){return fs;}
        public Path getPath(URI uri){return wrap(Paths.get(uri));}
        public SeekableByteChannel newByteChannel(Path path,Set<? extends OpenOption> options,FileAttribute<?>... attrs) throws IOException {
            Path p=unwrap(path); boolean existed=Files.exists(p);
            final SeekableByteChannel channel=real.newByteChannel(p,options); // 只注入元数据，不向Windows提交不存在的POSIX属性。
            if(!existed) {modes.put(p.toAbsolutePath(),temporary(p)?scenario.temporary:scenario.original);keys.put(p.toAbsolutePath(),new Object());}
            ++openChannels;
            // 直接跟踪实际底层channel生命周期，避免“旧ZIP存在”掩盖权限提前失败后的FD滞留。
            return new SeekableByteChannel() {
                boolean closed;
                public int read(java.nio.ByteBuffer b) throws IOException{return channel.read(b);}
                public int write(java.nio.ByteBuffer b) throws IOException{return channel.write(b);}
                public long position() throws IOException{return channel.position();}
                public SeekableByteChannel position(long n) throws IOException{channel.position(n);return this;}
                public long size() throws IOException{return channel.size();}
                public SeekableByteChannel truncate(long n) throws IOException{channel.truncate(n);return this;}
                public boolean isOpen(){return channel.isOpen();}
                public void close() throws IOException {
                    if(closed)return;closed=true;
                    try{channel.close();}finally{--openChannels;}
                    if(scenario.name.equals("permission-and-close-denied")&&!temporary(p))
                        throw new IOException("injected-close-error-after-real-close");
                }
            };
        }
        public DirectoryStream<Path> newDirectoryStream(Path path,final DirectoryStream.Filter<? super Path> filter) throws IOException {
            final DirectoryStream<Path> stream=Files.newDirectoryStream(unwrap(path));
            return new DirectoryStream<Path>() {
                public Iterator<Path> iterator() {
                    List<Path> result=new ArrayList<Path>();
                    try { for(Path p:stream) { Path wrapped=wrap(p); if(filter.accept(wrapped)) result.add(wrapped); } }
                    catch(IOException error){throw new DirectoryIteratorException(error);}
                    return result.iterator();
                }
                public void close() throws IOException {stream.close();}
            };
        }
        public void createDirectory(Path p,FileAttribute<?>...attrs) throws IOException {Files.createDirectory(unwrap(p));}
        public void delete(Path p) throws IOException {Path q=unwrap(p); Files.delete(q); modes.remove(q.toAbsolutePath());keys.remove(q.toAbsolutePath());}
        public void copy(Path a,Path b,CopyOption...options) throws IOException {Files.copy(unwrap(a),unwrap(b),options);}
        public void move(Path a,Path b,CopyOption...options) throws IOException {
            Path source=unwrap(a), target=unwrap(b); int value=mode(source);Object identity=key(source);
            Files.move(source,target,options); modes.remove(source.toAbsolutePath()); modes.put(target.toAbsolutePath(),value);
            keys.remove(source.toAbsolutePath());keys.put(target.toAbsolutePath(),identity);
        }
        public boolean isSameFile(Path a,Path b) throws IOException {return Files.isSameFile(unwrap(a),unwrap(b));}
        public boolean isHidden(Path p) throws IOException {return Files.isHidden(unwrap(p));}
        public FileStore getFileStore(Path p) throws IOException {return Files.getFileStore(unwrap(p));}
        public void checkAccess(Path p,AccessMode...modes) throws IOException {real.checkAccess(unwrap(p),modes);}
        @SuppressWarnings("unchecked")
        public <V extends FileAttributeView> V getFileAttributeView(Path path,Class<V> type,LinkOption...options) {
            final Path p=unwrap(path);
            if(type!=PosixFileAttributeView.class) return real.getFileAttributeView(p,type,options);
            return (V)new PosixFileAttributeView() {
                public String name(){return "posix";}
                public PosixFileAttributes readAttributes() throws IOException {return attributes(p);}
                public void setTimes(FileTime m,FileTime a,FileTime c) throws IOException {Files.getFileAttributeView(p,BasicFileAttributeView.class).setTimes(m,a,c);}
                public void setPermissions(Set<PosixFilePermission> value) throws IOException {set(p,value);}
                public UserPrincipal getOwner() throws IOException {return attributes(p).owner();}
                public void setOwner(UserPrincipal owner){throw new UnsupportedOperationException();}
                public void setGroup(GroupPrincipal group){throw new UnsupportedOperationException();}
            };
        }
        @SuppressWarnings("unchecked")
        public <A extends BasicFileAttributes> A readAttributes(Path path,Class<A> type,LinkOption...options) throws IOException {
            Path p=unwrap(path);
            if(type==BasicFileAttributes.class&&temporary(p)&&scenario.name.equals("initial-metadata-denied"))
                throw new AccessDeniedException(p.toString(),null,"injected-initial-identity-read-denial");
            if(type==PosixFileAttributes.class||type==BasicFileAttributes.class) return (A)attributes(p);
            return Files.readAttributes(p,type,options);
        }
        public Map<String,Object> readAttributes(Path path,String names,LinkOption...options) throws IOException {
            Path p=unwrap(path);
            if(!names.startsWith("unix:")) return Files.readAttributes(p,names,options);
            if(scenario.unsupported) throw new UnsupportedOperationException("unix view not available");
            if(scenario.readDenied) throw new AccessDeniedException(p.toString(),null,"injected-metadata-denial");
            Map<String,Object> result=new HashMap<String,Object>();
            result.put("mode",Integer.valueOf(0100000|mode(p)));
            Object key=key(p);
            result.put("fileKey",scenario.changedKey?new Object():key);
            return result;
        }
        @SuppressWarnings("unchecked")
        public void setAttribute(Path path,String name,Object value,LinkOption...options) throws IOException {
            if(name.equals("posix:permissions")) set(unwrap(path),(Set<PosixFilePermission>)value);
            else Files.setAttribute(unwrap(path),name,value,options);
        }
    }
    /** 包装Path只改变provider归属，所有名称解析保持宿主真正的Path实现。 */
    static final class TestPath implements Path {
        final TestFileSystem fs; final Path path;
        TestPath(TestFileSystem f,Path p){fs=f;path=p;}
        Path wrap(Path p){return p==null?null:new TestPath(fs,p);}
        Path unwrap(Path p){return p instanceof TestPath?((TestPath)p).path:p;}
        public FileSystem getFileSystem(){return fs;}
        public boolean isAbsolute(){return path.isAbsolute();}
        public Path getRoot(){return wrap(path.getRoot());}
        public Path getFileName(){return wrap(path.getFileName());}
        public Path getParent(){return wrap(path.getParent());}
        public int getNameCount(){return path.getNameCount();}
        public Path getName(int i){return wrap(path.getName(i));}
        public Path subpath(int a,int b){return wrap(path.subpath(a,b));}
        public boolean startsWith(Path p){return path.startsWith(unwrap(p));}
        public boolean startsWith(String p){return path.startsWith(p);}
        public boolean endsWith(Path p){return path.endsWith(unwrap(p));}
        public boolean endsWith(String p){return path.endsWith(p);}
        public Path normalize(){return wrap(path.normalize());}
        public Path resolve(Path p){return wrap(path.resolve(unwrap(p)));}
        public Path resolve(String p){return wrap(path.resolve(p));}
        public Path resolveSibling(Path p){return wrap(path.resolveSibling(unwrap(p)));}
        public Path resolveSibling(String p){return wrap(path.resolveSibling(p));}
        public Path relativize(Path p){return wrap(path.relativize(unwrap(p)));}
        public URI toUri(){return path.toUri();}
        public Path toAbsolutePath(){return wrap(path.toAbsolutePath());}
        public Path toRealPath(LinkOption...options) throws IOException{return wrap(path.toRealPath(options));}
        public java.io.File toFile(){return path.toFile();}
        public WatchKey register(WatchService watcher,WatchEvent.Kind<?>[] events,WatchEvent.Modifier...modifiers) throws IOException{return path.register(watcher,events,modifiers);}
        public WatchKey register(WatchService watcher,WatchEvent.Kind<?>...events) throws IOException{return path.register(watcher,events);}
        public Iterator<Path> iterator(){List<Path> result=new ArrayList<Path>();for(Path p:path)result.add(wrap(p));return result.iterator();}
        public int compareTo(Path p){return path.compareTo(unwrap(p));}
        public String toString(){return path.toString();}
        public boolean equals(Object p){return p instanceof TestPath&&((TestPath)p).fs==fs&&path.equals(((TestPath)p).path);}
        public int hashCode(){return path.hashCode();}
    }
    static final class TestFileSystem extends FileSystem {
        final TestProvider owner; TestFileSystem(TestProvider value){owner=value;}
        public FileSystemProvider provider(){return owner;}
        public void close(){}
        public boolean isOpen(){return true;}
        public boolean isReadOnly(){return false;}
        public String getSeparator(){return FileSystems.getDefault().getSeparator();}
        public Iterable<Path> getRootDirectories(){List<Path> result=new ArrayList<Path>();for(Path p:FileSystems.getDefault().getRootDirectories())result.add(owner.wrap(p));return result;}
        public Iterable<FileStore> getFileStores(){return FileSystems.getDefault().getFileStores();}
        public Set<String> supportedFileAttributeViews(){return new HashSet<String>(Arrays.asList("basic","posix","unix"));}
        public Path getPath(String first,String...more){return owner.wrap(Paths.get(first,more));}
        public PathMatcher getPathMatcher(String syntaxAndPattern){return FileSystems.getDefault().getPathMatcher(syntaxAndPattern);}
        public UserPrincipalLookupService getUserPrincipalLookupService(){return FileSystems.getDefault().getUserPrincipalLookupService();}
        public WatchService newWatchService() throws IOException{return FileSystems.getDefault().newWatchService();}
    }

    static void run(String prefix,Path base,Scenario scenario,boolean patched) throws Exception {
        Path directory=Files.createDirectory(base.resolve(scenario.name));
        Path original=directory.resolve("original.zip");
        try(OutputStream file=Files.newOutputStream(original,StandardOpenOption.CREATE_NEW); ZipOutputStream zip=new ZipOutputStream(file)) {
            zip.putNextEntry(new ZipEntry("before.txt"));zip.write(new byte[]{1,2,3});zip.closeEntry();
        }
        byte[] before=Files.readAllBytes(original);
        TestProvider provider=new TestProvider(scenario);provider.modes.put(original.toAbsolutePath(),scenario.original);
        Class<?> providerType=Class.forName(prefix+".ZipFileSystemProvider");
        Object zipProvider=providerType.getDeclaredConstructor().newInstance();
        Class<?> filesystemType=Class.forName(prefix+".ZipFileSystem");
        Constructor<?> constructor=filesystemType.getDeclaredConstructor(providerType,Path.class,Map.class);
        constructor.setAccessible(true);
        FileSystem zip=(FileSystem)constructor.newInstance(zipProvider,provider.wrap(original),Collections.emptyMap());
        Files.write(zip.getPath("/after.txt"),new byte[]{4,5,6},StandardOpenOption.CREATE_NEW);
        Throwable failure=null;
        try{zip.close();}catch(Throwable error){failure=error;}
        boolean exact=scenario.original==scenario.temporary&&(scenario.temporary&07000)==0;
        boolean initialDenied=scenario.name.equals("initial-metadata-denied");
        boolean closeDenied=scenario.name.equals("permission-and-close-denied");
        boolean noOp=patched&&exact&&!scenario.unsupported&&!scenario.changedKey&&!scenario.readDenied&&!scenario.name.equals("missing-key")&&!initialDenied;
        boolean success=noOp||!scenario.deny;
        if(patched&&(scenario.changedKey||scenario.readDenied||initialDenied))success=false;
        require((failure==null)==success,scenario.name+" unexpected close result: "+failure);
        if(success){
            require(Files.exists(original),scenario.name+" missing committed ZIP");
            try(ZipFile result=new ZipFile(original.toFile())){require(result.getEntry("before.txt")!=null&&result.getEntry("after.txt")!=null,"ZIP entries lost");}
            require(provider.mode(original)==scenario.original,"permissions changed unexpectedly");
        } else if(patched||closeDenied){
            require(Files.exists(original),scenario.name+" original deleted before failure");
            require(Arrays.equals(before,Files.readAllBytes(original)),scenario.name+" original bytes changed on error");
        } else require(!Files.exists(original),scenario.name+" historical pre-delete defect did not reproduce");
        int expectedCalls=(noOp||(patched&&(scenario.changedKey||scenario.readDenied||initialDenied))||(!patched&&closeDenied))?0:1;
        require(provider.setCalls==expectedCalls,scenario.name+" permission request count "+provider.setCalls);
        require(provider.openChannels==0,scenario.name+" leaked real source/output channels: "+provider.openChannels);
        if(patched&&closeDenied){
            require(failure instanceof AccessDeniedException,"close error replaced the original permission error");
            require(failure.getSuppressed().length==1&&failure.getSuppressed()[0].getMessage().contains("injected-close-error"),"close error not preserved as suppressed");
        }
        System.out.println((patched?"PASS ":"OLD-REPRO ")+scenario.name+" permissionCalls="+provider.setCalls+
            " originalExists="+Files.exists(original)+" success="+success+" openChannels="+provider.openChannels+
            " error="+(failure==null?"none":failure.getClass().getSimpleName()));
    }
    public static void main(String[] args) throws Exception {
        require(args.length==3,"prefix external-output patched|old");
        Path base=Files.createDirectory(Paths.get(args[1]));boolean patched=args[2].equals("patched");
        Scenario[] scenarios={
            new Scenario("same-denied",0660,0660,true,false,false,false),
            new Scenario("change-denied",0640,0660,true,false,false,false),
            new Scenario("special-denied",0660,04660,true,false,false,false),
            new Scenario("unknown-view",0660,0660,true,true,false,false),
            new Scenario("missing-key",0660,0660,true,false,false,false),
            new Scenario("identity-changed",0660,0660,true,false,true,false),
            new Scenario("metadata-denied",0660,0660,true,false,false,true),
            new Scenario("initial-metadata-denied",0660,0660,true,false,false,false),
            new Scenario("permission-and-close-denied",0640,0660,true,false,false,false),
            new Scenario("change-allowed",0640,0660,false,false,false,false),
            new Scenario("exact-allowed",0660,0660,false,false,false,false)
        };
        for(Scenario scenario:scenarios)run(args[0],base,scenario,patched);
        System.out.println("ZIPFS_PERMISSION_REGRESSION_COMPLETE mode="+(patched?"patched":"old")+" cases="+scenarios.length);
    }
}
