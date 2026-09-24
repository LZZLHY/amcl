#include "amcl_input_api.h"

int amcl_input_c_abi_smoke(void) {
    return sizeof(AmclInputBlobRef) == 16u &&
                   sizeof(AmclInputEventHeader) == 72u &&
                   offsetof(AmclInputEventHeader, deviceClass) == 44u &&
                   sizeof(AmclInputSurfacePayload) == 32u &&
                   offsetof(AmclInputSurfacePayload, validFields) == 20u &&
                   offsetof(AmclInputSurfacePayload,
                            publicationGeneration) == 24u &&
                   sizeof(AmclInputDiagnosticDropPayload) == 48u &&
                   offsetof(AmclInputDiagnosticDropPayload, rawControl) == 8u &&
                   offsetof(AmclInputDiagnosticDropPayload,
                            hardwareScanCode) == 16u &&
                   sizeof(AmclInputEvent) == 120u &&
                   sizeof(AmclInputBackendConsumerStatePayload) == 48u &&
                   sizeof(AmclInputSurfaceContextPayload) == 48u &&
                   offsetof(AmclInputSurfaceContextPayload, widthPx) == 16u &&
                   offsetof(AmclInputSurfaceContextPayload, density) == 24u &&
                   offsetof(AmclInputSurfaceContextPayload, transform) == 32u &&
                   offsetof(AmclInputSurfaceContextPayload, generation) == 40u &&
                   sizeof(AmclInputSnapshotV1) == 104u &&
                   offsetof(AmclInputHostApiV1, generation) == 16u &&
                   offsetof(AmclInputHostApiV1, beginSession) == 24u &&
                   offsetof(AmclInputHostApiV1, readPacketBlob) == 112u &&
                   AMCL_INPUT_EVENT_POINTER_ENTER == 11u &&
                   AMCL_INPUT_EVENT_TEXT_COMMIT == 12u &&
                   AMCL_INPUT_EVENT_TEXT_EDITING == 13u &&
                   AMCL_INPUT_EVENT_TEXT_CANDIDATES == 14u &&
                   AMCL_INPUT_EVENT_DIAGNOSTIC_DROP == 16u &&
                   AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED == 18u &&
                   AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED == 19u &&
                   AMCL_INPUT_SOURCE_IME != AMCL_INPUT_SOURCE_UNKNOWN &&
                   AMCL_INPUT_WHEEL_UNIT_PIXEL != AMCL_INPUT_WHEEL_UNIT_LINE &&
                   AMCL_INPUT_DEVICE_CAP_KEYBOARD != 0u &&
                   AMCL_INPUT_SURFACE_FIELD_DIMENSIONS != 0u &&
                   AMCL_INPUT_SURFACE_FIELD_TRANSFORM != 0u &&
                   AMCL_INPUT_SURFACE_FIELD_DENSITY != 0u &&
                    AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION == (1u << 3) &&
                    AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND == (1u << 2) &&
                    AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP == (1u << 4) &&
                   AMCL_INPUT_DEVICE_CLASS_UNKNOWN == 0u &&
                   AMCL_INPUT_DEVICE_CLASS_MOUSE == 1u &&
                   AMCL_INPUT_DEVICE_CLASS_TOUCHPAD == 2u &&
                   AMCL_INPUT_CAP_SURFACE_FIELD_VALIDITY != 0u &&
                    AMCL_INPUT_CAP_DIAGNOSTIC_DROP != 0u &&
                    AMCL_INPUT_CAP_BACKEND_CONSUMER_READY != 0u &&
                    AMCL_INPUT_CAP_DEVICE_CLASS == (1u << 16) &&
                    AMCL_INPUT_CAP_SURFACE_CONTEXT == (1u << 17) &&
                    AMCL_INPUT_CAP_TEXT_INPUT_SESSION == (1u << 18) &&
                     AMCL_INPUT_CAP_VERIFIED_RAW_RELATIVE != 0u &&
                      AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE == (1ull << 14) &&
                    AMCL_INPUT_HOST_API_GENERATION != 0u
               ? 0
               : 1;
}
