import testNapi from 'libentry.so'

export class EntryControlFeedbackLease {
  id: number = 0
}

class EntryControlFeedbackClient {
  id: number = 0
  onButton: (controlId: string, pressed: boolean) => void =
    (_controlId: string, _pressed: boolean): void => {}
  onHaptic: (strength: number) => void = (_strength: number): void => {}
}

let nextFeedbackLeaseId: number = 1
let activeFeedbackClient: EntryControlFeedbackClient | undefined = undefined

const brokerButtonCallback: (controlId: string, pressed: boolean) => void =
  (controlId: string, pressed: boolean): void => {
    const client: EntryControlFeedbackClient | undefined = activeFeedbackClient
    if (client !== undefined) client.onButton(controlId, pressed)
  }

const brokerHapticCallback: (strength: number) => void = (strength: number): void => {
  const client: EntryControlFeedbackClient | undefined = activeFeedbackClient
  if (client !== undefined) client.onHaptic(strength)
}

/** Latest page wins; a stale page cannot unregister the current native slots. */
export function acquireEntryControlFeedback(
  onButton: (controlId: string, pressed: boolean) => void,
  onHaptic: (strength: number) => void
): EntryControlFeedbackLease | undefined {
  const previous: EntryControlFeedbackClient | undefined = activeFeedbackClient
  const client = new EntryControlFeedbackClient()
  client.id = nextFeedbackLeaseId
  if (nextFeedbackLeaseId < 9007199254740991) nextFeedbackLeaseId++
  client.onButton = onButton
  client.onHaptic = onHaptic
  try {
    const buttonReady: boolean = testNapi.onButtonPressed(brokerButtonCallback)
    const hapticReady: boolean = testNapi.onHaptic(brokerHapticCallback)
    if (!buttonReady || !hapticReady) throw new Error('native feedback registration rejected')
  } catch (_) {
    let restored: boolean = true
    try {
      if (!testNapi.onButtonPressed(brokerButtonCallback)) restored = false
    } catch (_) { restored = false }
    try {
      if (!testNapi.onHaptic(brokerHapticCallback)) restored = false
    } catch (_) { restored = false }
    activeFeedbackClient = restored ? previous : undefined
    return undefined
  }
  activeFeedbackClient = client
  const lease = new EntryControlFeedbackLease()
  lease.id = client.id
  return lease
}

export function releaseEntryControlFeedback(lease: EntryControlFeedbackLease): boolean {
  const active: EntryControlFeedbackClient | undefined = activeFeedbackClient
  if (active === undefined || lease.id === 0 || active.id !== lease.id) return false
  activeFeedbackClient = undefined
  let cleared: boolean = true
  try { if (!testNapi.onButtonPressed()) cleared = false } catch (_) { cleared = false }
  try { if (!testNapi.onHaptic()) cleared = false } catch (_) { cleared = false }
  return cleared
}
