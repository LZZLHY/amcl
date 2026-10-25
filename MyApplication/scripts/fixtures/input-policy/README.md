# 输入政策激活报告的首批生产回归

入口为 `node scripts/test-input-policy-activation.mjs --output <仓库外绝对目录>`。默认输出复用
`scripts/lib/workspace-paths.mjs` 的工作区发现规则；独立克隆可显式提供外置输出目录。测试不启动
SDK、设备或 JVM，不能替代四产品构建和真机验收。

测试直接执行 `LayoutStore` 的保存事务、`InputConfigurationDelivery` 的定义与域回执、会话拥有的
`InputConfigurationRuntime`、`GameControls` 的配置 listener/schema 投影/呈现/节点确认/只读文字
订阅，以及 `TouchSurfaceController` 的发布算法。无法在 Node 创建的 ArkUI 布局和 Native 出口
是可编程边界；测试不另写一套保存、投影、发布或状态归约算法。

真实状态序列包括：

- 已确认保存绑定稳定 profile ID/revision；保存失败不创建新的激活 operation。
- 无 activity ID 的准备代仅表示 Preparing，实际首次 bind 保留原 generation 和 operation。
- Native 未确认、异常或资格不可读只表示 Waiting/NotApplied，不猜成 Native 拒绝。
- 保留旧四字段全来源 look 的完整原子参数组；物理 alpha=1 和 gyro 平滑/加速例外显式保留。
  运行报告不写入持久 JSON，也不新增 LookBySource 字段。
- 旧接触未结束时实际 UI 显示“方案已保存，待生效”；安装回执丢失查询同一发布，不重复安装。
  UI ACK false 不能结束原 publication/candidate/token，真正确认后相同政策 operation 才变成 Applied。
- A 发布在途、B 保存到达时，B 的 desired 身份与 A 的 target 身份分开；旧 A token 不确认 B。
- 旧 Runtime 完成、旧 Store registration 和旧组件 appearance 回调不能写后来操作的成功状态。
- 纯报告读取不调用 Native，不数触点、不重试消费者，也不新增运行时钟。

四个撤回负控分别删除实际 UI SavedPending 表达、删除实际 ACK false 门、改回旧 reader 借后来
controller 的进度，以及删除旧 Native 完成的 operation 资格。每个负控必须先可编译并运行到
具名行为断言；语法或导入错误不算反控成立。
输出收据绑定实际源字节 SHA、系统实取起止时间、正例序列和负控断言。

这一批覆盖现有 Native look、触控发布和既有手柄消费者的真实登记状态，不能声称整个 P4 已完成。
完整独立来源政策、耦合组的原子激活、旧数据迁移选择、导入与跨进程关闭事务仍按提案 §十八
继续实施。稳定 ID、journal 和三方合并复用原生产实现，本测试没有改变持久格式。
