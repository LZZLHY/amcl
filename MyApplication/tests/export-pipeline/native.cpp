/**
 * 编译实际导出数据面，宿主只在syscall边界注入短IO/错误/取消，绝不复制生产算法。
 * 独立Python zipfile另读实际输出；本测试聚焦可信fd、收敛、有界队列与结构反控。
 */
#include "../../entry/src/main/cpp/export/export_trusted_io.h"
#include "../../entry/src/main/cpp/download/hmac_sha256.h"
#include "../../entry/src/main/cpp/download/sha1.h"
#include <filesystem>
#include <fstream>
#include <functional>
#include <thread>
#include <iostream>
#include <dirent.h>
#include <cstring>
#include <fcntl.h>
#include <cstdlib>
#include <new>

#define CHECK(x) do { if (!(x)) { std::cerr << "EXPORT CHECK " << __LINE__ << ": " << #x << std::endl; std::exit(2); } } while (false)
namespace fs = std::filesystem;
using namespace amcl::exporter;
namespace {
std::atomic<int> readFault{0}, writeFault{0}, syncFault{0};
std::atomic<bool> shortIo{false};
std::atomic<size_t> readCalls{0};
std::atomic<bool> captureArrays{false}, failHashArray{false};
std::atomic<size_t> arrayNews{0}, arrayDeletes{0}, arrayBytes{0};
std::atomic<size_t> capturedArraySize{0};
std::atomic<void*> capturedArray{nullptr};
std::mutex hookMutex;
std::function<void()> readHook, writeHook;
std::string root;
unsigned sequence = 0, passed = 0;
void Hook(std::function<void()>& source) { std::function<void()> call; { std::lock_guard<std::mutex> l(hookMutex); call = std::move(source); source = {}; } if (call) call(); }
std::string Hash(const std::string& s) { download::Sha256 h; h.update(s.data(), s.size()); return h.finalizeHex(); }
std::string Hash1(const std::string& s) { download::Sha1 h; h.update(s.data(), s.size()); return h.finalizeHex(); }
std::string Data(size_t n, unsigned seed = 3) { std::string out(n, 0); for (size_t i=0;i<n;++i) out[i] = static_cast<char>((i * 71 + seed + i/31) & 255); return out; }
void Put(const fs::path& p, const std::string& s) { fs::create_directories(p.parent_path()); std::ofstream f(p, std::ios::binary | std::ios::trunc); f.write(s.data(), s.size()); CHECK(f.good()); }
std::string Get(const fs::path& p) { std::ifstream f(p, std::ios::binary); return std::string(std::istreambuf_iterator<char>(f), {}); }
size_t Fds() { DIR* d = ::opendir("/proc/self/fd"); CHECK(d); size_t n=0; while (::readdir(d)) ++n; ::closedir(d); return n; }
ArchiveSpec Spec(unsigned workers = 2) {
    ArchiveSpec s; s.filesDir = root; s.jobRelative = "game-export/work/job" + std::to_string(++sequence); s.workers=workers;
    fs::create_directories(fs::path(root)/s.jobRelative/"snapshot"); return s;
}
fs::path Snapshot(const ArchiveSpec& s) { return fs::path(root)/s.jobRelative/"snapshot"; }
fs::path Zip(const ArchiveSpec& s) { return fs::path(root)/s.jobRelative/"export.zip"; }
void Add(ArchiveSpec& s, const std::string& name, const std::string& bytes) { Put(Snapshot(s)/name, bytes); Entry e; e.path=name;e.size=bytes.size();e.sha256=Hash(bytes);s.entries.push_back(e); }
void Directory(ArchiveSpec& s, const std::string& name) { fs::create_directories(Snapshot(s)/name); Entry e;e.path=name;e.directory=true;s.entries.push_back(e); }
void Success(const Operation& op) { std::string c,m;op.error(c,m); if(op.state!=State::Succeeded) std::cerr<<c<<" "<<m<<std::endl; CHECK(op.state==State::Succeeded && op.coreFinished && !op.settled); }
void Failed(const Operation& op) { if(op.state!=State::Failed){std::string c,m;op.error(c,m);std::cerr<<"unexpected state "<<StateName(op.state)<<" "<<c<<" "<<m<<std::endl;}CHECK(op.coreFinished && op.state==State::Failed && !op.settled); }
void Test(const char* name, const std::function<void()>& call) { const size_t f=Fds();call();CHECK(Fds()==f);++passed;std::cout<<"PASS "<<name<<std::endl; }
void RejectPlan(ArchiveSpec s) { bool rejected=false;try { ValidateSpec(s); }catch(const Failure&){rejected=true;}CHECK(rejected); }
}
/** 测试专用分配端口：毒化缓冲以检出误hash未读尾部，同时观察容量和坏分配后真实关闭。 */
void* operator new[](size_t bytes) {
    const bool hashArray = captureArrays && bytes > 0 && bytes == capturedArraySize.load();
    if (hashArray && failHashArray.exchange(false)) throw std::bad_alloc();
    void* pointer = std::malloc(bytes ? bytes : 1); if (!pointer) throw std::bad_alloc();
    if (hashArray) {
        ++arrayNews; arrayBytes = bytes; capturedArray = pointer; std::memset(pointer, 0xa5, bytes);
    }
    return pointer;
}
void operator delete[](void* pointer) noexcept {
    if (pointer && pointer == capturedArray.load()) { ++arrayDeletes; capturedArray = nullptr; }
    std::free(pointer);
}
void operator delete[](void* pointer, size_t) noexcept { ::operator delete[](pointer); }
extern "C" ssize_t __real_pread(int,void*,size_t,off_t);
extern "C" ssize_t __wrap_pread(int fd,void* b,size_t n,off_t at) {
    ++readCalls;
    Hook(readHook); const int fault=readFault.exchange(0);if(fault){errno=fault;return -1;}
    return __real_pread(fd,b,shortIo?std::min<size_t>(n,397):n,at);
}
extern "C" ssize_t __real_pwrite(int,const void*,size_t,off_t);
extern "C" ssize_t __wrap_pwrite(int fd,const void* b,size_t n,off_t at) {
    Hook(writeHook);const int fault=writeFault.exchange(0);if(fault){errno=fault;return -1;}
    return __real_pwrite(fd,b,shortIo?std::min<size_t>(n,521):n,at);
}
extern "C" int __real_fsync(int);
extern "C" int __wrap_fsync(int fd) {const int fault=syncFault.exchange(0);if(fault){errno=fault;return -1;}return __real_fsync(fd);}

int main(int argc,char** argv) {
    CHECK(argc==2);root=(fs::absolute(argv[1])/"application").string();fs::create_directories(root);CHECK(amcl::ConfigureUpdateInstallFilesRoot(root));
    Test("workers 1/2/4 exact common ZIP and bounded streaming",[] {
        std::string canonical;
        for(unsigned w:{1U,2U,4U}) {
            auto s=Spec(w);Directory(s,".minecraft/assets");Add(s,".minecraft/assets/empty","");Add(s,".minecraft/版本.json",Data(8921));
            Add(s,".minecraft/assets/a",Data(1100003));Add(s,".minecraft/assets/b",Data(893733,7));
            Operation op;RunWrite(s,op);Success(op);CHECK(op.filesDone==s.entries.size() && op.bytesDone==2002657);
            CHECK(op.peakQueuedBytes<=w*2*kChunkBytes);const auto bytes=Get(Zip(s));CHECK(Hash(bytes)==op.result.sha256 && bytes.size()==op.result.size);
            if(canonical.empty())canonical=bytes;else CHECK(bytes==canonical);
            Operation verify;RunVerify(s,verify);Success(verify);CHECK(verify.archiveBytes==bytes.size() && verify.result.sha256==op.result.sha256 && verify.bytesDone==op.bytesDone);
            if(w==4) { Put(fs::path(root).parent_path()/"independent.zip",bytes); }
        }
    });
    Test("short reads writes EINTR and sync retry",[] {auto s=Spec();Add(s,"a",Data(280003));shortIo=true;readFault=EINTR;writeFault=EINTR;syncFault=EINTR;Operation op;RunWrite(s,op);shortIo=false;Success(op);Operation v;RunVerify(s,v);Success(v);});
    Test("five thousand small entries cannot exhaust sequence window",[] {auto s=Spec(4);for(unsigned i=0;i<5000;++i)Add(s,"assets/"+std::to_string(i),Data(i%201,i));Operation op;RunWrite(s,op);Success(op);CHECK(op.peakQueuedBytes<=8*kChunkBytes);Operation v;RunVerify(s,v);Success(v);});
    Test("preexisting target preserved",[] {auto s=Spec();Add(s,"a","payload");Put(Zip(s),"keep-original");Operation op;RunWrite(s,op);Failed(op);CHECK(Get(Zip(s))=="keep-original");});
    Test("wrong SHA length symlink hardlink and directory alias rejected",[] {
        for(int mode=0;mode<5;++mode){auto s=Spec();Add(s,"d/a",Data(130001));if(mode==0)s.entries[0].sha256=Hash("wrong");
            if(mode==1)s.entries[0].size++;
            if(mode==2){fs::rename(Snapshot(s)/"d/a",Snapshot(s)/"other");fs::create_symlink("../other",Snapshot(s)/"d/a");}
            if(mode==3)fs::create_hard_link(Snapshot(s)/"d/a",Snapshot(s)/"alias");
            if(mode==4){fs::rename(Snapshot(s)/"d",Snapshot(s)/"e");fs::create_directory_symlink("e",Snapshot(s)/"d");}
            Operation op;RunWrite(s,op);Failed(op);
        }
    });
    Test("same length mutation and root replacement fail before success",[] {
        auto s=Spec();Add(s,"a",Data(140001));readHook=[=]{Put(Snapshot(s)/"a",Data(140001,9));};Operation op;RunWrite(s,op);Failed(op);
        auto moved=Spec();Add(moved,"a",Data(90000));writeHook=[=]{fs::rename(Snapshot(moved),Snapshot(moved).string()+"-old");fs::create_directory(Snapshot(moved));};Operation changed;RunWrite(moved,changed);Failed(changed);
    });
    Test("IO errors fsync failure and queue cancellation settle all fds",[] {
        for(int mode=0;mode<3;++mode){auto s=Spec(4);for(unsigned i=0;i<4;++i)Add(s,"a"+std::to_string(i),Data(400003,i));
            if(mode==0)readFault=EIO;
            if(mode==1)writeFault=ENOSPC;
            if(mode==2)syncFault=EIO;
            Operation op;RunWrite(s,op);Failed(op);}
        auto s=Spec(4);for(unsigned i=0;i<8;++i)Add(s,"a"+std::to_string(i),Data(700003,i));Operation op;writeHook=[&]{op.cancel();};RunWrite(s,op);CHECK(op.coreFinished && op.state==State::Cancelled && !op.settled);
    });
    Test("concurrent cancel settles idle and backpressured workers",[] {
        auto s=Spec(4);for(unsigned i=0;i<12;++i)Add(s,"a"+std::to_string(i),Data(260003,i));
        for(unsigned i=0;i<40;++i){fs::remove(Zip(s));Operation op;std::thread writer([&]{RunWrite(s,op);});
            // 从另一个owner发布取消，不获得Pool锁；循环覆盖启动、生产与窗口等待时序。
            if(i%3)std::this_thread::sleep_for(std::chrono::microseconds(i*31));
            op.cancel();writer.join();CHECK(op.coreFinished && op.state==State::Cancelled);}
    });
    Test("independent verifier rejects local body descriptor central tail and truncation",[] {
        auto s=Spec();Add(s,"a",Data(300003));Operation op;RunWrite(s,op);Success(op);const auto original=Get(Zip(s));
        const std::vector<size_t> corrupt={4,51,51+300003,original.size()-98-75,original.size()-98,original.size()-1};
        for(size_t at:corrupt){auto bytes=original;bytes.at(at)^=1;Put(Zip(s),bytes);Operation v;RunVerify(s,v);Failed(v);}
        Put(Zip(s),original.substr(0,original.size()-1));Operation truncated;RunVerify(s,truncated);Failed(truncated);
        Put(Zip(s),original+"hidden");Operation trailing;RunVerify(s,trailing);Failed(trailing);
    });
    Test("hash preserves borrowed offset and optional SHA1",[] {
        const auto p=fs::path(root)/"hash";const auto bytes=Data(190003);Put(p,bytes);const int fd=::open(p.c_str(),O_RDONLY|O_CLOEXEC);CHECK(fd>=0 && ::lseek(fd,31,SEEK_SET)==31);
        for(bool sha:{true,false}){Operation op;RunHash(::fcntl(fd,F_DUPFD_CLOEXEC,0),bytes.size(),sha,op);Success(op);CHECK(::lseek(fd,0,SEEK_CUR)==31);CHECK(op.result.sha256==Hash(bytes) && op.result.sha1==(sha?Hash1(bytes):""));}
        CHECK(::close(fd)==0);Put(p,"");Operation empty;RunHash(::open(p.c_str(),O_RDONLY),0,true,empty);Success(empty);CHECK(empty.result.sha256==Hash(""));
    });
    Test("SHA1-only purpose keeps byte count identity cancel and empty markers",[] {
        const auto p=fs::path(root)/"hash-sha1-purpose";
        for(const auto& bytes:std::vector<std::string>{"","abc",Data(190003),std::string(1000000,'a')}){
            Put(p,bytes);const int fd=::open(p.c_str(),O_RDONLY|O_CLOEXEC);CHECK(fd>=0 && ::lseek(fd,13,SEEK_SET)==13);
            Operation op;RunHash(::fcntl(fd,F_DUPFD_CLOEXEC,0),bytes.size(),true,false,op);Success(op);
            CHECK(op.result.sha1==Hash1(bytes) && op.result.sha256.empty() && op.bytesDone==bytes.size() && op.result.size==bytes.size() && ::lseek(fd,0,SEEK_CUR)==13);
            if(bytes.empty())CHECK(op.result.sha1=="da39a3ee5e6b4b0d3255bfef95601890afd80709");
            if(bytes=="abc")CHECK(op.result.sha1=="a9993e364706816aba3e25717850c26c9cd0d89d");
            if(bytes==std::string(1000000,'a'))CHECK(op.result.sha1=="34aa973cd4c4daa4f61eeb2bdbad27316534016f");
            CHECK(::close(fd)==0);
        }
        Put(p,Data(190003));const auto before=readCalls.load();Operation invalid;
        RunHash(::open(p.c_str(),O_RDONLY),190003,false,false,invalid);Failed(invalid);CHECK(readCalls==before && invalid.bytesDone==0);
        Operation wrong;RunHash(::open(p.c_str(),O_RDONLY),190004,true,false,wrong);Failed(wrong);CHECK(readCalls==before);
        Operation cancel;readHook=[&]{cancel.cancel();};RunHash(::open(p.c_str(),O_RDONLY),190003,true,false,cancel);CHECK(cancel.coreFinished && cancel.state==State::Cancelled && cancel.result.sha1.empty() && cancel.result.sha256.empty());
    });
    Test("raw hash buffer is bounded fully filled and released on allocation IO cancel failure",[] {
        const auto p=fs::path(root)/"hash-buffer";
        for(size_t size:{0U,1U,63U,64U,65U,10085U,65535U,65536U,65537U,131087U}) {
            const auto bytes=Data(size);Put(p,bytes);arrayNews=0;arrayDeletes=0;arrayBytes=0;
            capturedArraySize=std::min(size,kChunkBytes);shortIo=true;readFault=EINTR;captureArrays=true;Operation op;
            RunHash(::open(p.c_str(),O_RDONLY),size,true,true,op);captureArrays=false;shortIo=false;
            if(size==0)readFault=0; // 空文件不发read，故障注入不能泄漏给下一子例。
            Success(op);CHECK(op.result.sha1==Hash1(bytes) && op.result.sha256==Hash(bytes) && op.bytesDone==size);
            CHECK(arrayNews==(size?1U:0U) && arrayDeletes==arrayNews && capturedArray==nullptr);
            CHECK(arrayBytes==(size?std::min(size,kChunkBytes):0U));
        }
        Put(p,Data(65537));const auto reads=readCalls.load();capturedArraySize=kChunkBytes;captureArrays=true;failHashArray=true;Operation oom;
        RunHash(::open(p.c_str(),O_RDONLY),65537,true,true,oom);captureArrays=false;Failed(oom);
        std::string code,message;oom.error(code,message);CHECK(code=="OutOfMemory" && readCalls==reads && capturedArray==nullptr);
        for(unsigned mode=0;mode<3;++mode) {
            Put(p,Data(65537));arrayNews=0;arrayDeletes=0;captureArrays=true;Operation op;
            if(mode==0)readFault=EIO;
            if(mode==1)readHook=[=]{Put(p,"");}; // EOF在ReadExact内失败，不能hash毒化/未填充区间。
            if(mode==2)readHook=[&]{op.cancel();};
            RunHash(::open(p.c_str(),O_RDONLY),65537,true,true,op);captureArrays=false;
            if(mode==2)CHECK(op.coreFinished && op.state==State::Cancelled);else Failed(op);
            CHECK(op.result.sha1.empty() && op.result.sha256.empty() && arrayNews==1 && arrayDeletes==1 && capturedArray==nullptr);
        }
    });
    Test("hash IO mutation size cancel fence and special fd reject",[] {
        const auto p=fs::path(root)/"hash-fail";const auto bytes=Data(150003);Put(p,bytes);
        Operation wrong;RunHash(::open(p.c_str(),O_RDONLY),bytes.size()+1,true,wrong);Failed(wrong);
        Operation io;readFault=EIO;RunHash(::open(p.c_str(),O_RDONLY),bytes.size(),true,io);Failed(io);
        // 明确把同长度写入的mtime推进1秒，避免宿主同一个时钟tick内写入无法产生可观测戳差。
        readHook=[=]{Put(p,Data(bytes.size(),9));fs::last_write_time(p,fs::last_write_time(p)+std::chrono::seconds(1));};Operation mutation;RunHash(::open(p.c_str(),O_RDONLY),bytes.size(),true,mutation);Failed(mutation);
        Operation cancel;cancel.cancel();RunHash(::open(p.c_str(),O_RDONLY),bytes.size(),true,cancel);CHECK(cancel.state==State::Cancelled && cancel.coreFinished);
        Operation directory;RunHash(::open(root.c_str(),O_RDONLY|O_DIRECTORY),0,true,directory);Failed(directory);
        Put(fs::path(root)/"sideload-update/install-fence.json","{}");Operation fenced;RunHash(::open(p.c_str(),O_RDONLY),bytes.size(),true,fenced);Failed(fenced);fs::remove(fs::path(root)/"sideload-update/install-fence.json");
    });
    Test("plan bounds traversal collision reserved path and ZIP safe integer",[] {
        for(const std::string p:{"../a","a/../b","/x","a\\b","NUL.txt","a.","a//b"}){auto s=Spec();Add(s,"a","");s.entries[0].path=p;RejectPlan(s);}
        auto s=Spec();Add(s,"a","");auto duplicate=s;duplicate.entries.push_back(duplicate.entries[0]);RejectPlan(duplicate);
        auto prefix=s;Entry child=prefix.entries[0];child.path="a/b";prefix.entries.push_back(child);RejectPlan(prefix);
        auto fold=s;fold.entries[0].path="Ä";fold.entries[0].foldedPath="ä";child=fold.entries[0];child.path="ä";fold.entries.push_back(child);RejectPlan(fold);
        auto over=s;over.entries[0].size=kSafeInteger;RejectPlan(over);over=s;over.workers=5;RejectPlan(over);over=s;over.jobRelative="game-export/work/a/b";RejectPlan(over);
    });
    std::cout<<"EXPORT_CORE_TOTAL "<<passed<<" PASS"<<std::endl;return 0;
}
