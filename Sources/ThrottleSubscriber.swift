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
        // Cancel any existing work item if it has not yet executed
        workItem.cancel()
        
        // Re-assign workItem with the new block task, resetting the previousRun time when it executes
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
    private let queue = DispatchQueue(label: "ThrottleSubscriber.Queue", attributes: .concurrent)
    private var exponentialBackoff = ExponentialBackoff.build()
    var limit: Int = 10
    
    init() {
        let executeBlock: (() -> ())? = { [weak self] in
            self?.authorizeIfNeeded()
        }
        
        throttler.executeBlock = executeBlock
        exponentialBackoff.executeBlock = executeBlock
    }
    
    func subscribe(channelName: String) -> PusherChannel? {
        guard let connection = self.connection else { return nil }
        return criticalChannel(channelName, connection: connection) ?? nonCriticalChannel(channelName, connection: connection)
    }
    
    private func criticalChannel(_ channelName: String, connection: PusherConnection) -> PusherChannel? {
        guard channelName.hasPrefix("presence-") else { return nil }
        let channel = buildPresenceChannel(channelName, connection: connection)
        if isDuringRetry {
            insertCandidate(channel)
        } else {
            authorizePriorityChannel(channel)
        }
        return channel
    }
    
    private func nonCriticalChannel(_ channelName: String, connection: PusherConnection) -> PusherChannel? {
        guard isDuringRetry == false else { return nil }
        let channel = buildChannel(channelName, connection: connection)
        
        if fetchCandidateChannels().count < limit {
            insertCandidate(channel)
            throttler.schedule()
        } else {
            authorizeIfNeeded()
            throttler.updatePreviousRun()
        }
        return channel
    }

    private func insertCandidate(_ channel: PusherChannel) {
        queue.async(flags: .barrier) { [weak self] in
            self?.candidateChannels.insert(channel)
        }
    }
    
    private func removeCandidate(_ channel: PusherChannel) {
        queue.async(flags: .barrier) { [weak self] in
            self?.candidateChannels.remove(channel)
        }
    }
    
    private var isDuringRetry: Bool {
        return exponentialBackoff.isSchedule
    }
    
    func subscribedToChannel(name: String) {
        let channels = fetchCandidateChannels()
        let filterChannels = channels.filter({ $0.name == name })
        if let channel = filterChannels.first {
            removeCandidate(channel)
        }
        exponentialBackoff.reset()
    }
    
    func attemptSubscriptionsToUnsubscribedChannels() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self, let connection = self.connection else { return }
            self.candidateChannels = self.candidateChannels.union(connection.channels.list)
        }
    }

    func retryAndCutoffChannelWithout(prefix: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let criticalChannels = self.candidateChannels.filter({ $0.name.hasPrefix(prefix) })
            self.candidateChannels = criticalChannels
            if self.candidateChannels.count > 0 {
                self.exponentialBackoff.schedule()
            }
        }
    }
    
    //MARK: - Private Methods
    
    private func fetchCandidateChannels() -> Array<PusherChannel> {
        var channels = [PusherChannel]()
        queue.sync {
            channels = Array(candidateChannels)
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
        guard let connection = self.connection, connection.connectionState == .connected else { return }
        let channels = fetchCandidateChannels()
        if !connection.authorize(channels) {
            print("[ThrottleSubscriber] Unable to subscribe to channels")
        }
    }
    
    private func authorizePriorityChannel(_ channel: PusherChannel) {
        guard let connection = self.connection, connection.connectionState == .connected else { return }
        let channels =  Array([channel])
        if !connection.authorize(channels) {
            print("[ThrottleSubscriber] Unable to subscribe to channels")
        }
    }
}

class ExponentialBackoff {
    let initialInterval: TimeInterval
    let maxIntervalTime: TimeInterval
    let multiplier: Double
    var executeBlock: (() -> ())?
    private(set) var count: TimeInterval = 0
    private(set) var isSchedule: Bool = false

    static func build() -> ExponentialBackoff {
        return ExponentialBackoff(initialInterval: 0, maxIntervalTime: 30, multiplier: 2)
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
        guard isSchedule == false else { return }
        isSchedule.toggle()
        let interval = next()
        print("[\(Date()) schedule retry after: \(interval)]")
        DispatchQueue.main.asyncAfter(deadline: .secondsFromNow(interval)) { [weak self] in
            self?.doTask()
        }
    }
    
    private func doTask() {
        guard isSchedule == true else { return }
        isSchedule.toggle()
        executeBlock?()
    }
    
    func reset() {
        count = initialInterval
        isSchedule = false
    }
}
