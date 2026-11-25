interface DestinationWait {
  activity: number;
  resolve: (shown: boolean) => void;
}

/** 只认首页对原活动的已显示回执；标记已读和返回路由都不是结果页真正打开的证明。 */
export class MessageDestination {
  private static wait: DestinationWait | undefined = undefined;

  static async open(activity: number, navigate: () => void): Promise<boolean> {
    if (!Number.isSafeInteger(activity) || activity <= 0 || MessageDestination.wait) return false;
    return new Promise<boolean>((resolve: (shown: boolean) => void): void => {
      let timer: number = -1;
      const request: DestinationWait = { activity:activity, resolve:(shown: boolean): void => {
        if (MessageDestination.wait !== request) return;
        MessageDestination.wait = undefined;
        clearTimeout(timer);
        resolve(shown);
      } };
      MessageDestination.wait = request;
      timer = setTimeout((): void => request.resolve(false),5000);
      try { navigate(); } catch (_) { request.resolve(false); }
    });
  }

  static witness(activity: number): (shown: boolean) => void {
    const current = MessageDestination.wait;
    return (shown: boolean): void => {
      if (shown && current && current.activity === activity && current === MessageDestination.wait) current.resolve(true);
    };
  }
}
