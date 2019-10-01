import Foundation

@objc public protocol AuthRequestBuilderProtocol {
    @objc optional func requestFor(socketID: String, channelName: String) -> URLRequest?
    @objc optional func requestFor(socketID: String, channels: [PusherChannel]) -> URLRequest?
}
