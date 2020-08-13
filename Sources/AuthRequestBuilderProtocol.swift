import Foundation

@objc public protocol AuthRequestBuilderProtocol {
    @objc optional func requestFor(socketID: String, channelName: String) -> URLRequest?
    @objc optional func requestFor(socketID: String, channels: [PusherChannel]) -> URLRequest?
}

class AuthResultItem {
    private(set) var channel: String
    private(set) var auth: String? = nil
    private(set) var reason: String? = nil
    private(set) var channelData: [String: AnyObject]? = nil
    
    init(_ channelName: String) {
        channel = channelName
    }
    
    static func build(channel: String, payload: AnyObject) -> AuthResultItem? {
        guard let json = payload as? [String: AnyObject] else {
            return nil
        }
        let item = AuthResultItem(channel)

        let auth = json["auth"] as? String
        let reason = json["reason"] as? String
        
        if let channelDataString = json["channel_data"] as? String,
            let data = channelDataString.data(using: .utf8),
            let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
            let channelData = jsonObject as? [String: AnyObject] {
            item.channelData = channelData
        }

        item.auth = auth
        item.reason = reason
        return item
    }
    
    var userID: String? {
        channelData?["user_id"] as? String
    }
    var userInfo: [String: AnyObject]? {
        channelData?["user_info"] as? [String: AnyObject]
    }
}
