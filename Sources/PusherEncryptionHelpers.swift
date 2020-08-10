import Foundation

struct PusherEncryptionHelpers {

    public static func shouldDecryptMessage(eventName: String, channelName: String?) -> Bool {
        return isEncryptedChannel(channelName: channelName) && !isPusherSystemEvent(eventName: eventName)
    }

    public static func isEncryptedChannel(channelName: String?) -> Bool {
        guard let channelName = channelName else { return false }
        return channelName.starts(with: "private-enc-") ||
            channelName.starts(with: "presence-enc-") ||
            channelName.starts(with: "private-encrypted-")
    }

    public static func isPusherSystemEvent(eventName: String) -> Bool {
        return eventName.starts(with: "pusher:") || eventName.starts(with: "pusher_internal:")
    }

}
