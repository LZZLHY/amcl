import { describe, it, expect } from '@ohos/hypium'
import { ReadOnlyLaunchPreferences, LaunchPreferenceSnapshot, copyLaunchPreferenceSnapshot, createLaunchPreferenceStores } from 'commons'

export default function preferenceSnapshotTest(): void {
  describe('Desktop immutable launch preferences', () => {
    it('missing or duplicate store snapshots fail as one transaction', 0, () => {
      const settings: LaunchPreferenceSnapshot = { name: 'amcl_settings', values: {} }
      const accounts: LaunchPreferenceSnapshot = { name: 'amcl_accounts', values: {} }
      const layout: LaunchPreferenceSnapshot = { name: 'control_layout', values: {} }
      let rejected: number = 0
      try { createLaunchPreferenceStores([settings, accounts]) } catch (_) { rejected++ }
      try { createLaunchPreferenceStores([settings, accounts, settings]) } catch (_) { rejected++ }
      expect(rejected).assertEqual(2)
      expect(createLaunchPreferenceStores([settings, accounts, layout]).size).assertEqual(3)
    })
    it('owner changes cannot mutate an already prepared game snapshot', 0, () => {
      const original: LaunchPreferenceSnapshot = { name: 'amcl_settings', values: { 'xmx': 2048, 'theme': 'dark' } }
      const game = new ReadOnlyLaunchPreferences(original)
      original.values['xmx'] = 4096
      expect(game.getSync('xmx', 0)).assertEqual(2048)
      expect(game.getSync('missing', false)).assertFalse()
    })
    it('game cannot persist or delete launcher data', 0, async () => {
      const snapshot: LaunchPreferenceSnapshot = { name: 'amcl_accounts', values: { 'account_a': 'encrypted-record' } }
      const game = new ReadOnlyLaunchPreferences(snapshot)
      let rejected: number = 0
      try { game.putSync('account_a', 'stale-token') } catch (_) { rejected++ }
      try { await game.put('account_b', 'new') } catch (_) { rejected++ }
      try { game.deleteSync('account_a') } catch (_) { rejected++ }
      expect(rejected).assertEqual(3)
      expect(game.getSync('account_a', '')).assertEqual('encrypted-record')
    })
    it('JSON round trip keeps falsy values without fallback substitution', 0, () => {
      const snapshot: LaunchPreferenceSnapshot = { name: 'amcl_settings', values: { 'zero': 0, 'off': false, 'empty': '' } }
      const restored = JSON.parse(JSON.stringify(snapshot)) as LaunchPreferenceSnapshot
      const game = new ReadOnlyLaunchPreferences(restored)
      expect(game.getSync('zero', 9)).assertEqual(0)
      expect(game.getSync('off', true)).assertFalse()
      expect(game.getSync('empty', 'fallback')).assertEqual('')
    })
    it('invalid values reject the whole snapshot', 0, () => {
      const bad = JSON.parse('{"name":"amcl_settings","values":{"ok":1,"bad":{"secret":"x"}}}') as LaunchPreferenceSnapshot
      let rejected: boolean = false
      try { copyLaunchPreferenceSnapshot(bad) } catch (_) { rejected = true }
      expect(rejected).assertTrue()
    })
  })
}
