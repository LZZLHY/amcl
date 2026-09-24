#ifndef AMCL_WINDOW_HOST_H
#define AMCL_WINDOW_HOST_H
#include "../glfw/amcl_native_window_lease_broker_abi.h"

#if defined(AMCL_WINDOW_HOST_STATIC)
#define AMCL_WINDOW_EXPORT
#elif defined(_WIN32)
#define AMCL_WINDOW_EXPORT __declspec(dllexport)
#else
#define AMCL_WINDOW_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AmclWindowHostSnapshot {
    void* nativeWindow;
    uint64_t generation;
    int width;
    int height;
    AmclNativeWindowPublicationState state;
} AmclWindowHostSnapshot;
typedef void (*AmclWindowHostCommitFn)(const AmclWindowHostSnapshot*, void*);

typedef struct AmclWindowHostStats {
    uint64_t generation;
    uint64_t publications;
    uint64_t acquired;
    uint64_t reused;
    uint64_t released;
    uint64_t liveLeases;
    uint64_t livePresentationToken;
    uint64_t pendingRetirements;
    uint64_t referenceFailures;
    uint64_t unreferenceFailures;
    uint64_t rejectedReleases;
    uint64_t rejectedPresentations;
    uint32_t state;
    uint32_t publicationReference;
} AmclWindowHostStats;

AMCL_WINDOW_EXPORT uint64_t amclWindowHostNextGeneration(uint64_t current);
// The optional publisher callback runs inside the exclusive publication
// transaction before the generation commit. It must not re-enter this host.
AMCL_WINDOW_EXPORT uint64_t amclWindowHostPublish(void* nativeWindow, int width, int height,
    AmclWindowHostCommitFn beforeCommit, void* context);
AMCL_WINDOW_EXPORT uint64_t amclWindowHostUpdateSize(void* expectedWindow, uint64_t expectedGeneration, int width, int height);
AMCL_WINDOW_EXPORT uint64_t amclWindowHostClear(void* expectedWindow, uint64_t expectedGeneration);
AMCL_WINDOW_EXPORT int amclWindowHostReadSnapshot(AmclWindowHostSnapshot* snapshot);
AMCL_WINDOW_EXPORT uint64_t amclWindowHostPeekGeneration(void);
AMCL_WINDOW_EXPORT AmclNativeWindowPublicationState amclWindowHostPeekState(void);
AMCL_WINDOW_EXPORT const AmclNativeWindowLeaseBrokerV2* amclWindowHostGetBroker(void);
AMCL_WINDOW_EXPORT int amclWindowHostAcquire(void* retainedWindow, uint64_t retainedGeneration, void* retainedBroker,
    void** outWindow, int* outWidth, int* outHeight, uint64_t* outGeneration, void** outBroker);
AMCL_WINDOW_EXPORT void amclWindowHostRelease(void* nativeWindow, void* broker);
AMCL_WINDOW_EXPORT int amclWindowHostBeginInputPublication(int* outWidth, int* outHeight,
    uint64_t* outGeneration, void** outBroker);
AMCL_WINDOW_EXPORT void amclWindowHostEndInputPublication(void* broker);
AMCL_WINDOW_EXPORT void amclWindowHostGetStats(AmclWindowHostStats* stats);
AMCL_WINDOW_EXPORT int amclWindowHostRetryRetiredReferences(void);

#if defined(AMCL_WINDOW_HOST_TESTING)
typedef int (*AmclWindowHostReferenceFn)(void*, void*);
AMCL_WINDOW_EXPORT int amclWindowHostSetReferenceDriver(AmclWindowHostReferenceFn reference,
    AmclWindowHostReferenceFn unreference, void* context);
AMCL_WINDOW_EXPORT void amclWindowHostTestOverridePid(uint64_t processId);
#endif

#ifdef __cplusplus
}
#endif
#endif
