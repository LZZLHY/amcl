# STB resize v1 binary compatibility

The modern LWJGL STB API stays intact. Legacy public method descriptors are
forwarded to `org.lwjgl.stb.STBImageResizeV1`, compiled from the pinned 3.3.3
wrapper. Its JNI functions have a distinct class prefix and compile the original
resize implementation as static symbols in a separate translation unit. Both
implementations live in `liblwjgl_stb.so`; no legacy native library is searched at runtime.

`sources.json` pins upstream commit and complete file hashes. LWJGL wrapper/JNI
code uses the LWJGL BSD license; the resize header carries its public-domain/MIT
license. Source notices are preserved. The reference JAR is build/test input only.

Modern constants retain their upstream meanings. Already compiled old consumers
carry old constant values and reach the v1 implementation; source users wanting
the old advanced API should use the explicit `STBImageResizeV1` constants/API.

Build with `python scripts/lwjgl-stb-compat/prepare.py --native`. Regular JAR
preparation uses the same script without `--native`. API collision, unpinned
source, missing JNI, and final package fingerprint mismatches are errors.
