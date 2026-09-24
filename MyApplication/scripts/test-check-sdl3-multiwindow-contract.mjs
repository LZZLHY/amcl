#!/usr/bin/env node
// Self-test for check-sdl3-multiwindow-contract.mjs.
//
// Each contract rule has an independently-broken fixture. The assertion is not
// merely "the gate failed": it names the rule that must turn red, so deleting a
// rule or accidentally satisfying it from a comment cannot keep this test green.

import { analyzeFiles, RULE_IDS, parsePatchText } from './check-sdl3-multiwindow-contract.mjs';

let failures = 0;
function check(name, condition, detail = '') {
  if (condition) console.log(`  ok   ${name}`);
  else {
    failures += 1;
    console.error(`  FAIL ${name}${detail ? `\n       ${detail}` : ''}`);
  }
}

const CORE = `
SDL_WindowFlags SDL_GetWindowCreateFlags(SDL_PropertiesID props)
{
    SDL_WindowFlags flags = (SDL_WindowFlags)SDL_GetNumberProperty(
        props, SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER, 0);
    if (SDL_GetBooleanProperty(props, SDL_PROP_WINDOW_CREATE_HIDDEN_BOOLEAN, false)) flags |= SDL_WINDOW_HIDDEN;
    if (!SDL_GetBooleanProperty(props, SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN, true)) flags |= SDL_WINDOW_NOT_FOCUSABLE;
    if (SDL_GetBooleanProperty(props, SDL_PROP_WINDOW_CREATE_UTILITY_BOOLEAN, false)) flags |= SDL_WINDOW_UTILITY;
    if (SDL_GetBooleanProperty(props, SDL_PROP_WINDOW_CREATE_OPENGL_BOOLEAN, false)) flags |= SDL_WINDOW_OPENGL;
    if (SDL_GetBooleanProperty(props, SDL_PROP_WINDOW_CREATE_VULKAN_BOOLEAN, false)) flags |= SDL_WINDOW_VULKAN;
    return flags;
}
`;

const EGL_H = `
struct SDL_EGL_VideoData {
    bool egl_config_locked;
    EGLConfig egl_config;
};
bool SDL_EGL_LockConfig(SDL_VideoDevice *device, EGLConfig config);
`;

const EGL_C = `
bool SDL_EGL_LockConfig(SDL_VideoDevice *device, EGLConfig config)
{
    device->egl_data->egl_config = config;
    device->egl_data->egl_config_locked = true;
    return true;
}

bool SDL_EGL_ChooseConfig(SDL_VideoDevice *device)
{
    if (device->egl_data->egl_config_locked) return true;
    return ChooseBestConfig(device);
}
`;

const WINDOW_H = `
typedef enum OPENHARMONY_WindowRole {
    OPENHARMONY_WINDOW_PRESENTED,
    OPENHARMONY_WINDOW_AUXILIARY_PBUFFER
} OPENHARMONY_WindowRole;

typedef struct AmclNativeWindowLeaseBrokerV2 {
    uint32_t abiVersion;
    uint32_t structSize;
    int (*acquire)(void **window, uint64_t *generation);
    void (*release)(void *window);
    uint64_t (*peekGeneration)(void);
    uint32_t (*peekState)(void);
} AmclNativeWindowLeaseBrokerV2;

struct SDL_WindowData {
    OPENHARMONY_WindowRole role;
    EGLSurface egl_surface;
    int surface_width;
    int surface_height;
    void *native_window;
    const AmclNativeWindowLeaseBrokerV2 *native_window_lease_broker;
};

struct SDL_VideoData {
    SDL_Window *presented_window;
    unsigned auxiliary_window_count;
};

SDL_Window *OPENHARMONY_GetPresentedWindow(SDL_VideoDevice *device);
`;

const WINDOW_C = `
static const AmclNativeWindowLeaseBrokerV2 *OPENHARMONY_AMCL_GetLeaseBroker(void)
{
    const char *descriptor = SDL_getenv_unsafe("AMCL_NATIVE_WINDOW_LEASE_BROKER");
    return ParseVersionedBroker(descriptor, sizeof(AmclNativeWindowLeaseBrokerV2));
}

static bool OPENHARMONY_AMCL_AcquireNativeWindowLease(SDL_WindowData *data)
{
    data->native_window_lease_broker = OPENHARMONY_AMCL_GetLeaseBroker();
    return data->native_window_lease_broker->acquire(&data->native_window, NULL) != 0;
}

static void OPENHARMONY_AMCL_ReleaseNativeWindowLease(SDL_WindowData *data)
{
    data->native_window_lease_broker->release(data->native_window);
    data->native_window = NULL;
}

SDL_Window *OPENHARMONY_GetPresentedWindow(SDL_VideoDevice *device)
{
    return device->internal->presented_window;
}

static OPENHARMONY_WindowRole OPENHARMONY_ClassifyWindowRole(SDL_WindowFlags flags)
{
    const SDL_WindowFlags auxiliary = SDL_WINDOW_HIDDEN | SDL_WINDOW_UTILITY |
        SDL_WINDOW_NOT_FOCUSABLE | SDL_WINDOW_OPENGL;
    if ((flags & auxiliary) == auxiliary &&
        !(flags & (SDL_WINDOW_VULKAN | SDL_WINDOW_METAL | SDL_WINDOW_EXTERNAL))) {
        return OPENHARMONY_WINDOW_AUXILIARY_PBUFFER;
    }
    return OPENHARMONY_WINDOW_PRESENTED;
}

static bool OPENHARMONY_GLES_EnsureWindowConfig(SDL_VideoDevice *device)
{
    device->egl_data->egl_surfacetype = EGL_WINDOW_BIT | EGL_PBUFFER_BIT;
    if (!SDL_EGL_ChooseConfig(device)) return false;
    EGLint surfaceType = 0;
    eglGetConfigAttrib(device->egl_data->egl_display, device->egl_data->egl_config,
                       EGL_SURFACE_TYPE, &surfaceType);
    if ((surfaceType & (EGL_WINDOW_BIT | EGL_PBUFFER_BIT)) !=
        (EGL_WINDOW_BIT | EGL_PBUFFER_BIT)) return false;
    return SDL_EGL_LockConfig(device, device->egl_data->egl_config);
}

bool OPENHARMONY_CreateWindow(SDL_VideoDevice *device, SDL_Window *window,
                              SDL_PropertiesID create_props)
{
    SDL_WindowFlags requested = SDL_GetWindowCreateFlags(create_props);
    SDL_WindowData *data = SDL_calloc(1, sizeof(*data));
    data->role = OPENHARMONY_ClassifyWindowRole(requested);
    if (!OPENHARMONY_GLES_EnsureWindowConfig(device)) return false;
    if (data->role == OPENHARMONY_WINDOW_AUXILIARY_PBUFFER) {
        data->surface_width = window->w;
        data->surface_height = window->h;
        data->egl_surface = SDL_EGL_CreateOffscreenSurface(device, data->surface_width, data->surface_height);
        device->internal->auxiliary_window_count++;
    } else {
        if (device->internal->presented_window) return false;
        if (!OPENHARMONY_AMCL_AcquireNativeWindowLease(data)) return false;
        data->egl_surface = SDL_EGL_CreateSurface(device, window, data->native_window);
        device->internal->presented_window = window;
    }
    if (data->egl_surface == EGL_NO_SURFACE) return false;
    window->internal = data;
    return true;
}

void OPENHARMONY_ShowWindow(SDL_VideoDevice *device, SDL_Window *window)
{
    if (window->internal->role == OPENHARMONY_WINDOW_PRESENTED) {
        SDL_SetMouseFocus(window);
        SDL_SetKeyboardFocus(window);
    }
}

void OPENHARMONY_HideWindow(SDL_VideoDevice *device, SDL_Window *window)
{
    if (window->internal->role == OPENHARMONY_WINDOW_PRESENTED) {
        SDL_SetMouseFocus(NULL);
        SDL_SetKeyboardFocus(NULL);
    }
}

void OPENHARMONY_GetWindowSizeInPixels(SDL_VideoDevice *device, SDL_Window *window,
                                       int *width, int *height)
{
    if (window->internal->role == OPENHARMONY_WINDOW_AUXILIARY_PBUFFER) {
        *width = window->internal->surface_width;
        *height = window->internal->surface_height;
    } else if (window->internal->role == OPENHARMONY_WINDOW_PRESENTED) {
        ReadPresentedSurfaceSize(window, width, height);
    }
}

bool OPENHARMONY_GLES_SwapWindow(SDL_VideoDevice *device, SDL_Window *window)
{
    bool result = false;
    if (window->internal->role == OPENHARMONY_WINDOW_AUXILIARY_PBUFFER) {
        result = SDL_EGL_SwapBuffers(device, window->internal->egl_surface);
    } else if (window->internal->role == OPENHARMONY_WINDOW_PRESENTED) {
        result = SDL_EGL_SwapBuffers(device, window->internal->egl_surface);
        if (result) OPENHARMONY_AMCL_NotifyFramePresented();
    }
    return result;
}

void OPENHARMONY_DestroyWindow(SDL_VideoDevice *device, SDL_Window *window)
{
    SDL_WindowData *data = window->internal;
    if (!data) return;
    if (data->egl_surface != EGL_NO_SURFACE) SDL_EGL_DestroySurface(device, data->egl_surface);
    if (data->role == OPENHARMONY_WINDOW_PRESENTED) {
        device->internal->presented_window = NULL;
        OPENHARMONY_AMCL_ReleaseNativeWindowLease(data);
    } else if (data->role == OPENHARMONY_WINDOW_AUXILIARY_PBUFFER) {
        device->internal->auxiliary_window_count--;
    }
    SDL_free(data);
    window->internal = NULL;
}
`;

const VIDEO_C = `
static SDL_VideoDevice *OPENHARMONY_CreateDevice(void)
{
    SDL_VideoDevice *device = NewDevice();
    device->ShowWindow = OPENHARMONY_ShowWindow;
    device->HideWindow = OPENHARMONY_HideWindow;
    device->GetWindowSizeInPixels = OPENHARMONY_GetWindowSizeInPixels;
    return device;
}
`;

const HOST_GATE_H = `
enum class ComponentFocus { Unknown, Focused, Blurred };

constexpr bool ComputeInputForegroundGate(bool surfacePublished,
                                          uint32_t abilityForegroundMask,
                                          ComponentFocus focus)
{
    if (!surfacePublished) return false;
    if (abilityForegroundMask == 0u) return false;
    return focus != ComponentFocus::Blurred;
}

void PublishInputForegroundGateForAbility(uint32_t abilityForegroundMask,
                                          const char *reason);
`;

const HOST_XCOMPONENT = `
static void PublishInputForegroundGateLocked(const char *reason)
{
    bool value = ComputeInputForegroundGate(surfacePublished,
                                            abilityForegroundMask, focus);
    setenv("AMCL_WINDOW_FOREGROUND", value ? "1" : "0", 1);
}

static void PublishInputForegroundSurfaceState(bool published,
                                               const char *reason)
{
    surfacePublished = published;
    PublishInputForegroundGateLocked(reason);
}

static void OnSurfaceCreated(void)
{
    PublishInputForegroundSurfaceState(true, "surface-created");
}
`;

const HOST_FRAME_RATE = `
bool SetFrameRateForegroundSource(uint32_t sourceBit, bool foreground,
                                  const char *reason)
{
    uint32_t foregroundMask = WithFrameRateForegroundSource(
        sourceBit, foreground);
    PublishInputForegroundGateForAbility(foregroundMask, reason);
    return true;
}
`;

const HOST_TYPED_INPUT_H = `
#define AMCL_BACKEND_INPUT_EVENT_FOCUS 5u
#define AMCL_BACKEND_INPUT_EVENT_CAPTURE 6u
#define AMCL_BACKEND_INPUT_EVENT_RELATIVE 7u
#define AMCL_BACKEND_INPUT_EVENT_DEVICE 8u
#define AMCL_BACKEND_INPUT_EVENT_SURFACE_CONTEXT 9u
#define AMCL_BACKEND_INPUT_RELATIVE_FLAG_HARDWARE_RAW (1u << 0)
`;

const HOST_TYPED_INPUT_C = `
static void FocusSink(void *context, const FocusEvent& event) { Enqueue(context, event); }
static void CaptureSink(void *context, const CaptureEvent& event) { Enqueue(context, event); }
static void RelativeSink(void *context, const RelativeEvent& event)
{
    AmclBackendInputEvent out = BlankEvent(AMCL_BACKEND_INPUT_EVENT_RELATIVE);
    out.wheelX = event.dx;
    out.wheelY = event.dy;
    Enqueue(context, out);
}
static void DeviceSink(void *context, const DeviceEvent& event)
{
    out.resetReason = event.deviceClass;
    Enqueue(context, out);
}
static void SurfaceContextSink(void *context, const SurfaceContextEvent& event)
{
    Enqueue(context, EncodeBackendSurfaceContext(event));
}
static GlfwInputSink SinkFor(void *channel)
{
    GlfwInputSink sink;
    sink.relative = RelativeSink;
    sink.focus = FocusSink;
    sink.capture = CaptureSink;
    sink.device = DeviceSink;
    sink.surfaceContext = SurfaceContextSink;
    return sink;
}
`;

const HOST_POINTER_ADAPTER = `
static void ProcessDevice(const Event& event, Emissions& emissions)
{
    switch (event.header.eventType) {
    case AMCL_INPUT_EVENT_DEVICE_CHANGED:
        ClearDeviceLocked(event.header.deviceId, event.header.deviceClass);
        emissions.emplace_back(GlfwDeviceSinkEvent{event.header.deviceId});
        break;
    }
}
`;

const SDL_TYPED_INPUT = `
#define AMCL_BACKEND_EVENT_FOCUS 5u
#define AMCL_BACKEND_EVENT_CAPTURE 6u
#define AMCL_BACKEND_EVENT_RELATIVE 7u
#define AMCL_BACKEND_EVENT_DEVICE 8u
#define AMCL_BACKEND_EVENT_SURFACE_CONTEXT 9u
#define AMCL_BACKEND_RELATIVE_FLAG_HARDWARE_RAW (1u << 0)
#define AMCL_BACKEND_RELATIVE_FLAG_MASK AMCL_BACKEND_RELATIVE_FLAG_HARDWARE_RAW
#define AMCL_CAPTURE_REASON_NONE 0u
#define AMCL_CAPTURE_REASON_GRANTED 1u
#define AMCL_DEVICE_CLASS_MOUSE 1u
#define AMCL_DEVICE_CLASS_TOUCHPAD 2u
#define AMCL_SURFACE_CONTEXT_FIELD_WINDOW (1u << 0)
#define AMCL_SURFACE_CONTEXT_FIELD_DISPLAY (1u << 1)
#define AMCL_SURFACE_CONTEXT_FIELD_RECT (1u << 2)
#define AMCL_SURFACE_CONTEXT_FIELD_DENSITY (1u << 3)
#define AMCL_SURFACE_CONTEXT_FIELD_TRANSFORM (1u << 4)
#define AMCL_SURFACE_CONTEXT_FIELD_REFRESH_RATE (1u << 5)
#define AMCL_SURFACE_CONTEXT_FIELD_ALL 0x3fu
#define AMCL_RELATIVE_DISABLE_NONE 0u
#define AMCL_RELATIVE_DISABLE_FOCUS_LOST 1u
#define AMCL_RELATIVE_DISABLE_CAPTURE_LOST 2u
static bool host_capture_requested;
static bool host_capture_active;
static bool host_baseline_valid;
static bool host_presented_active;
static Uint32 host_relative_disable_authority;
static Uint64 host_surface_context_generation;
static Uint64 host_unclassified_relative_release_count;

static SDL_MouseID OPENHARMONY_MouseIDFromHost(Uint64 deviceId)
{
    return deviceId == 0 ? 1 : (SDL_MouseID)(deviceId + 1u);
}

static bool OPENHARMONY_ValidateTypedEvent(const Event *event)
{
    switch (event->eventType) {
    case AMCL_BACKEND_EVENT_FOCUS: return event->action <= 1u;
    case AMCL_BACKEND_EVENT_CAPTURE:
        return event->code >= 0 && event->code <= 1 &&
            (event->action == 0u ||
             event->resetReason == AMCL_CAPTURE_REASON_GRANTED) &&
            (event->action != 0u ||
             event->resetReason != AMCL_CAPTURE_REASON_GRANTED);
    case AMCL_BACKEND_EVENT_RELATIVE:
        return !isnan(event->wheelX) && !isinf(event->wheelX) &&
            (event->modifiers & ~AMCL_BACKEND_RELATIVE_FLAG_MASK) == 0u;
    case AMCL_BACKEND_EVENT_SURFACE_CONTEXT: {
        Uint32 valid_fields = (Uint32)(event->monotonicTimeNs & 0xffffffffu);
        Uint32 transform = (Uint32)(event->monotonicTimeNs >> 32u);
        if (event->deviceId == 0u ||
            (valid_fields & ~AMCL_SURFACE_CONTEXT_FIELD_ALL) != 0u) return false;
        if ((valid_fields & AMCL_SURFACE_CONTEXT_FIELD_WINDOW) != 0u &&
            event->code <= 0) return false;
        if ((valid_fields & AMCL_SURFACE_CONTEXT_FIELD_DISPLAY) != 0u &&
            event->rawCode < 0) return false;
        if ((valid_fields & AMCL_SURFACE_CONTEXT_FIELD_RECT) != 0u &&
            (event->lockState == 0u || event->resetReason == 0u)) return false;
        if ((valid_fields & AMCL_SURFACE_CONTEXT_FIELD_DENSITY) != 0u &&
            (isnan(event->wheelX) || isinf(event->wheelX) || event->wheelX <= 0.0f)) return false;
        if ((valid_fields & AMCL_SURFACE_CONTEXT_FIELD_TRANSFORM) != 0u &&
            transform > 3u) return false;
        if ((valid_fields & AMCL_SURFACE_CONTEXT_FIELD_REFRESH_RATE) != 0u &&
            (isnan(event->wheelY) || isinf(event->wheelY) ||
             event->wheelY <= 0.0f || event->wheelY > 1000.0f)) return false;
        break;
    }
    default: return true;
    }
    return true;
}

static void OPENHARMONY_DisableRelativeModeForHostLoss(Uint32 authority)
{
    host_relative_disable_authority = authority;
    bool disabled = SDL_SetRelativeMouseMode(false);
    host_relative_disable_authority = AMCL_RELATIVE_DISABLE_NONE;
}

static bool OPENHARMONY_ApplyTypedFocus(SDL_WindowID id, bool focused)
{
    SDL_Window *window = SDL_GetWindowFromID(id);
    if (focused) {
        SDL_SetKeyboardFocus(window);
        SDL_SetMouseFocus(window);
    } else {
        host_relative_disable_authority = AMCL_RELATIVE_DISABLE_FOCUS_LOST;
        SDL_SetKeyboardFocus(NULL);
        host_relative_disable_authority = AMCL_RELATIVE_DISABLE_NONE;
        SDL_SetMouseFocus(NULL);
    }
    return true;
}

static void OPENHARMONY_ApplyTypedCapture(const Event *event)
{
    host_capture_requested = event->code != 0;
    host_capture_active = event->action != 0u;
    if (!host_capture_requested ||
        (!host_capture_active && event->resetReason != AMCL_CAPTURE_REASON_NONE)) {
        OPENHARMONY_DisableRelativeModeForHostLoss(
            AMCL_RELATIVE_DISABLE_CAPTURE_LOST);
        return;
    }
    SDL_Window *input_window = OPENHARMONY_AMCL_GetInputWindow();
    Bridge *bridge = OPENHARMONY_GetHostBridge();
    if (host_capture_requested && host_capture_active &&
        event->resetReason == AMCL_CAPTURE_REASON_GRANTED &&
        host_presented_active && input_window && bridge &&
        bridge->IsGrabbing && bridge->IsGrabbing() &&
        SDL_GetKeyboardFocus() == input_window &&
        (input_window->flags & SDL_WINDOW_MOUSE_RELATIVE_MODE) != 0 &&
        !SDL_GetRelativeMouseMode() &&
        !SDL_SetRelativeMouseMode(true)) {
        SDL_LogWarn("restore failed");
    }
}

static bool OPENHARMONY_SetRelativeMouseMode(bool enabled)
{
    Uint32 disable_authority = host_relative_disable_authority;
    if (!enabled) {
        host_relative_disable_authority = AMCL_RELATIVE_DISABLE_NONE;
    }
    bool driver_teardown = SDL_GetVideoDevice()->is_quitting;
    bool message_box = SDL_GetMessageBoxCount() > 0;
    Bridge *bridge = OPENHARMONY_GetHostBridge();
    SDL_Window *input_window = OPENHARMONY_AMCL_GetInputWindow();
    if (!enabled && disable_authority != AMCL_RELATIVE_DISABLE_NONE) {
        host_capture_active = false;
        host_baseline_valid = false;
        return true;
    }
    if (!enabled && driver_teardown) {
        host_capture_requested = false;
        host_capture_active = false;
        host_baseline_valid = false;
        if (bridge && bridge->SetGrabState) {
            bridge->SetGrabState(0);
        }
        return true;
    }
    if (!host_presented_active || !input_window) return false;
    if (!bridge || !bridge->SetGrabState || !bridge->IsGrabbing) return false;
    if (!enabled &&
        (input_window->flags & SDL_WINDOW_MOUSE_RELATIVE_MODE) != 0 &&
        !message_box) {
        ++host_unclassified_relative_release_count;
        return SDL_SetError("relative release lacks authority");
    }
    if (!enabled) {
        host_capture_requested = false;
        host_capture_active = false;
        bridge->SetGrabState(0);
    } else {
        host_capture_requested = true;
        if (!bridge->IsGrabbing()) {
            host_capture_active = false;
            bridge->SetGrabState(1);
        }
    }
    host_baseline_valid = false;
    return true;
}

static void OPENHARMONY_AMCL_UpdatePresentedForeground(void)
{
    SDL_Window *window = OPENHARMONY_AMCL_GetInputWindow();
    if (window && window->internal &&
        (window->flags & SDL_WINDOW_MOUSE_RELATIVE_MODE) == 0) {
        Bridge *bridge = OPENHARMONY_GetHostBridge();
        if (bridge && bridge->SetGrabState && bridge->IsGrabbing &&
            bridge->IsGrabbing()) {
            host_capture_requested = false;
            host_capture_active = false;
            host_baseline_valid = false;
            bridge->SetGrabState(0);
        }
    }
}

static Uint64 host_grabbed_motion_delivered;
static Uint64 host_grabbed_motion_suppressed;
static bool host_typed_relative_seen;

static bool OPENHARMONY_TypedRelativeCaptureGranted(void)
{
    return host_capture_requested && host_capture_active;
}

static bool OPENHARMONY_TypedRelativeOwnsGrabbedMotion(bool typed_relative_owner)
{
    return typed_relative_owner && OPENHARMONY_TypedRelativeCaptureGranted() &&
           host_typed_relative_seen;
}

static void OPENHARMONY_PumpHostCursor(Bridge *bridge, bool typed_relative_owner)
{
    bool grabbing = bridge->IsGrabbing();
    if (grabbing != host_last_grabbing) {
        host_last_grabbing = grabbing;
        host_baseline_valid = false;
        host_typed_relative_seen = false;
    }
    if (grabbing && OPENHARMONY_TypedRelativeOwnsGrabbedMotion(typed_relative_owner)) {
        ++host_grabbed_motion_suppressed;
        return;
    }
    if (grabbing) {
        ++host_grabbed_motion_delivered;
        SDL_SendMouseMotion(0, window, 0, true, dx, dy);
        return;
    }
    SDL_SendMouseMotion(0, window, 0, false, x, y);
}

static void OPENHARMONY_ReleaseHeldMouseButtons(bool teardown, int window_id)
{
    typedef struct {
        SDL_MouseID mouse_id;
        SDL_MouseButtonFlags held;
    } OPENHARMONY_HeldMouseSource;
    OPENHARMONY_HeldMouseSource *held_sources = SDL_malloc(2 * sizeof(*held_sources));
    for (int source_index = 0; source_index < 2; ++source_index) {
        held_sources[source_index].mouse_id = mouse->sources[source_index].mouseID;
        held_sources[source_index].held = mouse->sources[source_index].buttonstate;
        SDL_SendMouseButton(0, window, held_sources[source_index].mouse_id, 1, false);
    }
    if (window_lost) {
        for (int live_index = 0; live_index < mouse->num_sources; ++live_index) {
            mouse->sources[live_index].buttonstate = 0;
        }
    }
    SDL_free(held_sources);
}

static void OPENHARMONY_PumpTypedEvents(Bridge *bridge)
{
    Event event;
    switch (event.eventType) {
    case AMCL_BACKEND_EVENT_RESET:
        SDL_ResetKeyboard();
        host_baseline_valid = false;
        break;
    case AMCL_BACKEND_EVENT_BUTTON:
        SDL_SendMouseButton(0, window,
                            OPENHARMONY_MouseIDFromHost(event.deviceId), 1, true);
        break;
    case AMCL_BACKEND_EVENT_WHEEL:
        SDL_SendMouseWheel(0, window,
                           OPENHARMONY_MouseIDFromHost(event.deviceId), 0, 1, 0);
        break;
    case AMCL_BACKEND_EVENT_FOCUS:
        OPENHARMONY_ApplyTypedFocus(window_id, event.action != 0u);
        break;
    case AMCL_BACKEND_EVENT_CAPTURE:
        OPENHARMONY_ApplyTypedCapture(&event);
        break;
    case AMCL_BACKEND_EVENT_RELATIVE:
        if (OPENHARMONY_TypedRelativeCaptureGranted() && SDL_GetRelativeMouseMode()) {
            if (!host_typed_relative_seen) {
                host_typed_relative_seen = true;
                host_baseline_valid = false;
            }
            SDL_SendMouseMotion(event.monotonicTimeNs, window,
                                OPENHARMONY_MouseIDFromHost(event.deviceId), true,
                                event.wheelX, event.wheelY);
        }
        break;
    case AMCL_BACKEND_EVENT_DEVICE:
        if (event.code == 1) {
            SDL_AddMouse(OPENHARMONY_MouseIDFromHost(event.deviceId),
                         event.resetReason == AMCL_DEVICE_CLASS_TOUCHPAD
                             ? "Touchpad" : "Mouse");
        } else {
            SDL_RemoveMouse(OPENHARMONY_MouseIDFromHost(event.deviceId));
        }
        break;
    case AMCL_BACKEND_EVENT_SURFACE_CONTEXT:
        if (event.deviceId > host_surface_context_generation) {
            host_surface_context_generation = event.deviceId;
        }
        break;
    }
}

static void OPENHARMONY_AMCL_PumpEvents(void)
{
    bool typed_relative_owner = GetTypedNext(bridge) != NULL;
    OPENHARMONY_PumpHostCursor(bridge, typed_relative_owner);
    OPENHARMONY_PumpTypedEvents(bridge);
}

static void OPENHARMONY_AMCL_SetPresentedActive(bool active)
{
    if (!active) {
        OPENHARMONY_PumpTypedEvents(bridge);
        typed_set_active(AMCL_BACKEND_ID_SDL3, 0);
    }
}

static void OPENHARMONY_AMCL_QuitMouse(void)
{
    OPENHARMONY_AMCL_SetPresentedActive(false);
    Bridge *bridge = OPENHARMONY_GetHostBridge();
    if (bridge && bridge->SetGrabState) {
        bridge->SetGrabState(0);
    }
    host_capture_requested = false;
    host_capture_active = false;
    host_relative_disable_authority = AMCL_RELATIVE_DISABLE_NONE;
    host_baseline_valid = false;
}
`;

function greenFixture() {
  return new Map([
    ['src/video/SDL_video.c', CORE],
    ['src/video/SDL_egl_c.h', EGL_H],
    ['src/video/SDL_egl.c', EGL_C],
    ['src/video/openharmony/SDL_openharmonywindow.h', WINDOW_H],
    ['src/video/openharmony/SDL_openharmonywindow.c', WINDOW_C],
    ['src/video/openharmony/SDL_openharmonyvideo.c', VIDEO_C],
    ['src/video/openharmony/SDL_openharmonyamcl.c', SDL_TYPED_INPUT],
    ['entry/src/main/cpp/platform/input_foreground_gate.h', HOST_GATE_H],
    ['entry/src/main/cpp/platform/xcomponent.cpp', HOST_XCOMPONENT],
    ['entry/src/main/cpp/platform/ohos_frame_rate_hint.cpp', HOST_FRAME_RATE],
    ['entry/src/main/cpp/input/adapters/backend_input_bridge.h', HOST_TYPED_INPUT_H],
    ['entry/src/main/cpp/input/adapters/backend_input_bridge.cpp', HOST_TYPED_INPUT_C],
    ['entry/src/main/cpp/input/adapters/glfw_input_adapter.cpp', HOST_POINTER_ADAPTER],
  ]);
}

function mutate(rel, replace, replacement) {
  const fixture = greenFixture();
  const before = fixture.get(rel);
  if (!before.includes(replace)) throw new Error(`mutation anchor missing in ${rel}: ${replace}`);
  fixture.set(rel, before.replace(replace, replacement));
  return fixture;
}

function mutateAll(replace, replacement) {
  const fixture = greenFixture();
  let hits = 0;
  for (const [rel, before] of fixture) {
    if (!before.includes(replace)) continue;
    hits += before.split(replace).length - 1;
    fixture.set(rel, before.replaceAll(replace, replacement));
  }
  if (hits === 0) throw new Error(`global mutation anchor missing: ${replace}`);
  return fixture;
}

function failedIds(report) {
  return report.results.filter((r) => !r.ok).map((r) => r.id);
}

const green = analyzeFiles(greenFixture());
check('green source fixture passes every rule', green.ok,
  `failed=${green.results.filter((r) => !r.ok)
    .map((r) => `${r.id}[${r.evidence ?? r.detail}]`).join(', ')}`);
check('rule inventory is stable and unique',
  green.results.length === RULE_IDS.length
    && new Set(green.results.map((r) => r.id)).size === RULE_IDS.length
    && RULE_IDS.every((id) => green.results.some((r) => r.id === id)));

// Runtime truth table paired with the source predicate checked by
// typed-focus-capture. Pending is the one easily-regressed row: treating every
// inactive publication as loss would immediately cancel a just-requested mode.
const captureUnwindsRelative = (requested, active, reason) =>
  !requested || (!active && reason !== 0);
check('capture pending keeps SDL relative request alive',
  !captureUnwindsRelative(true, false, 0));
check('capture grant keeps SDL relative request alive',
  !captureUnwindsRelative(true, true, 1));
check('capture real loss exits SDL relative mode',
  captureUnwindsRelative(true, false, 3));
check('capture explicit release exits SDL relative mode',
  captureUnwindsRelative(false, false, 0));

// Runtime truth table paired with relative-disable-authority. SDL's active
// relative bit is derived state; the per-window request bit distinguishes an
// application release (already cleared) from an unclassified internal release.
const RELATIVE_DISABLE_NONE = 0;
const RELATIVE_DISABLE_FOCUS = 1;
const RELATIVE_DISABLE_CAPTURE = 2;
const relativeDisableDecision = ({
  enabled,
  windowRequested,
  authority = RELATIVE_DISABLE_NONE,
  driverTeardown = false,
  messageBox = false,
  bridgeGrabbing = false,
}) => {
  if (enabled && bridgeGrabbing) {
    return { result: true, bridgeWrite: null, nextAuthority: authority };
  }
  if (enabled) return { result: true, bridgeWrite: 1, nextAuthority: authority };
  const nextAuthority = RELATIVE_DISABLE_NONE;
  if (windowRequested && !driverTeardown && !messageBox) {
    if (authority !== RELATIVE_DISABLE_NONE) {
      return { result: true, bridgeWrite: null, nextAuthority };
    }
    return { result: false, bridgeWrite: null, nextAuthority };
  }
  return { result: true, bridgeWrite: 0, nextAuthority };
};

const internalRelease = relativeDisableDecision({
  enabled: false, windowRequested: true,
});
check('unclassified internal relative=false is rejected without clearing host grab',
  !internalRelease.result && internalRelease.bridgeWrite === null);

const appRelease = relativeDisableDecision({
  enabled: false, windowRequested: false,
});
check('application relative=false clears host grab after its request flag is cleared',
  appRelease.result && appRelease.bridgeWrite === 0);

for (const authority of [RELATIVE_DISABLE_FOCUS, RELATIVE_DISABLE_CAPTURE]) {
  const hostLoss = relativeDisableDecision({
    enabled: false, windowRequested: true, authority,
  });
  const repeated = relativeDisableDecision({
    enabled: false, windowRequested: true,
    authority: hostLoss.nextAuthority,
  });
  check(`host authority ${authority} suspends SDL once without writing bridge grab`,
    hostLoss.result && hostLoss.bridgeWrite === null
      && hostLoss.nextAuthority === RELATIVE_DISABLE_NONE);
  check(`host authority ${authority} is one-shot`,
    !repeated.result && repeated.bridgeWrite === null);
}

for (const boundary of [
  { driverTeardown: true, name: 'driver teardown' },
  { messageBox: true, name: 'message box' },
]) {
  const allowed = relativeDisableDecision({
    enabled: false, windowRequested: true,
    driverTeardown: boundary.driverTeardown ?? false,
    messageBox: boundary.messageBox ?? false,
  });
  check(`${boundary.name} may explicitly clear host grab`,
    allowed.result && allowed.bridgeWrite === 0);
}

const resetState = {
  relative: true, hostGrabbed: true, captureRequested: true, captureActive: true,
};
const afterReset = { ...resetState, heldKeys: 0, heldButtons: 0 };
check('RESET clears held state but does not exit relative or revoke capture authority',
  afterReset.relative && afterReset.hostGrabbed
    && afterReset.captureRequested && afterReset.captureActive);

const reconcileRelativeState = (input) => {
  const state = { ...input, bridgeWrites: [...(input.bridgeWrites ?? [])] };
  const clearBestEffort = () => {
    if (state.bridgeAvailable && state.bridgeGrabbing) {
      state.bridgeWrites.push(0);
      state.bridgeGrabbing = false;
    }
    state.captureRequested = false;
    state.captureActive = false;
  };
  if (!state.liveWindow) {
    clearBestEffort();
    return state;
  }
  if (!state.windowRequested && state.bridgeGrabbing) {
    state.bridgeWrites.push(0);
    state.bridgeGrabbing = false;
    state.captureRequested = false;
    state.captureActive = false;
    return state;
  }
  if (state.windowRequested && state.captureRequested && state.captureActive &&
      state.presented && state.keyboardFocused && !state.globalRelative) {
    const enable = relativeDisableDecision({
      enabled: true,
      windowRequested: true,
      bridgeGrabbing: state.bridgeGrabbing,
    });
    if (enable.result) {
      state.globalRelative = true;
      if (enable.bridgeWrite !== null) {
        state.bridgeWrites.push(enable.bridgeWrite);
        state.bridgeGrabbing = true;
        state.captureActive = false;
      }
      // When bridge grab already represented W=1, the enable hook must retain
      // the CAPTURE GRANTED fact consumed immediately before reconciliation.
      state.captureRequested = true;
    }
  }
  return state;
};

const staleGrab = {
  liveWindow: true, windowRequested: false,
  bridgeAvailable: true, bridgeGrabbing: true,
  captureRequested: true, captureActive: true,
  presented: true, keyboardFocused: true, globalRelative: false,
  bridgeWrites: [],
};
const staleCleared = reconcileRelativeState(staleGrab);
const staleSecondTick = reconcileRelativeState(staleCleared);
check('current-state W=0 clears stale bridge grab and capture exactly once',
  JSON.stringify(staleCleared.bridgeWrites) === JSON.stringify([0])
    && !staleCleared.bridgeGrabbing
    && !staleCleared.captureRequested && !staleCleared.captureActive
    && JSON.stringify(staleSecondTick.bridgeWrites) === JSON.stringify([0]));

const grantedSuspension = {
  liveWindow: true, windowRequested: true,
  bridgeAvailable: true, bridgeGrabbing: true,
  captureRequested: true, captureActive: true,
  presented: true, keyboardFocused: true, globalRelative: false,
  bridgeWrites: [],
};
const reactivated = reconcileRelativeState(grantedSuspension);
check('granted W=1 suspension re-enables SDL relative without duplicate bridge=1',
  reactivated.globalRelative && reactivated.bridgeGrabbing
    && reactivated.captureRequested && reactivated.captureActive
    && reactivated.bridgeWrites.length === 0);

for (const [name, mutation] of [
  ['capture pending', { captureActive: false }],
  ['not presented', { presented: false }],
  ['keyboard focus absent', { keyboardFocused: false }],
]) {
  const blocked = reconcileRelativeState({ ...grantedSuspension, ...mutation });
  check(`${name} cannot reactivate SDL relative`,
    !blocked.globalRelative && blocked.bridgeWrites.length === 0);
}

const hostSuspended = relativeDisableDecision({
  enabled: false,
  windowRequested: true,
  bridgeGrabbing: true,
  authority: RELATIVE_DISABLE_CAPTURE,
});
check('host authority disables SDL global relative but preserves bridge W=1',
  hostSuspended.result && hostSuspended.bridgeWrite === null);

const nullWindowCleanup = reconcileRelativeState({
  ...grantedSuspension,
  liveWindow: false,
});
check('window-null cleanup best-effort clears bridge and capture',
  JSON.stringify(nullWindowCleanup.bridgeWrites) === JSON.stringify([0])
    && !nullWindowCleanup.bridgeGrabbing
    && !nullWindowCleanup.captureRequested && !nullWindowCleanup.captureActive);

const unavailableBridgeCleanup = reconcileRelativeState({
  ...grantedSuspension,
  liveWindow: false,
  bridgeAvailable: false,
});
check('window-null cleanup clears local capture even without a callable bridge',
  unavailableBridgeCleanup.bridgeWrites.length === 0
    && !unavailableBridgeCleanup.captureRequested
    && !unavailableBridgeCleanup.captureActive);

// Runtime truth table for the event-type-9 validator. A zero-field publication
// is a valid authoritative invalidation; only fields named by validFields are
// interpreted, so negative left/top bit patterns remain legal.
const SURFACE_WINDOW = 1 << 0;
const SURFACE_DISPLAY = 1 << 1;
const SURFACE_RECT = 1 << 2;
const SURFACE_DENSITY = 1 << 3;
const SURFACE_TRANSFORM = 1 << 4;
const SURFACE_REFRESH = 1 << 5;
const SURFACE_ALL = 0x3f;
const validSurfaceContext = (event) => {
  const fields = event.validFields >>> 0;
  if (event.generation === 0 || (fields & ~SURFACE_ALL) !== 0) return false;
  if ((fields & SURFACE_WINDOW) !== 0 && event.windowId <= 0) return false;
  if ((fields & SURFACE_DISPLAY) !== 0 && event.displayId < 0) return false;
  if ((fields & SURFACE_RECT) !== 0 &&
      (event.width === 0 || event.height === 0)) return false;
  if ((fields & SURFACE_DENSITY) !== 0 &&
      (!Number.isFinite(event.density) || event.density <= 0)) return false;
  if ((fields & SURFACE_TRANSFORM) !== 0 && event.transform > 3) return false;
  if ((fields & SURFACE_REFRESH) !== 0 &&
      (!Number.isFinite(event.refresh) || event.refresh <= 0 || event.refresh > 1000)) return false;
  return true;
};
const surface = (overrides = {}) => ({
  generation: 41, validFields: SURFACE_ALL,
  windowId: 12, displayId: 3,
  leftBits: (-120) >>> 0, topBits: 44 >>> 0,
  width: 1600, height: 900,
  density: 2.25, refresh: 144, transform: 2,
  ...overrides,
});
check('full surface context accepts signed left/top bit patterns',
  validSurfaceContext(surface()) && (surface().leftBits | 0) === -120);
check('zero-field surface invalidation remains valid',
  validSurfaceContext(surface({
    validFields: 0, windowId: 0, displayId: -1,
    width: 0, height: 0, density: 0, refresh: 0, transform: 99,
  })));
check('partial surface context validates only fields named by its mask',
  validSurfaceContext(surface({
    validFields: SURFACE_DENSITY, windowId: 0, displayId: -1,
    width: 0, height: 0, refresh: Number.NaN, transform: 99,
  })));

const invalidSurfaceContexts = [
  ['generation', { generation: 0 }],
  ['unknown field', { validFields: SURFACE_ALL | (1 << 8) }],
  ['window id', { windowId: 0 }],
  ['display id', { displayId: -1 }],
  ['rect width', { width: 0 }],
  ['rect height', { height: 0 }],
  ['density zero', { density: 0 }],
  ['density NaN', { density: Number.NaN }],
  ['density infinity', { density: Number.POSITIVE_INFINITY }],
  ['transform', { transform: 4 }],
  ['refresh zero', { refresh: 0 }],
  ['refresh infinity', { refresh: Number.POSITIVE_INFINITY }],
  ['refresh upper bound', { refresh: 1001 }],
];
for (const [name, mutation] of invalidSurfaceContexts) {
  check(`surface context rejects ${name}`, !validSurfaceContext(surface(mutation)));
}

const consumeTypedSequence = (events) => {
  let malformed = 0;
  let inputEvents = 0;
  let generation = 0;
  for (const event of events) {
    if (event.type === 9) {
      if (!validSurfaceContext(event)) malformed += 1;
      else generation = Math.max(generation, event.generation);
    } else if (event.type === 1) {
      inputEvents += 1;
    }
  }
  return { malformed, inputEvents, generation };
};
const consumedSurface = consumeTypedSequence([
  { type: 9, ...surface() },
  { type: 1 },
]);
check('valid type9 is consumed without malformed/input injection and pump continues',
  consumedSurface.malformed === 0 && consumedSurface.inputEvents === 1
    && consumedSurface.generation === 41);
const droppedSurface = consumeTypedSequence([
  { type: 9, ...surface({ generation: 0 }) },
  { type: 1 },
]);
check('malformed type9 drops only itself and the next input still drains',
  droppedSurface.malformed === 1 && droppedSurface.inputEvents === 1);

// Behavioral mirror of the source contract: two devices holding the same
// button must still produce two UP edges carrying their original MouseIDs.
const releaseAllMouseSources = (sources) => sources.flatMap(source =>
  [1, 2, 3, 4, 5]
    .filter(button => (source.held & (1 << (button - 1))) !== 0)
    .map(button => ({ mouseId: source.mouseId, button })));
check('two-device RESET releases each held button under its own MouseID',
  JSON.stringify(releaseAllMouseSources([
    { mouseId: 42, held: 1 << 0 },
    { mouseId: 77, held: 1 << 0 },
  ])) === JSON.stringify([
    { mouseId: 42, button: 1 },
    { mouseId: 77, button: 1 },
  ]));

const negative = [
  {
    id: 'requested-flags',
    files: () => mutate('src/video/SDL_video.c',
      'SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER', 'SDL_PROP_FIXTURE_WRONG_FLAGS_NUMBER'),
  },
  {
    id: 'fixed-egl-config',
    files: () => mutateAll('egl_config_locked', 'fixture_lock_missing'),
  },
  {
    id: 'window-roles',
    files: () => mutateAll('OPENHARMONY_GetPresentedWindow', 'Fixture_GetAnyWindow'),
  },
  {
    id: 'auxiliary-pbuffer',
    files: () => mutate('src/video/openharmony/SDL_openharmonywindow.c',
      'data->egl_surface = SDL_EGL_CreateOffscreenSurface(device, data->surface_width, data->surface_height);',
      '/* SDL_EGL_CreateOffscreenSurface is only a comment decoy. */\n        data->egl_surface = EGL_NO_SURFACE;'),
  },
  {
    id: 'lease-broker',
    files: () => mutate('src/video/openharmony/SDL_openharmonywindow.c',
      'AMCL_NATIVE_WINDOW_LEASE_BROKER', 'AMCL_UNSAFE_RAW_WINDOW_POINTER'),
  },
  {
    id: 'role-aware-focus',
    files: () => mutate('src/video/openharmony/SDL_openharmonywindow.c',
      'void OPENHARMONY_ShowWindow', 'void Fixture_UnwiredShowWindow'),
  },
  {
    id: 'role-aware-pixel-size',
    files: () => mutate('src/video/openharmony/SDL_openharmonyvideo.c',
      'device->GetWindowSizeInPixels = OPENHARMONY_GetWindowSizeInPixels;',
      'device->GetWindowSizeInPixels = NULL;'),
  },
  {
    id: 'role-aware-swap',
    files: () => mutateAll('OPENHARMONY_WINDOW_PRESENTED', 'FIXTURE_PRESENTED_WITHOUT_ROLE'),
  },
  {
    id: 'destroy-any-role',
    files: () => mutate('src/video/openharmony/SDL_openharmonywindow.c',
      'SDL_free(data);', '/* SDL_free(data); is a comment decoy. */'),
  },
  {
    id: 'no-runtime-fingerprints',
    files: () => mutate('src/video/openharmony/SDL_openharmonywindow.c',
      'SDL_WindowFlags requested = SDL_GetWindowCreateFlags(create_props);',
      'SDL_WindowFlags requested = SDL_GetWindowCreateFlags(create_props);\n'
        + '    if (SDL_strstr(window->title, "Minecraft RenderPearl Snapshot 9")) requested |= SDL_WINDOW_UTILITY;'),
  },
  {
    id: 'focus-independent-activation',
    name: 'focus-independent-activation semantics',
    files: () => mutate('entry/src/main/cpp/platform/input_foreground_gate.h',
      'return focus != ComponentFocus::Blurred;',
      'return focus == ComponentFocus::Focused;'),
  },
  {
    id: 'typed-focus-capture',
    name: 'typed capture pending-vs-loss predicate',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      'event->resetReason != AMCL_CAPTURE_REASON_NONE',
       'event->resetReason == AMCL_CAPTURE_REASON_NONE'),
  },
  {
    id: 'relative-disable-authority',
    name: 'relative disable request-flag authority guard',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      '(input_window->flags & SDL_WINDOW_MOUSE_RELATIVE_MODE) != 0',
      'fixture_accepts_unclassified_internal_release'),
  },
  {
    id: 'relative-disable-authority',
    name: 'relative disable rejection before host grab write',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      'return SDL_SetError("relative release lacks authority");',
      'return true;'),
  },
  {
    id: 'relative-disable-authority',
    name: 'host relative-disable authority is one-shot',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      `if (!enabled) {
        host_relative_disable_authority = AMCL_RELATIVE_DISABLE_NONE;
    }`,
      `if (!enabled) {
        fixture_authority_remains_latched();
    }`),
  },
  {
    id: 'relative-disable-authority',
    name: 'host loss never clears bridge grab intent',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      'bool disabled = SDL_SetRelativeMouseMode(false);',
      'bool disabled = SDL_SetRelativeMouseMode(false);\n    bridge->SetGrabState(0);'),
  },
  {
    id: 'relative-disable-authority',
    name: 'RESET preserves relative and capture authority',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      `case AMCL_BACKEND_EVENT_RESET:
        SDL_ResetKeyboard();
        host_baseline_valid = false;`,
      `case AMCL_BACKEND_EVENT_RESET:
        SDL_ResetKeyboard();
        OPENHARMONY_DisableRelativeModeForHostLoss(AMCL_RELATIVE_DISABLE_CAPTURE_LOST);
        host_baseline_valid = false;`),
  },
  {
    id: 'relative-disable-authority',
    name: 'current-state W=0 clears stale bridge grab',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      '(window->flags & SDL_WINDOW_MOUSE_RELATIVE_MODE) == 0',
      '(window->flags & SDL_WINDOW_MOUSE_RELATIVE_MODE) != 0'),
  },
  {
    id: 'relative-disable-authority',
    name: 'current-state W=0 clears capture tuple',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      `bridge->IsGrabbing()) {
            host_capture_requested = false;
            host_capture_active = false;`,
      `bridge->IsGrabbing()) {
            host_capture_requested = false;
            fixture_capture_active_survives_W0();`),
  },
  {
    id: 'relative-disable-authority',
    name: 'granted current-state reactivates SDL global relative',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      'SDL_SetRelativeMouseMode(true)',
      'fixture_grant_never_reactivates_relative()'),
  },
  {
    id: 'relative-disable-authority',
    name: 'idempotent enable preserves just-granted capture active',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      `host_capture_requested = true;
        if (!bridge->IsGrabbing()) {`,
      `host_capture_requested = true;
        host_capture_active = false;
        if (!bridge->IsGrabbing()) {`),
  },
  {
    id: 'relative-disable-authority',
    name: 'idempotent enable does not repeat bridge grab write',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      `host_capture_requested = true;
        if (!bridge->IsGrabbing()) {`,
      `host_capture_requested = true;
        bridge->SetGrabState(1);
        if (!bridge->IsGrabbing()) {`),
  },
  {
    id: 'relative-disable-authority',
    name: 'window-null best-effort clears host grab',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      'if (!enabled && driver_teardown) {',
      'if (!enabled && fixture_driver_teardown_never_matches) {'),
  },
  {
    id: 'relative-disable-authority',
    name: 'presented teardown best-effort clears host grab',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      'static void OPENHARMONY_AMCL_QuitMouse(void)',
      'static void FIXTURE_QuitMouse_without_bridge_cleanup(void)'),
  },
  {
    id: 'typed-relative-single-owner',
    files: () => mutate('entry/src/main/cpp/input/adapters/backend_input_bridge.cpp',
      'sink.relative = RelativeSink;', 'sink.relative = nullptr;'),
  },
  {
    // ⭐ 真机否证过的第一个代理：抑制端退回"typed 通道可调"（计划 §115）。
    id: 'typed-relative-single-owner',
    name: 'accumulated-cursor suppression must not widen to "typed callable"',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      'if (grabbing && OPENHARMONY_TypedRelativeOwnsGrabbedMotion(typed_relative_owner)) {',
      'if (grabbing && typed_relative_owner) {'),
  },
  {
    // ⭐ 真机否证过的第二个代理：归属只看"capture 已授予"。设备只要**报告**有鼠标能力
    // 光标锁就成功，于是纯触屏会话里它恒真、grabbed 运动零 owner（计划 §116）。
    id: 'typed-relative-single-owner',
    name: 'ownership must not rest on capture-granted alone',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      `    return typed_relative_owner && OPENHARMONY_TypedRelativeCaptureGranted() &&
           host_typed_relative_seen;`,
      '    return typed_relative_owner && OPENHARMONY_TypedRelativeCaptureGranted();'),
  },
  {
    id: 'typed-relative-single-owner',
    name: 'ownership transfers only where a RELATIVE record was delivered',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      `            if (!host_typed_relative_seen) {
                host_typed_relative_seen = true;
                host_baseline_valid = false;
            }
`,
      ''),
  },
  {
    id: 'typed-relative-single-owner',
    name: 'grab flip clears the ownership evidence',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      `        host_baseline_valid = false;
        host_typed_relative_seen = false;
    }`,
      `        host_baseline_valid = false;
    }`),
  },
  {
    id: 'typed-relative-single-owner',
    name: 'typed RELATIVE delivery must read the same named predicate',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      'if (OPENHARMONY_TypedRelativeCaptureGranted() && SDL_GetRelativeMouseMode()) {',
      'if (SDL_GetRelativeMouseMode()) {'),
  },
  {
    id: 'typed-relative-single-owner',
    name: 'both grabbed-motion flows stay counted',
    // 必须整体改名：门禁查的是标识符是否还在，只改声明会留下使用点而假绿。
    files: () => mutateAll(
      'host_grabbed_motion_suppressed', 'fixture_uncounted_suppression'),
  },
  {
    id: 'typed-surface-context',
    name: 'typed surface context host sink',
    files: () => mutate('entry/src/main/cpp/input/adapters/backend_input_bridge.cpp',
      'sink.surfaceContext = SurfaceContextSink;', 'sink.surfaceContext = nullptr;'),
  },
  {
    id: 'typed-surface-context',
    name: 'typed surface context SDL discriminator',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      '#define AMCL_BACKEND_EVENT_SURFACE_CONTEXT 9u',
      '#define FIXTURE_MISSING_SURFACE_CONTEXT 9u'),
  },
  {
    id: 'typed-surface-context',
    name: 'typed surface context validator',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      `case AMCL_BACKEND_EVENT_SURFACE_CONTEXT: {
        Uint32 valid_fields`,
      `case AMCL_BACKEND_EVENT_SURFACE_CONTEXT: {
        return false;
        Uint32 valid_fields`),
  },
  {
    id: 'typed-surface-context',
    name: 'typed surface context explicit consumer',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      `case AMCL_BACKEND_EVENT_SURFACE_CONTEXT:
        if (event.deviceId > host_surface_context_generation) {
            host_surface_context_generation = event.deviceId;
        }
        break;`,
      `case AMCL_BACKEND_EVENT_SURFACE_CONTEXT:
        fixture_surface_context_falls_through_default();
        break;`),
  },
  {
    id: 'typed-pointer-device-identity',
    files: () => mutate('entry/src/main/cpp/input/adapters/backend_input_bridge.cpp',
      'sink.device = DeviceSink;', 'sink.device = nullptr;'),
  },
  {
    id: 'typed-pointer-device-identity',
    name: 'typed pointer RESET per-device release',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      'SDL_SendMouseButton(0, window, held_sources[source_index].mouse_id, 1, false);',
      'SDL_SendMouseButton(0, window, SDL_DEFAULT_MOUSE_ID, 1, false);'),
  },
  {
    id: 'typed-pointer-device-identity',
    name: 'typed pointer RESET window-loss fallback clear',
    files: () => mutate('src/video/openharmony/SDL_openharmonyamcl.c',
      'mouse->sources[live_index].buttonstate = 0;',
      'fixture_window_loss_leaves_buttonstate_held();'),
  },
  {
    id: 'focus-independent-activation',
    name: 'focus-independent-activation single writer',
    files: () => {
      const fixture = greenFixture();
      fixture.set('entry/src/main/cpp/platform/rogue_foreground_writer.cpp', `
void RogueWriter(void)
{
    setenv("AMCL_WINDOW_FOREGROUND", "1", 1);
}
`);
      return fixture;
    },
  },
];

for (const item of negative) {
  const report = analyzeFiles(item.files());
  const red = failedIds(report);
  check(`negative fixture turns ${item.name ?? item.id} red`, red.includes(item.id),
    `failed=${red.join(', ') || '(none)'}`);
}

// Patch parser smoke test: all-new-file hunks reconstruct the same semantic
// corpus. This keeps default --patch-series mode from becoming an untested,
// always-green side door while source fixtures are the only path exercised.
const patch = [...greenFixture()].map(([rel, content]) => [
  `diff --git a/${rel} b/${rel}`,
  'new file mode 100644',
  '--- /dev/null',
  `+++ b/${rel}`,
  `@@ -0,0 +1,${content.split(/\r?\n/).length} @@`,
  ...content.split(/\r?\n/).map((line) => `+${line}`),
].join('\n')).join('\n');
const patchFiles = parsePatchText(patch, '<green-fixture.patch>');
const patchReport = analyzeFiles(patchFiles, { mode: 'patch-series', input: '<fixture>' });
check('green patch fixture passes every rule', patchReport.ok,
  `failed=${failedIds(patchReport).join(', ')}`);

console.log('');
if (failures > 0) {
  console.error(`test-check-sdl3-multiwindow-contract: ${failures} failure(s)`);
  process.exit(1);
}
console.log(`test-check-sdl3-multiwindow-contract: ${RULE_IDS.length} rules / ${negative.length} negative mutations passed`);
