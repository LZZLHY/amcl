import { describe, it, expect } from '@ohos/hypium'
import {
  InputSurfaceContext,
  InputSurfaceContextCandidate,
  InputSurfacePublisherLease,
  InputSurfaceContextStore,
  INPUT_SURFACE_FIELD_DENSITY,
  INPUT_SURFACE_FIELD_DISPLAY,
  INPUT_SURFACE_FIELD_RECT,
  INPUT_SURFACE_FIELD_REFRESH_RATE,
  INPUT_SURFACE_FIELD_TRANSFORM,
  INPUT_SURFACE_FIELD_WINDOW
} from 'gamecontrol'

function completeCandidate(provisional: boolean): InputSurfaceContextCandidate {
  const value = new InputSurfaceContextCandidate()
  value.windowId = 41
  value.displayId = 7
  value.leftPx = -1200
  value.topPx = 20
  value.widthPx = 1600
  value.heightPx = 900
  value.density = 2.5
  value.transform = 1
  value.refreshRateHz = 120
  value.provisional = provisional
  return value
}

function publisher(store: InputSurfaceContextStore, owner: string): InputSurfacePublisherLease {
  return store.beginPublisher(owner) ?? new InputSurfacePublisherLease()
}

export default function inputSurfaceContextTest(): void {
  describe('InputSurfaceContext', () => {
    it('normalizes a complete current-window snapshot and owns validity', 0, () => {
      const store = new InputSurfaceContextStore()
      const lease: InputSurfacePublisherLease = publisher(store, 'page-a')
      const result: InputSurfaceContext =
        store.publish(lease, completeCandidate(false)) ?? new InputSurfaceContext()
      expect(result.generation).assertEqual(1)
      expect(result.provisional).assertFalse()
      expect(result.has(INPUT_SURFACE_FIELD_WINDOW)).assertTrue()
      expect(result.has(INPUT_SURFACE_FIELD_DISPLAY)).assertTrue()
      expect(result.has(INPUT_SURFACE_FIELD_RECT)).assertTrue()
      expect(result.has(INPUT_SURFACE_FIELD_DENSITY)).assertTrue()
      expect(result.has(INPUT_SURFACE_FIELD_TRANSFORM)).assertTrue()
      expect(result.has(INPUT_SURFACE_FIELD_REFRESH_RATE)).assertTrue()
      expect(result.leftPx).assertEqual(-1200)
    })

    it('deduplicates equivalent publications but upgrades provisional authority', 0, () => {
      const store = new InputSurfaceContextStore()
      const lease: InputSurfacePublisherLease = publisher(store, 'page-a')
      const provisional: InputSurfaceContext =
        store.publish(lease, completeCandidate(true)) ?? new InputSurfaceContext()
      const duplicate: InputSurfaceContext =
        store.publish(lease, completeCandidate(true)) ?? new InputSurfaceContext()
      const authoritative: InputSurfaceContext =
        store.publish(lease, completeCandidate(false)) ?? new InputSurfaceContext()
      expect(duplicate.generation).assertEqual(provisional.generation)
      expect(authoritative.generation).assertEqual(provisional.generation + 1)
      expect(authoritative.provisional).assertFalse()
    })

    it('rejects invalid facts instead of manufacturing a usable context', 0, () => {
      const store = new InputSurfaceContextStore()
      const lease: InputSurfacePublisherLease = publisher(store, 'page-a')
      const bad = new InputSurfaceContextCandidate()
      bad.windowId = Number.NaN
      bad.displayId = Number.POSITIVE_INFINITY
      bad.widthPx = -1
      bad.heightPx = 900
      bad.density = 0
      bad.transform = 99
      bad.refreshRateHz = 1001
      bad.provisional = false
      const result: InputSurfaceContext = store.publish(lease, bad) ?? new InputSurfaceContext()
      expect(result.validFields).assertEqual(0)
      expect(result.windowId).assertEqual(0)
      expect(result.displayId).assertEqual(-1)
      expect(result.provisional).assertFalse()
    })

    it('returns defensive copies and reset always advances the epoch', 0, () => {
      const store = new InputSurfaceContextStore()
      const lease: InputSurfacePublisherLease = publisher(store, 'page-a')
      const published: InputSurfaceContext =
        store.publish(lease, completeCandidate(false)) ?? new InputSurfaceContext()
      published.widthPx = 1
      const retained: InputSurfaceContext = store.snapshot()
      expect(retained.widthPx).assertEqual(1600)
      const firstReset: InputSurfaceContext =
        store.endPublisher(lease) ?? new InputSurfaceContext()
      const secondReset: InputSurfaceContext = store.snapshot()
      expect(firstReset.generation).assertEqual(retained.generation + 1)
      expect(firstReset.provisional).assertFalse()
      expect(secondReset.generation).assertEqual(firstReset.generation)
      expect(secondReset.validFields).assertEqual(0)
    })

    it('a stale page cannot publish or reset over a newer page', 0, () => {
      const store = new InputSurfaceContextStore()
      const oldLease: InputSurfacePublisherLease = publisher(store, 'old-page')
      store.publish(oldLease, completeCandidate(false))
      const newLease: InputSurfacePublisherLease = publisher(store, 'new-page')
      const current: InputSurfaceContext =
        store.publish(newLease, completeCandidate(false)) ?? new InputSurfaceContext()
      expect(store.publish(oldLease, completeCandidate(true)) === undefined).assertTrue()
      expect(store.endPublisher(oldLease) === undefined).assertTrue()
      expect(store.snapshot().generation).assertEqual(current.generation)
      expect(store.snapshot().provisional).assertFalse()
    })
  })
}
