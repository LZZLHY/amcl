// 仅宿主fixture。线程暂停点插在实际init的最后发布前，生产补丁不含该测试hook。
static pthread_mutex_t test_mutex=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t test_condition=PTHREAD_COND_INITIALIZER;
static bool entered=false,released=false,restart_entered=false,fatal_returned=false;
#ifdef __OHOS__
static bool shutdown_done=false;
#endif
static int test_mode=0,init_result=-99,trigger_calls=0;
static int warning_count=0,unlink_calls=0,last_warning_errno=0;
static std::string test_root;
static void test_before_publish();
class AllStatic {};
class JavaThread {public:static void* current(){return NULL;}};
class ThreadBlockInVM {public:explicit ThreadBlockInVM(void*){}~ThreadBlockInVM();};
enum {AL_NOT_INITIALIZED,AL_INITIALIZING,AL_INITIALIZED};
static void sink(const char*,...){}
static void warning(const char* format,...){
  va_list args;va_start(args,format);last_warning_errno=va_arg(args,int);va_end(args);++warning_count;
}
static int test_unlink(const char* path){
  if(test_mode==3 || test_mode==4){
    ++unlink_calls;
    if(test_mode==4 || unlink_calls==1){errno=test_mode==3?EINTR:EACCES;return -1;}
  }
  return ::unlink(path);
}
#define unlink test_unlink
#define log_debug(...) sink
#define debug_only(value) do {} while(0)
#define RESTARTABLE(action,result) do {result=(action);} while(result==-1 && errno==EINTR)
#undef assert
#define CHECK(value) do {if(!(value)){fprintf(stderr,"CHECK failed line %d: %s\n",__LINE__,#value);abort();}}while(0)
#define assert(value,...) CHECK(value)
#define guarantee(value,...) CHECK(value)
namespace os {
static const char* get_temp_directory(){return test_root.c_str();}
static int current_process_id(){return getpid();}
static void naked_yield(){sched_yield();}
static void yield(){sched_yield();}
}
class AttachListener {
public:
  static void abort();
  static bool check_socket_file();
  static int transit_state(int,int){pthread_mutex_lock(&test_mutex);restart_entered=true;pthread_cond_broadcast(&test_condition);pthread_mutex_unlock(&test_mutex);return AL_INITIALIZED;}
  static bool is_init_trigger(){++trigger_calls;return true;}
#ifdef __OHOS__
  static void vm_shutdown();
#endif
};
// GENERATED_OWNER_AND_PRODUCTION_FUNCTIONS
ThreadBlockInVM::~ThreadBlockInVM(){
#ifdef __OHOS__
  CHECK(pthread_mutex_trylock(&ohos_attach_lifecycle_mutex)==0);pthread_mutex_unlock(&ohos_attach_lifecycle_mutex);
#endif
}
static void test_before_publish(){
  if(test_mode==2){AttachListener::abort();fatal_returned=true;return;}
  if(test_mode!=1)return;
  pthread_mutex_lock(&test_mutex);entered=true;pthread_cond_broadcast(&test_condition);
  while(!released)pthread_cond_wait(&test_condition,&test_mutex);
  pthread_mutex_unlock(&test_mutex);
}
static void* initialize(void*){init_result=OWNER::init();return NULL;}
#ifdef __OHOS__
static void* finish_vm(void*){AttachListener::vm_shutdown();pthread_mutex_lock(&test_mutex);shutdown_done=true;pthread_cond_broadcast(&test_condition);pthread_mutex_unlock(&test_mutex);return NULL;}
static void* restart_wait(void*){CHECK(!AttachListener::check_socket_file());return NULL;}
#endif
static bool absent(const std::string& path){struct stat value;return lstat(path.c_str(),&value)<0 && errno==ENOENT;}
int main(int argc,char**argv){
  CHECK(argc==3);test_root=argv[2];CHECK(mkdir(test_root.c_str(),0700)==0);
  const std::string mode=argv[1],path=test_root+"/.java_pid"+std::string();
  char digits[32];snprintf(digits,sizeof(digits),"%d",getpid());const std::string socket_path=path+digits;
#ifdef __OHOS__
  if(mode=="stop-before-init"){
    AttachListener::vm_shutdown();CHECK(OWNER::init()==-1 && !OWNER::has_path() && OWNER::listener()==-1);CHECK(absent(socket_path));
  }else if(mode=="init-race"){
    test_mode=1;pthread_t init_thread,finish_thread;CHECK(pthread_create(&init_thread,NULL,initialize,NULL)==0);
    pthread_mutex_lock(&test_mutex);while(!entered)pthread_cond_wait(&test_condition,&test_mutex);pthread_mutex_unlock(&test_mutex);
    CHECK(pthread_create(&finish_thread,NULL,finish_vm,NULL)==0);usleep(20000);
    pthread_mutex_lock(&test_mutex);CHECK(!shutdown_done);released=true;pthread_cond_broadcast(&test_condition);pthread_mutex_unlock(&test_mutex);
    pthread_join(init_thread,NULL);pthread_join(finish_thread,NULL);
    CHECK(init_result==0 && absent(socket_path) && fcntl(OWNER::listener(),F_GETFD)>=0 && OWNER::init()==-1);listener_cleanup();
  }else if(mode=="fatal-self"){
    test_mode=2;CHECK(OWNER::init()==0 && fatal_returned);AttachListener::vm_shutdown();CHECK(absent(socket_path));listener_cleanup();
  }else if(mode=="restart-stop"){
    CHECK(OWNER::init()==0);CHECK(unlink(socket_path.c_str())==0);pthread_t thread;CHECK(pthread_create(&thread,NULL,restart_wait,NULL)==0);
    pthread_mutex_lock(&test_mutex);while(!restart_entered)pthread_cond_wait(&test_condition,&test_mutex);pthread_mutex_unlock(&test_mutex);
    AttachListener::vm_shutdown();pthread_join(thread,NULL);CHECK(trigger_calls==0 && OWNER::init()==-1 && absent(socket_path));listener_cleanup();
  }else if(mode=="restart-live"){
    CHECK(OWNER::init()==0);ohos_attach_restart_cleanup();CHECK(OWNER::listener()==-1 && OWNER::init()==0);AttachListener::vm_shutdown();listener_cleanup();
  }else if(mode=="normal-repeated"){
    CHECK(OWNER::init()==0);int original=OWNER::listener();AttachListener::vm_shutdown();CHECK(absent(socket_path) && fcntl(original,F_GETFD)>=0);
    int sentinel=open(socket_path.c_str(),O_CREAT|O_EXCL|O_WRONLY,0600);CHECK(sentinel>=0);
    AttachListener::vm_shutdown();CHECK(!absent(socket_path) && fcntl(original,F_GETFD)>=0);
    listener_cleanup();CHECK(fcntl(original,F_GETFD)<0 && errno==EBADF);int recycled=open("/dev/null",O_RDONLY);CHECK(recycled>=0);
    listener_cleanup();CHECK(fcntl(recycled,F_GETFD)>=0 && !absent(socket_path));close(recycled);close(sentinel);CHECK(unlink(socket_path.c_str())==0);
  }else if(mode=="unlink-eintr"){
    CHECK(OWNER::init()==0);test_mode=3;AttachListener::vm_shutdown();CHECK(unlink_calls==2 && warning_count==0 && absent(socket_path));test_mode=0;listener_cleanup();
  }else if(mode=="unlink-failure"){
    CHECK(OWNER::init()==0);test_mode=4;AttachListener::vm_shutdown();CHECK(unlink_calls==1 && warning_count==1 && last_warning_errno==EACCES && !absent(socket_path));
    puts("OBSERVED normal cleanup failure errno=EACCES; file still exists; not qualified");test_mode=0;listener_cleanup();CHECK(unlink(socket_path.c_str())==0);
  }else if(mode=="quick-exit"){
    CHECK(OWNER::init()==0);AttachListener::vm_shutdown();CHECK(absent(socket_path));quick_exit(0);
  }else
#endif
  if(mode=="atexit"){
    CHECK(OWNER::init()==0);printf("%s\n",socket_path.c_str());return 0; // 由原普通atexit执行完整清理。
  }else if(mode=="legacy-quick"){
    CHECK(OWNER::init()==0);printf("%s\n",socket_path.c_str());fflush(stdout);quick_exit(0);
  }else {CHECK(false);}
  CHECK(rmdir(test_root.c_str())==0);puts("PASS real source lifecycle consumer");return 0;
}
