//
//  ThrottleSubscriber.swift
//  PusherSwift
//
//  Created by peter on 2019/10/1.
//

import Foundation

extension DispatchTime {
    public static func secondsFromNow(_ amount: Double) -> DispatchTime {
        return DispatchTime.now() + amount
    }
}

fileprivate class Throttler {
    //https://www.craftappco.com/blog/2018/5/30/simple-throttling-in-swift
    private var workItem: DispatchWorkItem = DispatchWorkItem(block: {})
    private var previousRun: Date = Date.distantPast
    private let queue: DispatchQueue
    private(set) var minimumDelay: TimeInterval
    var executeBlock: (() -> ())?
    
    init(minimumDelay: TimeInterval, queue: DispatchQueue = DispatchQueue.main) {
        self.minimumDelay = minimumDelay
        self.queue = queue
    }
    
    func schedule() {
        // Re-assign workItem with the new block task, resetting the previousRun time when it executes
        workItem.cancel()
        workItem = DispatchWorkItem() {
            [weak self] in
            self?.updatePreviousRun()
            self?.executeBlock?()
        }
        
        // If the time since the previous run is more than the required minimum delay
        // => execute the workItem immediately
        // else
        // => delay the workItem execution by the minimum delay time
        let delay = previousRun.timeIntervalSinceNow > minimumDelay ? 0 : minimumDelay
        queue.asyncAfter(deadline: .now() + Double(delay), execute: workItem)
    }
    func updatePreviousRun() {
        previousRun = Date()
    }
}

class ThrottleSubscriber {
    private var throttler = Throttler(minimumDelay: 1)
    weak var connection: PusherConnection? = nil
    private var candidateChannels = Set<PusherChannel>()
    private var priorityCandidateChannels = Set<PusherChannel>()
    private var failureChannels = Set<PusherChannel>()
    private let queue = DispatchQueue(label: "ThrottleSubscriber.Queue", attributes: .concurrent)
    
    /// This backoff is for authorization request backoff
    private var exponentialBackoff = ExponentialBackoff.build()
    
    /// This backoff is for channels subscription failure backoff
    private var failureExponentialBackoff = ExponentialBackoff.build()
    var limit: Int = 10
    
    init() {
        throttler.executeBlock = { [weak self] in
            self?.triggerAuthorizationFlow()
        }
        exponentialBackoff.executeBlock = { [weak self] in
            self?.triggerAuthorizationFlow()
        }
        failureExponentialBackoff.executeBlock = { [weak self] in
            self?.moveFailureChannelsToCandidate()
        }
        throttler.schedule()
    }
    
    private var backoffList: Array<PusherChannel> {
        queue.sync {
            Array(failureChannels)
        }
    }
    
    func subscribe(channelName: String) -> PusherChannel? {
        guard let connection = self.connection else { return nil }
        return criticalChannel(channelName, connection: connection) ?? nonCriticalChannel(channelName, connection: connection)
    }
    
    private func criticalChannel(_ channelName: String, connection: PusherConnection) -> PusherChannel? {
        guard channelName.hasPrefix("presence-") else { return nil }
        let channel = buildPresenceChannel(channelName, connection: connection)
        insertCandidate(channel)
        return channel
    }
    
    private func nonCriticalChannel(_ channelName: String, connection: PusherConnection) -> PusherChannel? {
        let channel = buildChannel(channelName, connection: connection)
        insertCandidate(channel)
        return channel
    }

    private func insertCandidate(_ channel: PusherChannel) {
        queue.async(flags: .barrier) { [weak self] in
            if channel.isPriority {
                self?.priorityCandidateChannels.insert(channel)
            } else {
                self?.candidateChannels.insert(channel)
            }
        }
    }
    
    private func removeCandidate(_ channel: PusherChannel) {
        queue.async(flags: .barrier) { [weak self] in
            if channel.isPriority {
                self?.priorityCandidateChannels.remove(channel)
            } else {
                self?.candidateChannels.remove(channel)
            }
        }
    }
    
    private var isDuringRetry: Bool {
        exponentialBackoff.isDuringScheduled || failureExponentialBackoff.isDuringScheduled
    }
    
    func subscribedToChannel(name: String) {
        removeExistingChannel(name)
        exponentialBackoff.reset()
        if backoffList.count == 0 {
            failureExponentialBackoff.reset()
        }
    }
    
    func unsubscribeChannel(name: String) {
        removeExistingChannel(name)
    }
    
    private func removeExistingChannel(_ name: String) {
        if let channel = allCandidateChannels().first(where: { $0.name == name }) {
            channel.authorizing = false
            removeCandidate(channel)
        }
    }
    
    func attemptSubscriptionsToUnsubscribedChannels() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self, let connection = self.connection else { return }
            for channel in connection.channels.list {
                guard channel.subscribed == false else { continue }
                if channel.isPriority {
                    self.priorityCandidateChannels.insert(channel)
                } else {
                    self.candidateChannels.insert(channel)
                }
            }
        }
    }

    func retryAuthorizingChannels() {
        if allCandidateChannels().count > 0 {
            exponentialBackoff.schedule()
        }
    }
    
    func failAuthorizationChannels(_ channels: [PusherChannel]) {
        for channel in channels {
            removeCandidate(channel)
            appendFailureChannel(channel)
        }
        failureExponentialBackoff.schedule()
    }
    
    //MARK: - Private Methods
    private func appendFailureChannel(_ channel: PusherChannel) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            channel.authorizing = false
            self.failureChannels.insert(channel)
        }
    }
    
    private func moveFailureChannelsToCandidate() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for channel in self.failureChannels {
                if channel.isPriority {
                    self.priorityCandidateChannels.insert(channel)
                } else {
                    self.candidateChannels.insert(channel)
                }
            }
            self.failureChannels.removeAll()
        }
    }

    private func allCandidateChannels() -> Array<PusherChannel> {
        var channels = [PusherChannel]()
        queue.sync {
            channels = Array(priorityCandidateChannels.union(candidateChannels))
        }
        return channels
    }
    
    private func fetchCandidateChannels() -> Array<PusherChannel> {
        var channels = [PusherChannel]()
        queue.sync {
            let combine = Array(priorityCandidateChannels.filter({$0.authorizing == false})) + Array(candidateChannels.filter({$0.authorizing == false}) )
            channels = Array(combine.prefix(limit))
        }
        return channels
    }
    
    private func buildPresenceChannel(_ channelName: String, connection: PusherConnection) -> PusherChannel {
        return connection.channels.addPresence(
            channelName: channelName,
            connection: connection,
            auth: nil,
            onMemberAdded: nil,
            onMemberRemoved: nil
        )
    }
    
    private func buildChannel(_ channelName: String, connection: PusherConnection) -> PusherChannel {
        return connection.channels.add(
            name: channelName,
            connection: connection,
            auth: nil,
            onMemberAdded: nil,
            onMemberRemoved: nil
        )
    }
    
    private func authorizeIfNeeded() {
        guard let connection = self.connection,
            connection.connectionState == .connected,
            !isDuringRetry else { return }
        let channels = fetchCandidateChannels()
        if channels.count > 0, !connection.authorize(channels) {
            print("[ThrottleSubscriber] Unable to subscribe to channels")
        }
    }
    
    private func authorizePriorityChannel(_ channel: PusherChannel) {
        guard let connection = self.connection,
            connection.connectionState == .connected,
            !isDuringRetry else { return }
        let channels = Array([channel])
        if channels.count > 0, !connection.authorize(channels) {
            print("[ThrottleSubscriber] Unable to subscribe to channels")
        }
    }
    
    /// This method is only triggerred by throttle or exponentialBackoff.
    /// Try to subscribe candidate channels in the channel pool.
    private func triggerAuthorizationFlow() {
        authorizeIfNeeded()
        throttler.schedule()
    }
}

extension PusherChannel {
    var isPriority: Bool {
        type == .presence
    }
}

class ExponentialBackoff {
    let initialInterval: TimeInterval
    let maxIntervalTime: TimeInterval
    let multiplier: Double
    var executeBlock: (() -> ())?
    private(set) var count: TimeInterval = 0
    private let queue = DispatchQueue(label: "ExponentialBackoff.queue", attributes: .concurrent)
    private var workItem: DispatchWorkItem = DispatchWorkItem(block: {})
    private var isSchedule: Bool = false
    var isDuringScheduled: Bool {
        var result: Bool = false
        queue.sync {
            result = isSchedule
        }
        return result
    }
    static func build() -> ExponentialBackoff {
        return ExponentialBackoff(initialInterval: 1, maxIntervalTime: 60, multiplier: 2)
    }
    
    init(initialInterval: TimeInterval, maxIntervalTime: TimeInterval, multiplier: Double) {
        self.initialInterval = initialInterval
        self.count = initialInterval
        self.maxIntervalTime = maxIntervalTime
        self.multiplier = multiplier
    }
    
    private func next() -> TimeInterval {
        let value = pow(multiplier, count)
        if value > maxIntervalTime {
            return maxIntervalTime
        }
        count += 1
        return value
    }
    
    func schedule() {
        guard isDuringScheduled == false else { return }
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.workItem.cancel()
            self.workItem = DispatchWorkItem() {
                self.doTask()
            }
            self.isSchedule = true
            let interval = self.next()
            print("[\(Date()) schedule retry after: \(interval)]")
            DispatchQueue.main.asyncAfter(deadline: .secondsFromNow(interval), execute: self.workItem)
        }
    }
    
    private func doTask() {
        guard isDuringScheduled == true else { return }
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.isSchedule = false
            DispatchQueue.main.async {
                self.executeBlock?()
            }
        }
    }
    
    func reset() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.workItem.cancel()
            self.count = self.initialInterval
            self.isSchedule = false
        }
    }
}
