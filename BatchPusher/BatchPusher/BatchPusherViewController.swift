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
    var channels = [PusherChannel]()
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
        NotificationCenter.default.addObserver(self, selector: #selector(didReceivePrivateChannelDataNotification(_:)), name: NSNotification.Name.PusherInitPrivateChannelData, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didReceivePresenceChannelDataNotification(_:)), name: NSNotification.Name.PusherInitPresenceChannelData, object: nil)

        
        let pusherClientOptions = PusherClientOptions (
            authMethod: AuthMethod.authRequestBuilder(authRequestBuilder: AuthRequestBuilder()),
            host: .cluster("ap1")
        )
        
        pusher = Pusher(key: "aad17fe8f682717df2c0", options: pusherClientOptions)

        pusher.delegate = self
        
        pusher.connect()
        
        let _ = pusher.bind({ (message: Any?) in
            if let message = message as? [String: AnyObject], let eventName = message["event"] as? String, eventName == "pusher:error" {
                if let data = message["data"] as? [String: AnyObject], let errorMessage = data["message"] as? String {
                    print("Error message: \(errorMessage)")
                }
            }
        })
        
        channels.append(pusher.subscribe("private-swag"))
        channels.append(pusher.subscribe("private-swag"))
        channels.append(pusher.subscribe("presence-client@\(deviceID)"))
        channels.append(pusher.subscribe("presence-user@57a42a779f22bb6bcc434520"))
        channels.append(pusher.subscribe("private-user@5ca18900c449bf5431d4b1e1")) //john6273

        let myChannel = pusher.subscribe("private-user@5cab00e6b56dea13e93edebb") //max9961
        
        myChannel.bind(eventName: "online", eventCallback: { (event: PusherEvent) -> Void in
            if let data: String = event.data {
                // `data` is a string that you can parse if necessary.
                print("[BIND] \(data)")
            }
        })
        myChannel.bind(eventName: "offline", eventCallback: { (event: PusherEvent) -> Void in
            if let data: String = event.data {
                // `data` is a string that you can parse if necessary.
                print("[BIND] \(data)")
            }
        })
        channels.append(myChannel)
        
        pusher.bind { [weak self](data: Any?) in
            print(data)

        }
        let deadline = DispatchTime.now() + .seconds(4)
        
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            _ = self.pusher.subscribe("private-ios")
        }
        
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
    func receivedError(error: PusherError) {
        if let code = error.code {
            print("[PUSHER] Received error: (\(code)) \(error.message)")
        } else {
            print("[PUSHER] Received error: \(error.message)")
        }
    }
    
    
    @objc func didReceivePrivateChannelDataNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        print("[PrivateChannelData]: \(userInfo)")
    }
    @objc func didReceivePresenceChannelDataNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        print("[PresenceChannelData]: \(userInfo)")
    }}


let deviceID = UUID().uuidString.lowercased()

class AuthRequestBuilder: AuthRequestBuilderProtocol {
    
    func requestFor(socketID: String, channels: [PusherChannel]) -> URLRequest? {
        let urlString = "https://api.v2.swag.live/pusher/batch-authenticate"

        var request = URLRequest(url: URL(string: urlString)!)

        request.httpMethod = "POST"
        request.addValue(deviceID, forHTTPHeaderField: "'X-Client-ID")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let jwt = "Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6IjU5MTVhOWYzIn0.eyJzdWIiOiI1N2E0MmE3NzlmMjJiYjZiY2M0MzQ1MjAiLCJpc3MiOiJhcGkuc3dhZy5saXZlIiwiYXVkIjoiYXBpLnN3YWcubGl2ZSIsImlhdCI6MTU3Nzk0ODM2MiwiZXhwIjoxNTc5MTU3OTYyLCJqdGkiOiJYZzJVeXFidXFMMjQ1QVREIiwic2NvcGVzIjpbInVwbG9hZGVyIiwic3RhdHM6cmVhZCIsImNoYXQiLCJjdXJhdG9yIl19.pWzyKoUMJSr_cJ6ypPd3VmPHAiIylDMFY9snFFKd1po"
        request.addValue(jwt, forHTTPHeaderField: "Authorization")

        let channelNames = channels.compactMap({ $0.name })

        let parameters: [String : Any] = ["socket_id": socketID, "channels":channelNames]
        let httpBody = try? JSONSerialization.data(withJSONObject: parameters, options:[])
        request.httpBody = httpBody
        return request

    }
}
