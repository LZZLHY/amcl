/*
 * Copyright (c) 2022-2025 Huawei Device Co., Ltd.
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

#ifndef _INFO_APPLICATION_TARGET_SDK_VERSION_H
#define _INFO_APPLICATION_TARGET_SDK_VERSION_H

#ifdef __cplusplus
extern "C" {
#endif

#define __INNER_CONCAT(a, b) a##.##b
#define __INNER_APIAVAILABLE(ver) __builtin_available(ohos ver, *)

/**
  * @brief To ensure compatibility and stability of an application across different versions.
  * Prevent crashes caused by invoking non-existent APIs on older systems through compile-time
  * and runtime conditional checks.
  * Whenever using APIs that are newer than the distribution target version,
  * it is essential to protect them with the APIAVAILABLE method and provide a reasonable fallback solution.
  * see [Capi Compatibility Protection Usage Guide](https://developer.huawei.com/consumer/cn/doc/harmonyos-releases/c-api-compatibility-warning-elim)
  *
  * @param maj, int value 0 - 99.
  * @param min, int value 0 - 99.
  * @param patch, int value 0 - 99.
  * @since 22
  */
#define APIAVAILABLE(maj, min, patch) __INNER_APIAVAILABLE(__INNER_CONCAT(maj, min##.##patch))

#define SDK_VERSION_FUTURE 9999
#define SDK_VERSION_7 7
#define SDK_VERSION_8 8
#define SDK_VERSION_9 9
#define OH_API_VERSION_10 10
#define OH_API_VERSION_11 11
#define OH_API_VERSION_12 12
#define OH_API_VERSION_13 13
#define OH_API_VERSION_14 14
#define OH_API_VERSION_15 15
#define OH_API_VERSION_16 16
#define OH_API_VERSION_17 17
#define OH_API_VERSION_18 18
#define OH_API_VERSION_19 19
#define OH_API_VERSION_20 20
#define OH_API_VERSION_21 21
#define OH_API_VERSION_22 22
#define OH_API_VERSION_23 23
#define OH_API_VERSION_24 24
#define OH_API_VERSION_25 25
#define OH_API_VERSION_26 26
#define OH_CURRENT_API_VERSION OH_API_VERSION_26

/**
  * @brief Get the target sdk version number of the application.
  * @return The target sdk version number.
  */
int get_application_target_sdk_version(void);

/**
  * @brief Set the target sdk version number of the application.
  * @param target The target sdk version number.
  */
void set_application_target_sdk_version(int target);

#ifdef __cplusplus
}
#endif

#endif // _INFO_APPLICATION_TARGET_SDK_VERSION_H
