/** App事务与JDK续作之间的最小固定身份；不携带账号、HUKS材料、密码或私钥。 */
export interface AppUpdateBinding {
  transactionId: string; assetSha256: string; product: string; versionName: string; versionCode: number;
}
/** 仅由原安装执行权终态和实际已装身份共同确认后产生，作为耐久事件保存和重放。 */
export interface AppUpdateCompletionEvent extends AppUpdateBinding {
  installId: string; sourceRevision: string; uid: number; verifiedAt: number; runtimeIntentId?: string;
}
/** 人工维修包的真实当前身份；拿不到整包SHA时不伪造，只用于结束原执行权，不确认旧目标。 */
export interface AppUpdateSuperseder {
  product: string; versionName: string; versionCode: number; sourceRevision: string; uid: number; runtimeHostProtocols: number[];
}
