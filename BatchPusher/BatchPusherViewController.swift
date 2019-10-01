//
//  ViewController.swift
//  iOS Example
//
//  Created by Hamilton Chapman on 24/02/2015.
//  Copyright (c) 2015 Pusher. All rights reserved.
//

import UIKit
import PusherSwift

class BatchPusherViewController: UIViewController, PusherDelegate {
    var pusher: Pusher! = nil
    
    @IBAction func connectButton(_ sender: AnyObject) {
        pusher.connect()
    }
    
    @IBAction func disconnectButton(_ sender: AnyObject) {
        pusher.disconnect()
    }
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Only use your secret here for testing or if you're sure that there's
        // no security risk
        //        let pusherClientOptions = PusherClientOptions(authMethod: .inline(secret: "YOUR_APP_SECRET"))
        
        print("deviceID: \(deviceID)")
        
        let pusherClientOptions = PusherClientOptions (
            authMethod: AuthMethod.authRequestBuilder(authRequestBuilder: AuthRequestBuilder()),
            host: .cluster("ap1")
        )
        
        pusher = Pusher(key: "aad17fe8f682717df2c0", options: pusherClientOptions)
        
        //        // Use this if you want to try out your auth endpoint
        //        let optionsWithEndpoint = PusherClientOptions(
        //            authMethod: AuthMethod.authRequestBuilder(authRequestBuilder: AuthRequestBuilder())
        //        )
        //        pusher = Pusher(key: "YOUR_APP_KEY", options: optionsWithEndpoint)
        
        // Use this if you want to try out your auth endpoint (deprecated method)
        
        pusher.delegate = self
        
        pusher.connect()
        
        let _ = pusher.bind({ (message: Any?) in
            if let message = message as? [String: AnyObject], let eventName = message["event"] as? String, eventName == "pusher:error" {
                if let data = message["data"] as? [String: AnyObject], let errorMessage = data["message"] as? String {
                    print("Error message: \(errorMessage)")
                }
            }
        })
        

        _ = pusher.subscribe("private-swag")
        _ = pusher.subscribe("private-ios")

        pusher.bind { [weak self](data: Any?) in
            print(data)
            
        }
        let deadline = DispatchTime.now() + .milliseconds(4000)
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            _ = self.pusher.subscribe("presence-client@\(deviceID)")

        }
        
        
        //        let _ = chan.bind(eventName: "test-event", callback: { data in
        //            print(data)
        //            let _ = self.pusher.subscribe("presence-channel", onMemberAdded: onMemberAdded)
        //
        //            if let data = data as? [String : AnyObject] {
        //                if let testVal = data["test"] as? String {
        //                    print(testVal)
        //                }
        //            }
        //        })
        
        // triggers a client event
        //        chan.trigger(eventName: "client-test", data: ["test": "some value"])
    }
    
    // PusherDelegate methods
    
    func failedToSubscribeToChannel(name: String, response: URLResponse?, data: String?, error: NSError?) {
        print("[PUSHER] failedToSubscribeToChannel: \(name) error:\(error?.description ?? "nil")")
    }
    
    func changedConnectionState(from old: ConnectionState, to new: ConnectionState) {
        // print the old and new connection states
        print("[PUSHER] changedConnectionState: old:\(old.stringValue()) new:\(new.stringValue())")
    }
    
    func subscribedToChannel(name: String) {
        print("[PUSHER] Subscribed to \(name)")
    }
    
    func debugLog(message: String) {
        print("[PUSHER] debugLog:\(message)")
    }
}


//class AuthRequestBuilder: AuthRequestBuilderProtocol {
//    func requestFor(socketID: String, channelName: String) -> URLRequest? {
//        var request = URLRequest(url: URL(string: "http://localhost:9292/pusher/auth")!)
//        request.httpMethod = "POST"
//        request.httpBody = "socket_id=\(socketID)&channel_name=\(channelName)".data(using: String.Encoding.utf8)
//        return request
//    }
//}
let deviceID = UUID().uuidString.lowercased()

class AuthRequestBuilder: AuthRequestBuilderProtocol {

//    func requestFor(socketID: String, channelName: String) -> URLRequest? {
//        let urlString = "https://api.v2.swag.live/pusher/authenticate"
//
//        var request = URLRequest(url: URL(string: urlString)!)
//        request.httpMethod = "POST"
//        request.httpBody = "socket_id=\(socketID)&channel_name=\(channelName)".data(using: String.Encoding.utf8)
//
//        request.addValue(deviceID, forHTTPHeaderField: "'X-Client-ID")
//
//        return request
//    }
//    func requestFor(socketID: String, channelName: String) -> URLRequest? {
//        let urlString = "https://api.v2.swag.live/pusher/batch-authenticate"
//
//        var request = URLRequest(url: URL(string: urlString)!)
//        request.httpMethod = "POST"
//        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
//        request.addValue(deviceID, forHTTPHeaderField: "X-Client-ID")
//
//        let parameters: [String : Any] = ["socket_id": socketID,
//                                          "channels": [channelName]]
//        let httpBody = try? JSONSerialization.data(withJSONObject: parameters, options:[])
//        request.httpBody = httpBody
//
//        return request
//    }

    func requestFor(socketID: String, channels: [PusherChannel]) -> URLRequest? {
        let urlString = "https://api.v2.swag.live/pusher/batch-authenticate"

//        var request = PusherConnection.requestForAuthValue(from: urlString, socketId: socketID, channels: channels)
        //        request.addValue(token, forHTTPHeaderField: "Authorization")
        var request = URLRequest(url: URL(string: urlString)!)

        request.httpMethod = "POST"
        request.addValue(deviceID, forHTTPHeaderField: "'X-Client-ID")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")


        let channelNames = channels.compactMap({ $0.name })

        let parameters: [String : Any] = ["socket_id": socketID, "channels":channelNames]
        let httpBody = try? JSONSerialization.data(withJSONObject: parameters, options:[])
        request.httpBody = httpBody
        return request

    }
}
