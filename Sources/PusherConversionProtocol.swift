//
//  PusherConversionProtocol.swift
//  PusherSwift
//
//  Created by Kory on 2020/9/4.
//

import Foundation

public protocol PusherConversionProtocol {
    var blackList: [String] { get }
    var whiteList: [String] { get }
    var encryptKey: String { get }
    func encryptChannelNameIfNeeded(_ channelName: String) -> String
    func decryptChannelNameIfNeeded(_ channelName: String) -> String
}
