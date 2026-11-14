/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * @addtogroup OHMIDI
 * @{
 *
 * @brief Provides the definition of the C interface for the MIDI module.
 *
 * @since 24
 */
/**
 * @file native_midi_base.h
 *
 * @brief Declares the underlying data structure for MIDI module.
 *
 * @library libohmidi.so
 * @syscap SystemCapability.Multimedia.Audio.MIDI
 * @kit AudioKit
 * @since 24
 */
#ifndef NATIVE_MIDI_BASE_H
#define NATIVE_MIDI_BASE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>


#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief MIDI status code enumeration.
 *
 * @since 24
 */
typedef enum {
    /**
     * @error Operation successful.
     *
     * @since 24
     */
    OH_MIDI_STATUS_OK = 0,

    /**
     * @error Invalid parameter (e.g., null pointer).
     *
     * @since 24
     */
    OH_MIDI_STATUS_GENERIC_INVALID_ARGUMENT = 35500001,

    /**
     * @error IPC communication failure.
     *
     * @since 24
     */
    OH_MIDI_STATUS_GENERIC_IPC_FAILURE = 35500002,

    /**
     * @error Invalid client handle.
     *
     * @since 24
     */
    OH_MIDI_STATUS_INVALID_CLIENT = 35500003,

    /**
     * @error Invalid device handle.
     *
     * @since 24
     */
    OH_MIDI_STATUS_INVALID_DEVICE_HANDLE = 35500004,

    /**
     * @error Invalid port index.
     *
     * @since 24
     */
    OH_MIDI_STATUS_INVALID_PORT = 35500005,

    /**
     * @error The send buffer is transiently full.
     * Indicates that the shared memory buffer currently lacks space.
     * Returned by non-blocking send when a message cannot fit in the buffer.
     * Retry the operation with a short delay (recommended: 10ms).
     *
     * @since 24
     */
    OH_MIDI_STATUS_WOULD_BLOCK = 35500006,

    /**
     * @error Operation can not be handled in a reasonable time.
     *
     * @since 24
     */
    OH_MIDI_STATUS_TIMEOUT = 35500007,

    /**
     * @error The client has reached the maximum number of open devices allowed.
     * To open a new device, the client must close an existing one first.
     *
     * @since 24
     */
    OH_MIDI_STATUS_TOO_MANY_OPEN_DEVICES = 35500008,

    /**
     * @error The client has reached the maximum number of open ports allowed.
     * To open a new port, the client must close an existing one first.
     *
     * @since 24
     */
    OH_MIDI_STATUS_TOO_MANY_OPEN_PORTS = 35500009,

    /**
     * @error The client has already opened this device.
     *
     * @since 24
     */
    OH_MIDI_STATUS_DEVICE_ALREADY_OPEN = 35500010,

    /**
     * @error The client has already opened this port.
     *
     * @since 24
     */
    OH_MIDI_STATUS_PORT_ALREADY_OPEN = 35500011,

    /**
     * @error The system-wide or per-application limit for MIDI clients has been reached.
     * The application should wait or release other resources before retrying.
     *
     * @since 24
     */
    OH_MIDI_STATUS_TOO_MANY_CLIENTS = 35500012,

    /**
     * @error Permission denied.
     * Returned when the application attempts to perform an operation
     * without the required permission (e.g., Bluetooth for BLE devices).
     *
     * @since 24
     */
    OH_MIDI_STATUS_PERMISSION_DENIED = 35500013,

    /**
     * @error The MIDI system service has died or disconnected.
     * The client must be destroyed and recreated.
     *
     * @since 24
     */
    OH_MIDI_STATUS_SERVICE_DIED = 35500014,

    /**
     * @error System-level errors such as insufficient memory or system service failure.
     *
     * @since 24
     */
    OH_MIDI_STATUS_SYSTEM_ERROR = 35500100
} OH_MIDIStatusCode;

/**
 * @brief Port direction enumeration.
 *
 * @since 24
 */
typedef enum {
    /**
     * @brief Input port (Device -> Host).
     *
     * @since 24
     */
    OH_MIDI_PORT_DIRECTION_INPUT = 0,

    /**
     * @brief Output port (Host -> Device).
     *
     * @since 24
     */
    OH_MIDI_PORT_DIRECTION_OUTPUT = 1
} OH_MIDIPortDirection;

/**
 * @brief MIDI transport protocol semantics.
 *
 * @note **CRITICAL**: The SDK always uses UMP (Universal MIDI Packet) format for data transfer,
 * regardless of the selected protocol. This enum defines the "Behavior" and "Semantics"
 * of the connection, not the data structure.
 *
 * @since 24
 */
typedef enum {
    /**
     * @brief Legacy MIDI 1.0 Semantics.
     * Behavior:
     * - The service expects UMP packets strictly compatible with MIDI 1.0.
     * - **MT 0x0**: Utility Messages (e.g., Timestamps).
     * - **MT 0x1**: System Real Time and System Common Messages.
     * - **MT 0x2**: MIDI 1.0 Channel Voice Messages (32-bit).
     * - **MT 0x3**: Data Messages (64-bit) used for SysEx (7-bit payload).
     * - If the target hardware is MIDI 1.0: The service converts UMP back to byte stream (F0...F7).
     * - If the target hardware is MIDI 2.0: The service sends these packets as-is (encapsulated MIDI 1.0).
     *
     * @since 24
     */
    OH_MIDI_PROTOCOL_1_0 = 1,

    /**
     * @brief MIDI 2.0 Semantics.
     * Behavior:
     * - The service expects UMP packets leveraging MIDI 2.0 features.
     * - **MT 0x4**: MIDI 2.0 Channel Voice Messages (64-bit, high resolution).
     * - **MT 0x0**: Utility Messages (Timestamps).
     * - **MT 0xD**: Flex Data Messages (128-bit, e.g., Text, Lyrics).
     * - **MT 0xF**: UMP Stream Messages (128-bit, Endpoint Discovery, Function Blocks).
     * - **MT 0x3 / MT 0x5**: Data Messages (64-bit or 128-bit).
     * @note Fallback Policy: If this protocol is requested but the hardware only supports MIDI 1.0,
     * the service will perform "Best-Effort" translation (e.g., downscaling 32-bit velocity
     * to 7-bit, converting Type 4 back to Type 2). Some data precision or message types (like Flex Data)
     * may be lost or ignored.
     *
     * @since 24
     */
    OH_MIDI_PROTOCOL_2_0 = 2
} OH_MIDIProtocol;

/**
 * @brief MIDI Device type.
 *
 * @since 24
 */
typedef enum {
    /**
     * @brief USB MIDI device.
     *
     * @since 24
     */
    OH_MIDI_DEVICE_TYPE_USB = 0,

    /**
     * @brief Bluetooth Low Energy MIDI device.
     *
     * @since 24
     */
    OH_MIDI_DEVICE_TYPE_BLE = 1
} OH_MIDIDeviceType;

/**
 * @brief Device connection state change action.
 *
 * @since 24
 */
typedef enum {
    /**
     * @brief Device connected.
     *
     * @since 24
     */
    OH_MIDI_DEVICE_CHANGE_ACTION_CONNECTED = 0,

    /**
     * @brief Device disconnected.
     *
     * @since 24
     */
    OH_MIDI_DEVICE_CHANGE_ACTION_DISCONNECTED = 1
} OH_MIDIDeviceChangeAction;

/**
 * @brief MIDI Event Structure (Universal).
 * The event data is transferred in Universal MIDI Packets (UMP) format.
 * MIDI 1.0 byte stream data should be converted to UMP format before
 * filling this structure.
 *
 * @since 24
 */
typedef struct {
    /**
     * @brief Timestamp in nanoseconds.
     * Base time obtained via clock_gettime(CLOCK_MONOTONIC, &time)
     * 0 indicates "send immediately".
     *
     * @since 24
     */
    uint64_t timestamp;

    /**
     * @brief Number of 32-bit words in the packet.
     * e.g., 1 for Type 2/4 (64-bit messages use 2 words)
     *
     * @since 24
     */
    size_t length;

    /**
     * @brief Pointer to UMP data (Must be 4-byte aligned).
     * This contains the raw UMP words (uint32_t).
     *
     * @since 24
     */
    uint32_t *data;
} OH_MIDIEvent;

/**
 * @brief Device Information.
 * Used for enumeration and display.
 *
 * @since 24
 */
typedef struct {
    /**
     * @brief Unique identifier for the MIDI device.
     *
     * @since 24
     */
    int64_t midiDeviceId;

    /**
     * @brief Type of the device (USB, BLE, etc.).
     *
     * @since 24
     */
    OH_MIDIDeviceType deviceType;

    /**
     * @brief The native protocol supported by the hardware.
     *
     * - If OH_MIDI_PROTOCOL_1_0: The device is a legacy device or currently configured as such.
     * - If OH_MIDI_PROTOCOL_2_0: The device supports MIDI 2.0 features.
     * @note Applications can use this to decide whether to enable high-resolution UI controls.
     *
     * @since 24
     */
    OH_MIDIProtocol nativeProtocol;

    /**
     * @brief Device name.
     *
     * @since 24
     */
    char deviceName[256];

    /**
     * @brief Vendor ID.
     *
     * @since 24
     */
    uint64_t vendorId;

    /**
     * @brief Product ID.
     *
     * @since 24
     */
    uint64_t productId;

    /**
     * @brief Physical address (for BLE device).
     *
     * @since 24
     */
    char deviceAddress[64];
} OH_MIDIDeviceInformation;

/**
 * @brief Port Information (detailed).
 * Used for enumeration (contains display names).
 *
 * @since 24
 */
typedef struct {
    /**
     * @brief The index of the port.
     *
     * @since 24
     */
    uint32_t portIndex;

    /**
     * @brief The ID of the device this port belongs to.
     *
     * @since 24
     */
    int64_t deviceId;

    /**
     * @brief Direction of the port (Input/Output).
     *
     * @since 24
     */
    OH_MIDIPortDirection direction;

    /**
     * @brief Name of the port.
     *
     * @since 24
     */
    char name[64];
} OH_MIDIPortInformation;

/**
 * @brief Port Descriptor.
 *
 * @since 24
 */
typedef struct {
    /**
     * @brief The unique ID of the port within the device (index).
     *
     * @since 24
     */
    uint32_t portIndex;

    /**
     * @brief The requested protocol behavior for this session.
     *
     * This field dictates how the Service translates data between the app and the hardware.
     *
     * **Compatibility Behavior:**
     *
     * 1. **Request OH_MIDI_PROTOCOL_1_0 on a 2.0 Device**: (Safe)
     * - The service creates a virtual 1.0 view.
     * - App sends UMP Type 2 (MIDI 1.0 Channel Voice).
     * - Device receives UMP Type 2.
     * - Fully compatible.
     *
     * 2. **Request OH_MIDI_PROTOCOL_2_0 on a 1.0 Device**: (Lossy)
     * - The service creates a virtual 2.0 view.
     * - App sends UMP Type 4 (MIDI 2.0 Voice).
     * - Service **down-converts** Type 4 to Type 2 (e.g., clipping velocity, dropping per-note data).
     * - **Warning**: Data precision will be lost. Advanced messages may be dropped.
     *
     * @since 24
     */
    OH_MIDIProtocol protocol;
} OH_MIDIPortDescriptor;

/**
 * @brief Declares a MIDI client.
 *
 * @since 24
 */
typedef struct OH_MIDIClientStruct OH_MIDIClient;

/**
 * @brief Declares a MIDI device.
 *
 * @since 24
 */
typedef struct OH_MIDIDeviceStruct OH_MIDIDevice;

/**
 * @brief Callback for monitoring device connection/disconnection.
 *
 * @param userData The user context pointer passed to {@link #OH_MIDIClient_Create}.
 * @param action Device change action (connected/disconnected).
 * @param deviceInfo Information of the changed device.
 *
 * @since 24
 */
typedef void (*OH_MIDICallback_OnDeviceChange)(
    void *userData, OH_MIDIDeviceChangeAction action, OH_MIDIDeviceInformation deviceInfo);

/**
 * @brief Callback for handling client-level errors.
 * Invoked when a critical error occurs in the MIDI service (e.g., service crash).
 * Applications may need to recreate the client when this occurs.
 *
 * @param userData The user context pointer passed to {@link #OH_MIDIClient_Create}.
 * @param code The error code indicating the cause.
 *
 * @since 24
 */
typedef void (*OH_MIDICallback_OnError)(void *userData, OH_MIDIStatusCode code);

/**
 * @brief Callback for receiving MIDI data (Batch Processing).
 *
 * @warning **CRITICAL: Memory Safety**
 * The events array and all data pointers within it
 * are **transient and ONLY valid during this callback**.
 * Accessing these pointers after the callback returns
 * causes **undefined behavior** (crashes, memory corruption).
 * You MUST copy any data you need to keep.
 *
 * @warning This callback is invoked on a high-priority system thread.
 * Do **not** perform blocking operations, heavy computation, or I/O.
 *
 * @param userData The user context pointer passed to {@link #OH_MIDIDevice_OpenInputPort}.
 * @param events Pointer to the array of MIDI events received.
 * @param eventCount The number of events in the array.
 *
 * @since 24
 */
typedef void (*OH_MIDIDevice_OnReceived)(void *userData, const OH_MIDIEvent *events, size_t eventCount);

/**
 * @brief Callback for the result of asynchronously opening a BLE device.
 *
 * This callback is invoked when the BLE device open attempt finishes, either successfully
 * or with a failure.
 *
 * @param userData The user context pointer passed to {@link #OH_MIDIClient_OpenBLEDevice}.
 * @param opened Indicates whether the device was successfully opened.
 *     True: Device successfully opened, device handle is valid.
 *     False: Device open failed, device handle is NULL.
 * @param device The handle of the opened device.
 *     If opened is true, the application MUST close this handle using
 * {@link #OH_MIDIClient_CloseDevice} when it is no longer needed.
 *     If opened is false, this parameter is NULL.
 * @param info The information of the opened device.
 * Note: This object is valid ONLY within the scope of this callback.
 *     If you need to persist specific attributes (e.g., ID or Name), copy them.
 *
 * @since 24
 */
typedef void (*OH_MIDIClient_OnDeviceOpened)(void *userData,
                                             bool opened,
                                             OH_MIDIDevice *device,
                                             OH_MIDIDeviceInformation info);

/**
 * @brief Client callbacks structure.
 *
 * @since 24
 */
typedef struct {
    /**
     * @brief Handler for device hotplug events.
     *
     * @since 24
     */
    OH_MIDICallback_OnDeviceChange onDeviceChange;

    /**
     * @brief Handler for critical service errors.
     *
     * @since 24
     */
    OH_MIDICallback_OnError onError;
} OH_MIDICallbacks;

#ifdef __cplusplus
}
#endif
/** @} */
#endif // NATIVE_MIDI_BASE_H