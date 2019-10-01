//
//  DebounceSubscriber.swift
//  PusherSwift
//
//  Created by peter on 2019/10/1.
//

import Foundation

class DebounceSubscriber {
    weak var connection: PusherConnection? = nil
    private var prepareChannels = Set<PusherChannel>()
    private var timeframe: TimeInterval
    private var lastAddTimeInterval: TimeInterval = Date().timeIntervalSince1970
    private var timer: Timer?
    
    init(timeframe: TimeInterval) {
        self.timeframe = timeframe
        
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self](timer) in
            self?.authorizeIfNeeded()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
        
    }
    deinit {
        timer?.invalidate()
        timer = nil
    }
    
    func subscribe(channelName: String) -> PusherChannel? {
        guard let connection = self.connection else { return nil }
        let newChannel = channelName.hasPrefix("presence-") ? buildPresenceChannel(channelName, connection: connection) : buildChannel(channelName, connection: connection)
        
        prepareChannels.insert(newChannel)
        lastAddTimeInterval = Date().timeIntervalSince1970
        authorizeIfNeeded()
        return newChannel
    }
    
    func subscribedToChannel(name: String) {
        let channels = prepareChannels.filter({ $0.name == name })
        if let channel = channels.first {
            prepareChannels.remove(channel)
        }
    }
    
    func attemptSubscriptionsToUnsubscribedChannels() {
        guard let connection = self.connection else { return }
        prepareChannels = prepareChannels.union(connection.channels.list)
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
        let current = Date().timeIntervalSince1970
        if lastAddTimeInterval + timeframe < current {
            return
        }
        
        let channels = Array(prepareChannels)
        if !connection.authorize(channels) {
            print("Unable to subscribe to channels")
        }
        
    }
    
}
