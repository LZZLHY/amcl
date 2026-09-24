/** Immutable distribution identity, supplied by entry before services start. */
export enum DistributionChannel {
  Unconfigured = 0,
  Sideload = 1,
  Store = 2,
}

export class DistributionPolicy {
  private static channel: DistributionChannel = DistributionChannel.Unconfigured

  static configure(channel: DistributionChannel): void {
    if (channel !== DistributionChannel.Sideload && channel !== DistributionChannel.Store) {
      throw new Error('Invalid distribution channel')
    }
    if (DistributionPolicy.channel !== DistributionChannel.Unconfigured &&
      DistributionPolicy.channel !== channel) {
      throw new Error('Distribution channel cannot change during a process')
    }
    DistributionPolicy.channel = channel
  }

  static isStore(): boolean {
    return DistributionPolicy.channel === DistributionChannel.Store
  }

  static allowSideloadUpdates(): boolean {
    return DistributionPolicy.channel === DistributionChannel.Sideload
  }

  static allowPublisherServices(): boolean {
    return DistributionPolicy.channel === DistributionChannel.Sideload
  }

  static requiresPrivacyConsent(): boolean {
    return DistributionPolicy.channel === DistributionChannel.Store
  }
}
