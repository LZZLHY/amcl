# MIDI 来源及必要平台差异

四代 OpenJDK 的原文逐文件 URL、固定 commit 和 SHA 位于
[`reference/source.json`](reference/source.json)。引用原文保持原字节，不按当前
工作区换行或格式规则重写。自有实现由同一份源生成四代补丁。

OH_MIDI 的精确声明以当前本机 SDK 原件为准，测试快照在 `reference/sdk/`，保留
其 Apache-2.0 许可头。SDK 本身仍是外部编译前提，测试声明不是目标系统实物。
官方入口是 [OH_MIDI C API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/capi-native-midi-h)
与 [MIDI 开发指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/using-ohmidi)。

公开 OpenHarmony MIDI 源固定到
[`2fc6019a6fda4ccb2ab38deed6122e16cb78c991`](https://github.com/openharmony/multimedia_midi_framework/tree/2fc6019a6fda4ccb2ab38deed6122e16cb78c991)。
这是公开实现取证，不等于商业平板二进制的源码身份。

- [OHMidi.cpp](https://github.com/openharmony/multimedia_midi_framework/blob/2fc6019a6fda4ccb2ab38deed6122e16cb78c991/frameworks/native/ohmidi/OHMidi.cpp)
  中 GetDeviceCount 的包装会忽略内部返回值，因此实现即使预估数量为零也实际
  调 GetDeviceInfos，并传播其错误。Destroy 返回错误前也可能已经删除 client。
- [midi_client.cpp](https://github.com/openharmony/multimedia_midi_framework/blob/2fc6019a6fda4ccb2ab38deed6122e16cb78c991/frameworks/native/midi/src/midi_client.cpp)
  会将关闭的 device 从 shared_ptr 集合移除，故 raw handle 不能在错误后盲目重用。
  SendSysEx 没有时间参数且是阻塞帮助函数，不能代替保留 Java 时间戳及分段语义
  的 Send；其内部 group 选择是 portIndex 的低四位。
- [midi_in_server.cpp](https://github.com/openharmony/multimedia_midi_framework/blob/2fc6019a6fda4ccb2ab38deed6122e16cb78c991/services/server/src/midi_in_server.cpp)
  按蓝牙权限过滤 BLE 枚举。
  [midi_service_controller.cpp](https://github.com/openharmony/multimedia_midi_framework/blob/2fc6019a6fda4ccb2ab38deed6122e16cb78c991/services/server/src/midi_service_controller.cpp)
  对已有设备连接的 OpenDevice(deviceId) 增加当前 client 引用；BLE 连接成功先登记
  该连接。因此不能仅看到 BLE driver 的 ID 打开 stub 就断言已枚举 BLE 不可打开。
- [midi_device_ble.cpp](https://github.com/openharmony/multimedia_midi_framework/blob/2fc6019a6fda4ccb2ab38deed6122e16cb78c991/services/server/src/midi_device_ble.cpp)
  只将已连接设备暴露到已注册列表；新的地址扫描/配对/连接不属于 JavaSound 已有接口。

UMP 字段由真实 SDK protocol1 类型定义与
[Microsoft 的 UMP 格式说明](https://microsoft.github.io/MIDI/kb/ump-data-format-primer/)
交叉核对。测试使用外部 General MIDI On 固定向量，不仅依赖本模块编码后再自行
解码的循环校验。SysEx7 Start/Continue 可携带 0–6 字节；F0/F7 不占 UMP 的
7-bit payload，Java continuation marker 与真正 EOX 必须区别。

上游 JNI 的必要修复均由固定原文确认：输出把 jlong 微秒截成 UINT32 并忽略返回；
输入在 CallVoidMethod 后缺少 ExceptionCheck，数组/方法查找失败可漏还消息；
关闭以一秒 join 结束为条件直接释放 handle，不能覆盖用户 Receiver 尚在栈内的
寿命。新适配保持标准方法名，但在 OHOS 构建中由统一 JNI 源实现这些边界。

授权声明与交互使用
[公开 user_grant 权限表](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/permissions-for-all-user)
和 [abilityAccessCtrl](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-abilityaccessctrl)：
ACCESS_BLUETOOTH 从 API10 起为 normal/user_grant；状态查询从 API20 起，首次申请
接口和二次设置接口均早于最低 API20。首次拒绝不自动再次弹窗，所有申请必须由
用户在设置页明确点击；声明/编译通过不表示已经取得 OS 授权。
