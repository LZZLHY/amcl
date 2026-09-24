#pragma once
#ifdef _WIN32
inline int pthread_atfork(void (*)(), void (*)(), void (*)()) { return 0; }
#else
#include_next <pthread.h>
#endif
