# 公开更新数据的验证与 Pages 暂存

正式推荐、预览推荐和更新日志的展示顺序分别维护。旧 `update.json` 继续服务 sideload
稳定客户端，只投影该产品 stable 的准确原件；预览、desktop-only 发行和开发者人工
构建不能推动它。官网仍是原件审核/推荐事实来源，静态文件是已提交记录的派生快照。

`tools/validate-update-feeds.mjs --root <仓库>` 核对每个实际存在的产品/通道、包名、
版本、SHA、大小、官方原件地址及历史就绪收据，并核对旧入口与 sideload stable。
日志 latest 可以是预览或另一产品，但必须引用一条实际发布日志。不生成缺失产品的占位头。

Pages workflow 使用 `tools/stage-update-pages.mjs --root . --out _site`；此入口先完成
同一生产验证，再新建输出并复制原字节，拒绝覆盖和源链接。其反例由
`node tools/test-update-feeds.mjs` 直接调用，覆盖预览、独立电脑、正式收敛、人工开发
通道误入、原件漂移和冻结随包日志。工作区本机应显式设置 `AMCL_RUN_DIR` 到仓外
D 盘任务目录；CI 使用 runner.temp。成功只保留小收据，失败保留本轮夹具。

公开源码审核匹配其准确版本对应的任一已发布产品推荐，随包 changelog 保持构建时
冻结快照；不能要求源码和旧通用 stable 或后续全局日志 latest 始终相等。源码身份、
依赖 gitlink 和许可正文的原有校验继续执行。

这些改动本身不导出新 feed、不上传包、不推送 Git 或触发部署。实际发布时仍核对
官网、raw 与 Pages 的准确版本/摘要/publicationId；服务端头已提交而 Pages 失败时，
保留该身份续作补齐，不能伪造一次跨站点原子完成。
