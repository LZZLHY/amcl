# HarmonyOS runtime scheduling adapter

AMCL keeps HarmonyOS scheduling policy in the host integration layer, outside
MobileGlues and generic GL code:

- `libglfw` acquires `QOS_USER_INTERACTIVE` only after EGL or Zink has made a
  context current on the actual render thread. It restores the previous QoS on
  context release, window teardown, GLFW termination, or thread exit.
- `libentry` queries the default display refresh rate and passes a validated
  expected-rate range to XComponent at registration and surface lifecycle
  boundaries. The default range is `30..displayHz`, with `displayHz` expected.
- This is a scheduler hint only. AMCL does not register an XComponent frame
  callback, add another VSync loop, change CPU affinity, or replace Minecraft's
  own render loop and `eglSwapInterval` behavior.

## Surface lifecycle ownership

XComponent callbacks never call EGL or OSMesa. They publish an atomic
`NativeWindow + size + generation` snapshot. The render thread consumes each
generation from both `glfwPollEvents` and `glfwSwapBuffers` and classifies it as
lost, acquired, replaced, resized, or metadata-only. This guarantees a skipped
poll cannot present through an older window pointer.

The tuple is also mirrored into one encoded environment value. This is the
coherent fallback for HarmonyOS linker namespaces where the JVM and `libentry`
can hold distinct `libglfw` instances; the three legacy environment variables
are used only when no generation-aware publisher exists.

The XComponent-owning `libglfw` also publishes a process-lifetime lease broker.
Every consumer acquires an independent `OHNativeWindow` reference while the
publisher mutex still protects the current generation. All NativeObject
reference/unreference calls are serialized through that broker because the
platform API itself is not thread-safe. A GLFW window records the retained
object separately from its current presentation pointer, so replacement cannot
release the new object by mistake or leak the old one. Vulkan surface creation
and the Vulkan diagnostic probe use the same leased snapshot; the legacy raw
getter is a borrowed, synchronous compatibility view only.

- EGL surface loss/replacement destroys only `EGLSurface`; `EGLDisplay`,
  `EGLContext`, and Minecraft GL objects survive and are rebound to the new
  window on the render thread. `eglSwapBuffers` failures caused by a lost native
  surface take the same bounded-backoff recovery path. If EGL cannot safely
  detach the stale surface, presentation remains blocked and its NativeWindow
  lease remains held until a later owner-thread detach succeeds.
- `EGL_CONTEXT_LOST` is explicitly fatal: AMCL tears down the unusable EGL
  state, reports `GLFW_PLATFORM_ERROR`, and requests normal game shutdown. It
  never creates an empty replacement context while Minecraft still assumes its
  GL objects exist.
- Zink/OSMesa keeps its context and park buffer while presentation is
  suspended, then safely retargets the new `OHNativeWindow` on the render
  thread. The old park allocation is never freed while still current, and the
  NativeWindow row stride is reset before returning to the tightly packed park
  buffer. A genuine game/GLFW termination resolves and calls
  `OSMesaDestroyContext`; transient window recreation deliberately preserves it.
- Null or stale destroy callbacks fail closed. Invalid/zero dimensions publish
  a suspended epoch and are never passed to EGL initialization.

Context ownership and QoS are per render thread. A failed `MakeCurrent` does not
erase another thread's owner or release an existing context's QoS lease.
`glfwMakeContextCurrent(NULL)` changes ownership only after EGL detach succeeds.
The UI-side force-close extension is cooperative: it sets `shouldClose`, while
the render thread performs EGL/OSMesa and QoS teardown.

Optional process environment overrides are intentionally OHOS-prefixed:

| Variable | Meaning |
| --- | --- |
| `AMCL_OHOS_FRAME_RATE_HINT=off` | Disable the XComponent frame-rate hint. |
| `AMCL_OHOS_FRAME_RATE_MIN` | Minimum Hz, integer from 30 through 240. |
| `AMCL_OHOS_FRAME_RATE_MAX` | Maximum Hz, integer from 30 through 240. |
| `AMCL_OHOS_FRAME_RATE_EXPECTED` | Preferred Hz, integer from 30 through 240. |

Invalid values are ignored. Contradictory ranges are normalized so
`min <= expected <= max`. DisplayManager failures safely fall back to 60 Hz,
and all QoS/frame-rate API failures are logged without failing rendering.
