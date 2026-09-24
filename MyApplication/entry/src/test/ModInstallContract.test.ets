/**
 * 模组安装边界契约：启动器只保障文件事务，运行兼容性由游戏加载器处理。
 * 目录锁测试不访问真实磁盘，使用独立虚拟路径和可控 Promise 验证异常释放及串行顺序。
 * 原包内版本谓词/冲突求解器已经退役，不能继续以其错误语义作为产品验收标准。
 */
import { describe, it, expect } from '@ohos/hypium';
import { modInstallationActive, withModDirectoryLock } from 'mods';
import { PreLaunchValidator, PreLaunchCheck } from 'launch';

export default function modInstallContractTest(): void {
  describe('ModInstallContract', () => {
    it('预检保留安装状态而不再声明模组兼容性结论', 0, () => {
      const checks: PreLaunchCheck[] = PreLaunchValidator.pendingChecks();
      expect(checks.some((check: PreLaunchCheck): boolean => check.id === 'mod_install_state')).assertTrue();
      expect(checks.some((check: PreLaunchCheck): boolean => check.id === 'mods')).assertFalse();
      // 撤销模组语义裁决不应一并撤销启动器实际交付文件与 classpath 的责任。
      expect(checks.some((check: PreLaunchCheck): boolean => check.id === 'runtime')).assertTrue();
      expect(checks.some((check: PreLaunchCheck): boolean => check.id === 'contract')).assertTrue();
    });

    it('同目录的失败事务释放锁后等待者才能进入', 0, async (): Promise<void> => {
      const dir: string = '/amcl-contract/serialized/mods';
      let releaseFirst: () => void = (): void => {};
      let markEntered: () => void = (): void => {};
      const held: Promise<void> = new Promise<void>((resolve: () => void): void => { releaseFirst = resolve; });
      const entered: Promise<void> = new Promise<void>((resolve: () => void): void => { markEntered = resolve; });
      const first: Promise<void> = withModDirectoryLock<void>(dir, async (): Promise<void> => {
        markEntered();
        await held;
        throw new Error('测试安装失败');
      });
      // 先接住预期异常，避免异步测试框架将未处理拒绝误判为套件外失败。
      const failed: Promise<boolean> = first.then((): boolean => false, (): boolean => true);
      await entered;
      let secondEntered: boolean = false;
      const second: Promise<void> = withModDirectoryLock<void>(dir, async (): Promise<void> => {
        secondEntered = true;
      });
      try {
        expect(modInstallationActive(dir)).assertTrue();
        expect(secondEntered).assertFalse();
      } finally {
        // 断言失败也释放测试自己的锁，避免让排队者和套件永久悬挂。
        releaseFirst();
        await second;
      }
      expect(await failed).assertTrue();
      expect(secondEntered).assertTrue();
      expect(modInstallationActive(dir)).assertFalse();
    });

    it('不同实例目录的事务互不阻塞', 0, async (): Promise<void> => {
      const firstDir: string = '/amcl-contract/first/mods';
      const secondDir: string = '/amcl-contract/second/mods';
      let releaseFirst: () => void = (): void => {};
      const held: Promise<void> = new Promise<void>((resolve: () => void): void => { releaseFirst = resolve; });
      const first: Promise<void> = withModDirectoryLock<void>(firstDir, async (): Promise<void> => { await held; });
      try {
        await withModDirectoryLock<void>(secondDir, async (): Promise<void> => {
          expect(modInstallationActive(firstDir)).assertTrue();
          expect(modInstallationActive(secondDir)).assertTrue();
        });
        expect(modInstallationActive(secondDir)).assertFalse();
      } finally {
        // 即便断言失败也必须释放测试自己的锁，避免污染后续用例。
        releaseFirst();
        await first;
      }
      expect(modInstallationActive(firstDir)).assertFalse();
    });
  });
}
