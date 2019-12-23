//
//  ThrottleSubscriber.swift
//  PusherSwift
//
//  Created by peter on 2019/10/1.
//

import Foundation

fileprivate class Throttler {
    //https://www.craftappco.com/blog/2018/5/30/simple-throttling-in-swift
    private var workItem: DispatchWorkItem = DispatchWorkItem(block: {})
    private var previousRun: Date = Date.distantPast
    private let queue: DispatchQueue
    private let minimumDelay: TimeInterval
    
    init(minimumDelay: TimeInterval, queue: DispatchQueue = DispatchQueue.main) {
        self.minimumDelay = minimumDelay
        self.queue = queue
    }
    
    func throttle(_ block: @escaping () -> Void) {
        // Cancel any existing work item if it has not yet executed
        workItem.cancel()
        
        // Re-assign workItem with the new block task, resetting the previousRun time when it executes
        workItem = DispatchWorkItem() {
            [weak self] in
            self?.updatePreviousRun()
            block()
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
    private let throttler = Throttler(minimumDelay: 1)
    weak var connection: PusherConnection? = nil
    private var candidateChannels = Set<PusherChannel>()
    private let queue = DispatchQueue(label: "ThrottleSubscriber.SafeArrayQueue", attributes: .concurrent)

    func subscribe(channelName: String) -> PusherChannel? {
        guard let connection = self.connection else { return nil }
        let newChannel = channelName.hasPrefix("presence-") ? buildPresenceChannel(channelName, connection: connection) : buildChannel(channelName, connection: connection)
        
        if channelName.hasPrefix("presence-user@") || channelName.hasPrefix("presence-client@") {
            authorizePriorityChannel(newChannel)
            return newChannel
        }
        
        if candidateChannels.count < 25 {
            queue.async(flags: .barrier) { [weak self] in
                self?.candidateChannels.insert(newChannel)
            }
            throttler.throttle { [weak self] in
                self?.authorizeIfNeeded()
            }
        } else {
            authorizeIfNeeded()
            throttler.updatePreviousRun()
        }
        
        return newChannel
    }
    
    func subscribedToChannel(name: String) {
        var channels = [PusherChannel]()
        queue.sync { 
            channels = Array(candidateChannels)
        }
        let filterChannels = channels.filter({ $0.name == name })
        if let channel = filterChannels.first {
            queue.async(flags: .barrier) { [weak self] in
                self?.candidateChannels.remove(channel)
            }
        }
    }
    
    func attemptSubscriptionsToUnsubscribedChannels() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self, let connection = self.connection else { return }
            self.candidateChannels = self.candidateChannels.union(connection.channels.list)
        }
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
        var channels = [PusherChannel]()
        queue.sync() { [weak self] in
            channels = Array(self?.candidateChannels ?? [])
        }
        if !connection.authorize(channels) {
            print("[ThrottleSubscriber] Unable to subscribe to channels")
        }
    }
    
    private func authorizePriorityChannel(_ channel: PusherChannel) {
        guard let connection = self.connection, connection.connectionState == .connected else { return }
        if !connection.authorize([channel]) {
            print("[ThrottleSubscriber] Unable to subscribe to channels")
        }
    }
}
