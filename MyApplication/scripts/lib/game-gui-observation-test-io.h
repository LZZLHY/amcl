/** GUI真实JNI宿主组合的Win32 I/O边界；只用真实文件/独占锁/匿名pipe，原退出算法来自生产State。
 * Windows目录durability映射专属barrier flush，不声称验HarmonyOS POSIX持久化。 */
class WindowsOperations final:public amcl::gameexit::Operations {
public:
    std::string root,logical,records;
    std::array<HANDLE,32> handles{};
    int handleCount=0,lock=-1;
    int keep(HANDLE value) noexcept { if(value==INVALID_HANDLE_VALUE || !value || handleCount==32)return -1;handles[handleCount]=value;return handleCount++; }
    HANDLE get(int fd) const noexcept { return fd>=0 && fd<handleCount?handles[fd]:INVALID_HANDLE_VALUE; }
    void initialize(const char* path) {
        root=path;logical="/"+root;records=root+"/game-exits";
        if(_mkdir(records.c_str())!=0){log("record_directory_failed",GetLastError());std::exit(4);}
        const auto lockPath=root+"/.game-exit.lock";
        lock=keep(CreateFileA(lockPath.c_str(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,CREATE_NEW,FILE_FLAG_WRITE_THROUGH,nullptr));
        OVERLAPPED range{};
        if(lock<0 || !LockFileEx(get(lock),LOCKFILE_EXCLUSIVE_LOCK|LOCKFILE_FAIL_IMMEDIATELY,0,1,0,&range)) { log("lock_failed",GetLastError());std::exit(4); }
    }
    int pid()const noexcept override{return static_cast<int>(GetCurrentProcessId());}
    int barrier(const char* suffix) noexcept {
        char name[4096];if(sprintf_s(name,"%s/%s",root.c_str(),suffix)<0)return -1;
        return keep(CreateFileA(name,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_FLAG_WRITE_THROUGH,nullptr));
    }
    int openAuthority(const char* filesDir,int borrowed)noexcept override {
        if(std::strcmp(filesDir,logical.c_str()) || borrowed!=lock || get(lock)==INVALID_HANDLE_VALUE)return -1;
        return barrier(".files-durability.barrier");
    }
    bool checkAuthority(int files,int borrowed)noexcept override{return borrowed==lock && get(files)!=INVALID_HANDLE_VALUE && get(lock)!=INVALID_HANDLE_VALUE;}
    int openRecordDirectory(int files)noexcept override{return get(files)==INVALID_HANDLE_VALUE?-1:barrier(".record-directory-durability.barrier");}
    int createRecord(int,const char* temporary,const char* finalName)noexcept override {
        char target[4096],finalPath[4096];
        if(sprintf_s(target,"%s/%s",records.c_str(),temporary)<0 || sprintf_s(finalPath,"%s/%s",records.c_str(),finalName)<0)return -1;
        if(GetFileAttributesA(finalPath)!=INVALID_FILE_ATTRIBUTES)return -1;
        return keep(CreateFileA(target,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_DELETE,nullptr,CREATE_NEW,FILE_FLAG_WRITE_THROUGH,nullptr));
    }
    void removeOwnedTemporary(int,const char* name)noexcept override {char path[4096];if(sprintf_s(path,"%s/%s",records.c_str(),name)>=0)DeleteFileA(path);}
    bool createAckChannel(int& reader,int& writer)noexcept override {
        HANDLE r=nullptr,w=nullptr;if(!CreatePipe(&r,&w,nullptr,0))return false;
        reader=keep(r);writer=keep(w);return reader>=0 && writer>=0;
    }
    void closeOwned(int fd)noexcept override {if(get(fd)!=INVALID_HANDLE_VALUE){CloseHandle(get(fd));handles[fd]=INVALID_HANDLE_VALUE;}}
    std::int64_t nowMs()noexcept override {
        FILETIME time{};GetSystemTimeAsFileTime(&time);ULARGE_INTEGER ticks{};ticks.LowPart=time.dwLowDateTime;ticks.HighPart=time.dwHighDateTime;
        return static_cast<std::int64_t>(ticks.QuadPart/10000-11644473600000ULL);
    }
    std::int64_t monotonicMs()noexcept override{return static_cast<std::int64_t>(GetTickCount64());}
    amcl::gameexit::IoResult writeRecord(int fd,const char* bytes,std::size_t count)noexcept override {DWORD written=0;const bool ok=WriteFile(get(fd),bytes,static_cast<DWORD>(count),&written,nullptr);return {ok?static_cast<std::int64_t>(written):-1,false};}
    amcl::gameexit::IoResult sync(int fd)noexcept override{return {FlushFileBuffers(get(fd))?0:-1,false};}
    amcl::gameexit::IoResult publish(int,const char* temporary,const char* finalName)noexcept override {
        char from[4096],to[4096];if(sprintf_s(from,"%s/%s",records.c_str(),temporary)<0 || sprintf_s(to,"%s/%s",records.c_str(),finalName)<0)return {-1,false};
        return {MoveFileExA(from,to,MOVEFILE_WRITE_THROUGH)?0:-1,false};
    }
    amcl::gameexit::IoResult sendAck(int fd)noexcept override {const char byte=0x41;return writeRecord(fd,&byte,1);}
    amcl::gameexit::IoResult pollAck(int fd,int timeout)noexcept override {
        // PeekNamedPipe实际读原ack字节，1ms只是Windows非阻塞pipe轮询适配；全部轮次共用
        // 传入剩余预算与原State绝对deadline，虚假唤醒不会增加原3000ms协议预算。
        const auto end=GetTickCount64()+static_cast<ULONGLONG>(timeout);
        do {DWORD available=0;if(!PeekNamedPipe(get(fd),nullptr,0,nullptr,&available,nullptr))return {-1,false};
            if(available){char byte=0;DWORD read=0;if(!ReadFile(get(fd),&byte,1,&read,nullptr))return {-1,false};return {read==1 && byte==0x41?1:-1,false};}
            if(GetTickCount64()>=end)return {0,false};Sleep(1);
        }while(true);
    }
};
