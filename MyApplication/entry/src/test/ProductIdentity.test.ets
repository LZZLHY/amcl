/*
 * ProductIdentity.test.ets — 产品身份 banner 的纯函数单测（批次 D8）
 *
 * 覆盖：格式化 / 反向解析 / 字段齐全判定，正反向成对。
 *
 * 为什么这些函数是纯的（契约 §8.3.1）：采集侧要读 deviceInfo / bundleManager /
 * 生成的 ProductBuildProfile，那些在 Node 下的单测里都不存在。把"值从哪来"与
 * "值长什么样"分开之后，后者才能被单独喂样本 —— **能跑通不是判据，能被单独喂样本才是**。
 *
 * 创建日期：2026-09-07
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ProductIdentity,
  PRODUCT_IDENTITY_FIELDS,
  PRODUCT_IDENTITY_BANNER_PREFIX,
  formatProductIdentity,
  parseProductIdentityBanner,
  missingIdentityFields,
} from 'commons';

function sampleIdentity(): ProductIdentity {
  return {
    product: 'default',
    family: 'universal',
    storeChannel: false,
    publishable: false,
    developerDiagnostics: true,
    touchControls: true,
    runtimeRawMouse: true,
    capabilities: 3,
    developerBuild: true,
    testHooks: true,
    inputTrace: false,
    versionCode: 1000591,
    versionName: '1.0.3',
    deviceModel: 'MRDI-W10',
    deviceBrand: 'HUAWEI',
    osFullName: 'OpenHarmony-6.1.1.120',
    apiVersion: 24,
  };
}

export default function productIdentityTest() {
  describe('ProductIdentity', () => {

    it('formats every declared field on one line', 0, () => {
      const line: string = formatProductIdentity(sampleIdentity());
      expect(line.startsWith(PRODUCT_IDENTITY_BANNER_PREFIX)).assertTrue();
      expect(line.indexOf('\n')).assertEqual(-1);
      for (const field of PRODUCT_IDENTITY_FIELDS) {
        expect(line.indexOf(`${field}=`) >= 0).assertTrue();
      }
    });

    it('round-trips through the parser', 0, () => {
      const id: ProductIdentity = sampleIdentity();
      const parsed = parseProductIdentityBanner(formatProductIdentity(id));
      expect(parsed !== null).assertTrue();
      expect(parsed!.get('product')).assertEqual('default');
      expect(parsed!.get('capabilities')).assertEqual('3');
      expect(parsed!.get('versionCode')).assertEqual('1000591');
      expect(parsed!.get('apiVersion')).assertEqual('24');
      expect(missingIdentityFields(parsed).length).assertEqual(0);
    });

    it('encodes booleans as true/false rather than 0/1', 0, () => {
      // agent 会按值判断而不是按位置；`storeChannel=0` 与 `storeChannel=false`
      // 在字符串比较下是两回事，固定成后者。
      const line: string = formatProductIdentity(sampleIdentity());
      expect(line.indexOf('storeChannel=false') >= 0).assertTrue();
      expect(line.indexOf('developerDiagnostics=true') >= 0).assertTrue();
    });

    it('survives a device name containing spaces', 0, () => {
      // 本机机型实测无空格，但不能指望所有设备都如此：一个带空格的值会把
      // `key=value` 的切分冲垮，让后面所有字段错位。
      const id: ProductIdentity = sampleIdentity();
      id.deviceModel = 'Some Device Pro';
      const parsed = parseProductIdentityBanner(formatProductIdentity(id));
      expect(parsed !== null).assertTrue();
      expect(parsed!.get('deviceModel')).assertEqual('Some_Device_Pro');
      expect(missingIdentityFields(parsed).length).assertEqual(0);
    });

    it('writes a placeholder instead of dropping an empty value', 0, () => {
      // 空串会产生 `deviceBrand=` —— 解析出来是空值，与"字段缺失"不可区分。
      const id: ProductIdentity = sampleIdentity();
      id.deviceBrand = '';
      const parsed = parseProductIdentityBanner(formatProductIdentity(id));
      expect(parsed!.get('deviceBrand')).assertEqual('-');
      expect(missingIdentityFields(parsed).length).assertEqual(0);
    });

    it('returns null for lines that are not the banner', 0, () => {
      expect(parseProductIdentityBanner('[I][EntryAbility] Ability onCreate')).assertNull();
      expect(parseProductIdentityBanner('')).assertNull();
      expect(parseProductIdentityBanner(PRODUCT_IDENTITY_BANNER_PREFIX)).assertNull();
    });

    it('finds the banner inside a full log line', 0, () => {
      // 真实日志行前面有时间戳与 tag；判据不能要求 banner 在行首。
      const wrapped: string =
        `[2026-09-07 13:21:29][I][EntryAbility] ${formatProductIdentity(sampleIdentity())}`;
      const parsed = parseProductIdentityBanner(wrapped);
      expect(parsed !== null).assertTrue();
      expect(parsed!.get('product')).assertEqual('default');
    });

    it('reports exactly which fields are missing', 0, () => {
      // 反向：一份被截断的 banner 必须报出缺了什么，而不是"看起来解析成功了"。
      const truncated: string = `${PRODUCT_IDENTITY_BANNER_PREFIX} product=default family=universal`;
      const missing: string[] = missingIdentityFields(parseProductIdentityBanner(truncated));
      expect(missing.length).assertEqual(PRODUCT_IDENTITY_FIELDS.length - 2);
      expect(missing.indexOf('capabilities') >= 0).assertTrue();
      expect(missing.indexOf('product') >= 0).assertFalse();
    });

    it('treats a missing banner as every field missing', 0, () => {
      expect(missingIdentityFields(null).length).assertEqual(PRODUCT_IDENTITY_FIELDS.length);
    });
  });
}
