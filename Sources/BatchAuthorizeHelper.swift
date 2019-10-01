//
//  BatchAuthorizeHelper.swift
//  PusherSwift
//
//  Created by peter on 2019/10/1.
//

import Foundation
import CryptoSwift

protocol ExposureAuthorisationHelper: NSObject {
    func userDataJSON() -> String
    func subscribeNormalChannel(_ channel: PusherChannel)
    func handleAuthorizeInfo(authString: String, channelData: String?, channel: PusherChannel)
    func privateChannelAuth(authValue auth: String, channel: PusherChannel)
    func presenceChannelAuth(authValue: String, channel: PusherChannel, channelData: String)
    func authorizationError(forChannel channelName: String, response: URLResponse?, data: String?, error: NSError?)
    func authorizeResponse(json: [String : AnyObject], channel: PusherChannel)
}

class BatchAuthorizeHelper {
    weak var connection: PusherConnection?
    
    private func requestForAuthValue(from endpoint: String, socketId: String, channels: [PusherChannel]) -> URLRequest {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let channelNames = channels.compactMap({ $0.name })
        let parameters: [String : Any] = ["socket_id": socketId, "channels":channelNames]
        let httpBody = try? JSONSerialization.data(withJSONObject: parameters, options:[])
        request.httpBody = httpBody
        
        return request
    }
    
    fileprivate func handleAuthProvided(_ auth: PusherAuth, channel: PusherChannel) -> Bool {
        if channel.type == .private {
            connection?.privateChannelAuth(authValue: auth.auth, channel: channel)
        } else if let channelData = auth.channelData {
            connection?.presenceChannelAuth(authValue: auth.auth, channel: channel, channelData: channelData)
        } else {
            connection?.delegate?.debugLog?(message: "[PUSHER DEBUG] Attempting to subscribe to presence channel but no channelData value provided")
            return false
        }
        
        return true
    }
    private func raiseBatchAuthError(forChannels channels: [PusherChannel], response: URLResponse?, data: String?, error: NSError?) {
        guard !channels.isEmpty else { return }
        channels.forEach { [weak self](channel) in
            self?.connection?.authorizationError(forChannel: channel.name, response: response, data: data, error: error)
        }
    }
    
    private func handleAuthorizerBatch(_ channels: [PusherChannel], authorizer: Authorizer, socketId: String) {
        guard !channels.isEmpty else { return }
        channels.forEach { (channel) in
            authorizer.fetchAuthValue(socketID: socketId, channelName: channel.name) { [weak self] authInfo in
                guard let authInfo = authInfo else {
                    print("Auth info passed to authorizer completionHandler was nil so channel subscription failed")
                    return
                }
                
                self?.connection?.handleAuthorizeInfo(authString: authInfo.auth, channelData: authInfo.channelData, channel: channel)
            }
        }
    }
    
    private func handleInlineBatchAuth(channels: [PusherChannel], secret: String) {
        guard !channels.isEmpty, let connection = connection else { return }
        channels.forEach { (channel) in
            let channelData = channel.type == .presence ? connection.userDataJSON() : ""
            
            if let auth = generateAuthForChannel(channel, secret: secret, channelData: channelData) {
                if channel.type == .private {
                    connection.privateChannelAuth(authValue: auth, channel: channel)
                } else {
                    connection.presenceChannelAuth(authValue: auth, channel: channel, channelData: channelData)
                }
            }
        }
    }
    
    private func generateAuthForChannel(_ channel: PusherChannel, secret: String, channelData: String) -> String? {
        guard let connection = connection else { return nil }
        
        let msg = channel.type == .presence ? "\(connection.socketId!):\(channel.name):\(channelData)" : "\(connection.socketId!):\(channel.name)"
        
        let secretBuff: [UInt8] = Array(secret.utf8)
        let msgBuff: [UInt8] = Array(msg.utf8)
        
        if let hmac = try? HMAC(key: secretBuff, variant: .sha256).authenticate(msgBuff) {
            let signature = Data(bytes: hmac).toHexString()
            let auth = "\(connection.key):\(signature)".lowercased()
            return auth
        }
        return nil
    }
    
    fileprivate func sendBatchAuthorisationRequest(request: URLRequest, channels: [PusherChannel]) {
        let task = connection?.URLSession.dataTask(with: request, completionHandler: { [weak self] data, response, sessionError in
            if let error = sessionError {
                self?.raiseBatchAuthError(forChannels: channels, response: nil, data: nil, error: error as NSError?)
                return
            }
            
            guard let data = data else {
                self?.raiseBatchAuthError(forChannels: channels, response: response, data: nil, error: nil)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse, (httpResponse.statusCode == 200 || httpResponse.statusCode == 201) else {
                let dataString = String(data: data, encoding: String.Encoding.utf8)
                self?.raiseBatchAuthError(forChannels: channels, response: response, data: dataString, error: nil)
                return
            }
            
            guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []), let json = jsonObject as? [String: AnyObject] else {
                self?.raiseBatchAuthError(forChannels: channels, response: response, data: nil, error: nil)
                return
            }
            print("JSON: \(json)")
            self?.handleBatchAuthResponse(json: json, channels: channels)
        })
        
        task?.resume()
        
    }
    
    fileprivate func handleBatchAuthResponse(json: [String: AnyObject], channels: [PusherChannel]) {
        
        let responseChannels = channels.compactMap({ json.keys.contains($0.name) ? $0 : nil })
        let failureChannels = Array( Set(channels).subtracting(responseChannels) )
        
        for channel in responseChannels {
            if let payload = json[channel.name] as? [String: AnyObject] {
                connection?.authorizeResponse(json: payload, channel: channel)
            }
        }
        
        raiseBatchAuthError(forChannels: failureChannels, response: nil, data: nil, error: nil)
    }
    
    func authorize(_ channels: [PusherChannel], auth: PusherAuth? = nil) -> Bool {
        guard let connection = connection else { return false }
        
        let normalChannels = channels.filter({ $0.type != .presence && $0.type != .private})
        for channel in normalChannels {
            connection.subscribeNormalChannel(channel)
        }
        
        let allChannels = Set(channels)
        let exceptNormalsSet = allChannels.subtracting(normalChannels)
        let exceptNormals = Array(exceptNormalsSet)
        
        // Don't go through normal auth flow if auth value provided
        if let auth = auth {
            exceptNormals.forEach { (channel) in
                if !handleAuthProvided(auth, channel: channel) {
                    print("Unable to subscribe to channel: \(channel.name)")
                    return
                }
            }
        }
        guard let socketId = connection.socketId else {
            print("socketId value not found. You may not be connected.")
            return false
        }
        
        switch connection.options.authMethod {
        case .noMethod:
            let errorMessage = "Authentication method required for private / presence channels but none provided."
            let error = NSError(domain: "com.pusher.PusherSwift", code: 0, userInfo: [NSLocalizedFailureReasonErrorKey: errorMessage])
            
            print(errorMessage)
            raiseBatchAuthError(forChannels: channels, response: nil, data: nil, error: error)
            return false
            
        case .endpoint(authEndpoint: let authEndpoint):
            let request = requestForAuthValue(from: authEndpoint, socketId: socketId, channels: channels)
            sendBatchAuthorisationRequest(request: request, channels: channels)
            
        case .authRequestBuilder(authRequestBuilder: let builder):
            if let request = builder.requestFor?(socketID: socketId, channels: channels) {
                sendBatchAuthorisationRequest(request: request, channels: channels)
            } else {
                let errorMessage = "Authentication request could not be built"
                let error = NSError(domain: "com.pusher.PusherSwift", code: 0, userInfo: [NSLocalizedFailureReasonErrorKey: errorMessage])
                raiseBatchAuthError(forChannels: channels, response: nil, data: nil, error: error)
                return false
            }
        case .authorizer(authorizer: let authorizer):
            handleAuthorizerBatch(channels, authorizer: authorizer, socketId: socketId)
        case .inline(secret: let secret):
            handleInlineBatchAuth(channels: exceptNormals, secret: secret)
        }
        return true
    }
    
}
