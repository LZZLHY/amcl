/* AMCL 专用无窗口 SDL2 的进程/手柄更新边界，随同一 SDL2-compat 源码编译。 */
#ifdef _WIN32
static SRWLOCK amcl_update_lock = SRWLOCK_INIT;
#define AMCL_PID() ((Uint64)GetCurrentProcessId())
#define AMCL_LOCK() AcquireSRWLockExclusive(&amcl_update_lock)
#define AMCL_TRY_LOCK() TryAcquireSRWLockExclusive(&amcl_update_lock)
#define AMCL_UNLOCK() ReleaseSRWLockExclusive(&amcl_update_lock)
#else
#include <pthread.h>
#include <unistd.h>
static pthread_mutex_t amcl_update_lock = PTHREAD_MUTEX_INITIALIZER;
#define AMCL_PID() ((Uint64)getpid())
#define AMCL_LOCK() ((void)pthread_mutex_lock(&amcl_update_lock))
#define AMCL_TRY_LOCK() (pthread_mutex_trylock(&amcl_update_lock) == 0)
#define AMCL_UNLOCK() ((void)pthread_mutex_unlock(&amcl_update_lock))
#endif

/* 在实际库完成装载时发布一次，继承映像的子进程必须先拒绝，再访问 SDL TLS 或锁。 */
static Uint64 amcl_loaded_pid;
static SDL_AtomicInt amcl_worker_enabled;
static unsigned amcl_closing_depth; /* 只由通过角色校验的 owner 使用。 */

static bool AMCL_CurrentProcess(void)
{
    return amcl_loaded_pid && amcl_loaded_pid == AMCL_PID();
}

static void AMCL_RefreshGamepads(void)
{
    if (SDL3_GetAtomicInt(&amcl_worker_enabled) && AMCL_TRY_LOCK()) {
        /* 持锁后复核。另一轮正在更新或 owner 正在退出时本轮跳过，下一轮再读最新快照。 */
        if (SDL3_GetAtomicInt(&amcl_worker_enabled)) {
            SDL3_UpdateJoysticks();
        }
        AMCL_UNLOCK();
    }
}

static void AMCL_PublishJoystickState(void)
{
    if (!amcl_closing_depth) {
        SDL3_SetAtomicInt(&amcl_worker_enabled, SDL3_WasInit(SDL_INIT_JOYSTICK) != 0);
    }
}

static void AMCL_BeginShutdown(void)
{
    if (amcl_closing_depth++ == 0) {
        SDL3_SetAtomicInt(&amcl_worker_enabled, 0);
        /* 先封新读，只等先前获准的 UpdateJoysticks 离开。随后销毁时不持本锁。 */
        AMCL_LOCK();
        AMCL_UNLOCK();
    }
}

static void AMCL_EndShutdown(bool partial)
{
    --amcl_closing_depth;
    if (partial) {
        AMCL_PublishJoystickState();
    }
}
