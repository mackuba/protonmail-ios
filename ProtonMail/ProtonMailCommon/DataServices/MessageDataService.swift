//
//  MessageDataService.swift
//  ProtonMail
//
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of ProtonMail.
//
//  ProtonMail is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonMail is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonMail.  If not, see <https://www.gnu.org/licenses/>.


import Foundation
import CoreData
import Groot
import AwaitKit
import PromiseKit


/// TODO:: global access need to be refactored //TODO::fixme
let sharedMessageDataService = MessageDataService()

/// Message data service
class MessageDataService : Service {
    
    //TODO:: those 3 var need to double check to clean up
    private let incrementalUpdateQueue = DispatchQueue(label: "ch.protonmail.incrementalUpdateQueue", attributes: [])
    private let lastUpdatedMaximumTimeInterval: TimeInterval = 24 /*hours*/ * 3600
    private let maximumCachedMessageCount = 5000
    private lazy var localNotificationService = LocalNotificationService()
    
    typealias CompletionBlock = APIService.CompletionBlock
    typealias CompletionFetchDetail = APIService.CompletionFetchDetail
    typealias ReadBlock = (() -> Void)
    
    fileprivate var readQueue: [ReadBlock] = []
    var pushNotificationMessageID : String? = nil
    
    private var managedObjectContext: NSManagedObjectContext {
        return sharedCoreDataService.mainManagedObjectContext
    }

    init() {
        setupNotifications()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    /// fetch messages with set of message id
    ///
    /// - Parameter selected: MessageIDs
    /// - Returns: fetched message obj
    func fetchMessages(withIDs selected: NSMutableSet, in context: NSManagedObjectContext? = nil) -> [Message] {
        let context = context ?? self.managedObjectContext
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: Message.Attributes.entityName)
        fetchRequest.predicate = NSPredicate(format: "%K in %@", Message.Attributes.messageID, selected)
        do {
            if let messages = try context.fetch(fetchRequest) as? [Message] {
                return messages
            }
        } catch let ex as NSError {
            PMLog.D(" error: \(ex)")
        }
        return [Message]()
    }
    
    /// mark message to unread
    ///
    /// - Parameter message: message
    /// - Returns: true if change to unread and push to the queue
    @discardableResult
    func mark( message: Message, unRead: Bool) -> Bool {
        guard let context = message.managedObjectContext else {
            return false
        }
        self.queue(message, action: unRead ? .unread : .read)
        guard message.unRead != unRead else {
            return false
        }
        message.unRead = unRead
        let error = context.saveUpstreamIfNeeded()
        if let error = error {
            PMLog.D(" error: \(error)")
            return false
        }
        self.updateCounter(markUnRead: unRead, on: message)
        return true
    }
    
    private func updateCounter(markUnRead: Bool, on message: Message) {
        let offset = markUnRead ? 1 : -1
        let labelIDs: [String] = message.getLableIDs()
        for lID in labelIDs {
            var count = lastUpdatedStore.unreadCountForKey(lID)
            count = count + offset
            if count < 0 {
                count = 0
            }
            lastUpdatedStore.updateUnreadCountForKey(lID, count: count)
        }
    }
    @discardableResult
    func label(message: Message, label: String, apply: Bool) -> Bool {
        guard let context = message.managedObjectContext else {
            return false
        }
        if apply {
            if message.add(labelID: label) != nil && message.unRead {
                self.updateCounter(plus: true, with: label)
            }
        } else {
            if message.remove(labelID: label) != nil && message.unRead {
                self.updateCounter(plus: false, with: label)
            }
        }
        let error = context.saveUpstreamIfNeeded()
        if let error = error {
            PMLog.D(" error: \(error)")
            return false
        }
        self.queue(message, action: apply ? .label : .unlabel, data1: label)
        return true
    }
    
    func updateCounter(plus: Bool, with labelID: String) {
        let offset = plus ? 1 : -1
        var count = lastUpdatedStore.unreadCountForKey(labelID)
        count = count + offset
        if count < 0 {
            count = 0
        }
        lastUpdatedStore.updateUnreadCountForKey(labelID, count: count)
    }

    @discardableResult
    func move(message: Message, from fLabel: String, to tLabel: String, queue: Bool = true) -> Bool {
        guard let context = message.managedObjectContext else {
            return false
        }
        if let lid = message.remove(labelID: fLabel), message.unRead {
            self.updateCounter(plus: false, with: lid)
            if let id = message.selfSent(labelID: lid) {
                self.updateCounter(plus: false, with: id)
            }
        }
        if let lid = message.add(labelID: tLabel) {
            //if move to trash. clean lables.
            var labelsFound = message.getNormalLableIDs()
            labelsFound.append(Message.Location.starred.rawValue)
            labelsFound.append(Message.Location.allmail.rawValue)
            if lid == Message.Location.trash.rawValue {
                self.remove(labels: labelsFound, on: message, cleanUnread: true)
                message.unRead = false
            }
            if lid == Message.Location.spam.rawValue {
                self.remove(labels: labelsFound, on: message, cleanUnread: false)
            }
            
            if message.unRead {
                self.updateCounter(plus: true, with: lid)
                if let id = message.selfSent(labelID: lid) {
                    self.updateCounter(plus: true, with: id)
                }
            }
        }
        
        let error = context.saveUpstreamIfNeeded()
        if let error = error {
            PMLog.D(" error: \(error)")
            return false
        }
        
        if queue {
            self.queue(message, action: .folder, data1: fLabel, data2: tLabel)
        }
        return true
    }
    
    private func remove(labels: [String], on message: Message, cleanUnread: Bool) {
        let unread = cleanUnread ? message.unRead : cleanUnread
        for label in labels {
            if let lid = message.remove(labelID: label), unread {
                self.updateCounter(plus: false, with: lid)
                if let id = message.selfSent(labelID: lid) {
                    self.updateCounter(plus: false, with: id)
                }
            }
        }
    }
    
    @discardableResult
    func delete(message: Message, label: String) -> Bool {
        guard let context = message.managedObjectContext else {
            return false
        }
        
        self.queue(message, action: .delete)
        
        if let lid = message.remove(labelID: label), message.unRead {
            self.updateCounter(plus: false, with: lid)
            if let id = message.selfSent(labelID: lid) {
                self.updateCounter(plus: false, with: id)
            }
        }
        var labelsFound = message.getNormalLableIDs()
        labelsFound.append(Message.Location.starred.rawValue)
        labelsFound.append(Message.Location.allmail.rawValue)
        self.remove(labels: labelsFound, on: message, cleanUnread: true)
        let labelObjs = message.mutableSetValue(forKey: "labels")
        labelObjs.removeAllObjects()
        message.setValue(labelObjs, forKey: "labels")
        context.delete(message)
        
        let error = context.saveUpstreamIfNeeded()
        if let error = error {
            PMLog.D(" error: \(error)")
            return false
        }
        return true
    }
    
    // MAKR : upload attachment
    
    /// MARK -- Refactored functions
    
    ///  nonmaly fetching the message from server based on label and time. //TODO:: change to promise
    ///
    /// - Parameters:
    ///   - labelID: labelid, location id, forlder id
    ///   - time: the latest update time
    ///   - forceClean: force clean the exsition messages first
    ///   - completion: aync complete handler
    func fetchMessages(byLable labelID : String, time: Int, forceClean: Bool, completion: CompletionBlock?) {
        queue {
            let completionWrapper: CompletionBlock = { task, responseDict, error in
                if let messagesArray = responseDict?["Messages"] as? [[String : Any]] {
                    PMLog.D("\(messagesArray)")
                    let messcount = responseDict?["Total"] as? Int ?? 0
                    let context = sharedCoreDataService.backgroundManagedObjectContext
                    context.perform() {
                        do {
                            if let messages = try GRTJSONSerialization.objects(withEntityName: Message.Attributes.entityName, fromJSONArray: messagesArray, in: context) as? [Message] {
                                for message in messages {
                                    // the matedata set, mark the status
                                    message.messageStatus = 1
                                }
                                if let error = context.saveUpstreamIfNeeded() {
                                    PMLog.D(" error: \(error)")
                                }
                                if let lastMsg = messages.last, let firstMsg = messages.first {
                                    let updateTime = lastUpdatedStore.labelsLastForKey(labelID)
                                    if (updateTime.isNew) {
                                        updateTime.start = firstMsg.time!
                                        updateTime.total = Int32(messcount)
                                    }
                                    if let time = lastMsg.time {
                                        updateTime.end = time
                                    }
                                    updateTime.update = Date()
                                    lastUpdatedStore.updateLabelsForKey(labelID, updateTime: updateTime)
                                }
                                
                                //fetch inbox count
                                if labelID == Message.Location.inbox.rawValue {
                                    let counterApi = MessageCount()
                                    counterApi.call({ (task, response, hasError) in
                                        if !hasError {
                                            self.processEvents(counts: response?.counts)
                                        }
                                    })
                                }
                                
                                DispatchQueue.main.async {
                                    completion?(task, responseDict, error)
                                }
                            }
                            DispatchQueue.main.async {
                                completion?(task, responseDict, error)
                            }
                        } catch let ex as NSError {
                            PMLog.D("error: \(ex)")
                            DispatchQueue.main.async {
                                completion?(task, responseDict, ex)
                            }
                        }
                    }
                } else {
                    completion?(task, responseDict, NSError.unableToParseResponse(responseDict))
                }
            }

            let request = FetchMessagesByLabel(labelID: labelID, endTime: time)
            sharedAPIService.GET(request, completion: completionWrapper)
        }
    }
    
    
    /// fetching the message from server based on label and time also reset the events status //TODO:: change to promise
    ///
    /// - Parameters:
    ///   - labelID: labelid, location id, forlder id
    ///   - time: the latest update time
    ///   - completion: async complete handler
    func fetchMessagesWithReset(byLabel labelID: String, time: Int, completion: CompletionBlock?) {
        queue {
            let getLatestEventID = EventLatestIDRequest<EventLatestIDResponse>()
            getLatestEventID.call() { task, _IDRes, hasIDError in
                if let IDRes = _IDRes, !hasIDError && !IDRes.eventID.isEmpty {
                    let completionWrapper: CompletionBlock = { task, responseDict, error in
                        if error == nil {
                            lastUpdatedStore.clear()
                            lastUpdatedStore.lastEventID = IDRes.eventID
                        }
                        completion?(task, responseDict, error)
                    }
                    self.cleanMessage()
                    sharedContactDataService.clean()
                    self.fetchMessages(byLable: labelID, time: time, forceClean: false, completion: completionWrapper)
                    sharedContactDataService.fetchContacts(completion: nil)
                    sharedLabelsDataService.fetchLabels()
                }  else {
                    completion?(task, nil, nil)
                }
            }
        }
    }
    
    /// fetch event logs from server. sync up the cache status to latest
    ///
    /// - Parameters:
    ///   - labelID: Label/location/forlder
    ///   - notificationMessageID: the notification message
    ///   - completion: async complete handler
    func fetchEvents(byLable labelID: String, notificationMessageID : String?, completion: CompletionBlock?) {
        queue {
            let eventAPI = EventCheckRequest(eventID: lastUpdatedStore.lastEventID)
            eventAPI.call() { task, response, hasError in
                if let eventsRes = response {
                    if eventsRes.refresh.contains(.all) || eventsRes.refresh.contains(.mail) || (hasError && eventsRes.code == 18001) {
                        let getLatestEventID = EventLatestIDRequest<EventLatestIDResponse>()
                        getLatestEventID.call() { task, _IDRes, hasIDError in
                            if let IDRes = _IDRes, !hasIDError && !IDRes.eventID.isEmpty {
                                let completionWrapper: CompletionBlock = { task, responseDict, error in
                                    if error == nil {
                                        lastUpdatedStore.clear()
                                        lastUpdatedStore.lastEventID = IDRes.eventID
                                    }
                                    completion?(task, responseDict, error)
                                }
                                self.cleanMessage()
                                sharedContactDataService.clean()
                                self.fetchMessages(byLable: labelID, time: 0, forceClean: false, completion: completionWrapper)
                                sharedContactDataService.fetchContacts(completion: nil)
                                sharedLabelsDataService.fetchLabels()
                            } else {
                                completion?(task, nil, nil)
                            }
                        }
                    } else if eventsRes.refresh.contains(.contacts) {
                        sharedContactDataService.clean()
                        sharedContactDataService.fetchContacts(completion: nil)
                    } else if let messageEvents = eventsRes.messages {
                        self.processEvents(messages: messageEvents, notificationMessageID: notificationMessageID, task: task) { task, res, error in
                            if error == nil {
                                lastUpdatedStore.lastEventID = eventsRes.eventID
                                self.processEvents(contacts: eventsRes.contacts)
                                self.processEvents(contactEmails: eventsRes.contactEmails)
                                self.processEvents(labels: eventsRes.labels)
                                self.processEvents(user: eventsRes.user)
                                self.processEvents(userSettings: eventsRes.userSettings)
                                self.processEvents(mailSettings: eventsRes.mailSettings)
                                self.processEvents(addresses: eventsRes.addresses)
                                self.processEvents(counts: eventsRes.messageCounts)
                                self.processEvents(space: eventsRes.usedSpace)
                                
                                var outMessages : [Any] = []
                                for message in messageEvents {
                                    let msg = MessageEvent(event: message)
                                    if msg.Action == 1 {
                                        outMessages.append(msg)
                                    }
                                }
                                completion?(task, ["Messages": outMessages, "Notices": eventsRes.notices ?? [String](), "More" : eventsRes.more], nil)
                            }
                            else {
                                completion?(task, nil, error)
                            }
                        }
                    } else {
                        if eventsRes.code == 1000 {
                            lastUpdatedStore.lastEventID = eventsRes.eventID
                            self.processEvents(contacts: eventsRes.contacts)
                            self.processEvents(contactEmails: eventsRes.contactEmails)
                            self.processEvents(labels: eventsRes.labels)
                            self.processEvents(user: eventsRes.user)
                            self.processEvents(userSettings: eventsRes.userSettings)
                            self.processEvents(mailSettings: eventsRes.mailSettings)
                            self.processEvents(addresses: eventsRes.addresses)
                            self.processEvents(counts: eventsRes.messageCounts)
                            self.processEvents(space: eventsRes.usedSpace)
                        }
                        if hasError {
                            completion?(task, nil, eventsRes.error)
                        } else {
                            completion?(task, ["Notices": eventsRes.notices ?? [String](), "More" : eventsRes.more], nil)
                        }
                    }
                } else {
                    completion?(task, nil, nil)
                }
            }
        }
    }
    
    
    /// upload attachment to server
    ///
    /// - Parameter att: Attachment
    func upload( att : Attachment) {
        let context = sharedCoreDataService.mainManagedObjectContext
        if let error = context.saveUpstreamIfNeeded() {
            PMLog.D("error: \(error)")
            self.dequeueIfNeeded()
        } else {
            self.queue(att, action: .uploadAtt)
        }
    }
    
    /// upload attachment to server
    ///
    /// - Parameter att: Attachment
    func upload( pubKey : Attachment) {
        let context = sharedCoreDataService.mainManagedObjectContext
        if let error = context.saveUpstreamIfNeeded() {
            PMLog.D("error: \(error)")
            self.dequeueIfNeeded()
        } else {
            self.queue(pubKey, action: .uploadPubkey)
        }
    }
    
    /// delete attachment from server
    ///
    /// - Parameter att: Attachment
    func delete(att: Attachment!) {
        let attachmentID = att.attachmentID
        let context = sharedCoreDataService.mainManagedObjectContext 
        context.delete(att)
        if let error = context.saveUpstreamIfNeeded() {
            PMLog.D(" error: \(error)")
        }
        let _ = sharedMessageQueue.addMessage(attachmentID, action: .deleteAtt)
        dequeueIfNeeded()
    }
    
    // MARK : Send message
    func send(inQueue messageID : String!, completion: CompletionBlock?) {
        var error: NSError?
        let context = sharedCoreDataService.mainManagedObjectContext

        if let message = Message.messageForMessageID(messageID, inManagedObjectContext: context) {
            self.localNotificationService.scheduleMessageSendingFailedNotification(.init(messageID: messageID, subtitle: message.title))
            
            //message.location = .outbox
            error = context.saveUpstreamIfNeeded()
            if error != nil {
                PMLog.D(" error: \(String(describing: error))")
            } else {
                self.queue(message, action: .send)
            }
        } else {
            //TODO:: handle can't find the message error.
        }
        
        completion?(nil, nil, error)
    }

    func updateMessageCount() {
        queue {
            let counterApi = MessageCount()
            counterApi.call({ (task, response, hasError) in
                if !hasError {
                    self.processEvents(counts: response?.counts)
                }
            })
        }
    }
    
    
    func messageFromPush() -> Message? {
        guard let msgID = self.pushNotificationMessageID else {
            return nil
        }
        let context = self.managedObjectContext
        guard let message = Message.messageForMessageID(msgID, inManagedObjectContext: context) else {
            return nil
        }
        return message
    }
    
    
    ///TODO::fixme - double check it  // this way is a little bit hacky. future we will prebuild the send message body
    func injectTransientValuesIntoMessages() {
        let ids = sharedMessageQueue.queuedMessageIds()
        let context = sharedCoreDataService.mainManagedObjectContext
        context.performAndWait {
            ids.forEach { messageID in
                guard let objectID = sharedCoreDataService.managedObjectIDForURIRepresentation(messageID),
                    let managedObject = try? context.existingObject(with: objectID) else
                {
                    return
                }
                if let message = managedObject as? Message {
                    self.cachePropertiesForBackground(in: message)
                }
                if let attachment = managedObject as? Attachment {
                    self.cachePropertiesForBackground(in: attachment.message)
                }
            }
        }
    }
    
    //// only needed for drafts
    private func cachePropertiesForBackground(in message: Message) {
        // these cached objects will allow us to update the draft, upload attachment and send the message after the mainKey will be locked
        // they are transient and will not be persisted in the db, only in managed object context
        message.cachedPassphrase = sharedUserDataService.mailboxPassword
        message.cachedAuthCredential = AuthCredential.fetchFromKeychain()
        message.cachedUser = sharedUserDataService.userInfo
        message.cachedAddress = message.defaultAddress // computed property depending on current user settings
    }
    
    
    //
    func empty(location: Message.Location) {
        self.empty(labelID: location.rawValue)
    }
    
    func empty(labelID: String) {
        if Message.delete(labelID: labelID) {
            queue(.empty, data1: labelID)
        }
    }
    
    let reportTitle = "FetchMetadata"
    /// fetch message meta data with message obj
    ///
    /// - Parameter messages: Message
    private func fetchMetadata(with messageIDs : [String]) {
        if messageIDs.count > 0 {
            queue {
                let completionWrapper: CompletionBlock = { task, responseDict, error in
                    if let messagesArray = responseDict?["Messages"] as? [[String : Any]] {
                        let context = sharedCoreDataService.backgroundManagedObjectContext
                        context.perform() {
                            do {
                                if let messages = try GRTJSONSerialization.objects(withEntityName: Message.Attributes.entityName, fromJSONArray: messagesArray, in: context) as? [Message] {
                                    for message in messages {
                                        message.messageStatus = 1
                                    }
                                    if let error = context.saveUpstreamIfNeeded() {
                                        PMLog.D("GRTJSONSerialization.mergeObjectsForEntityName saveUpstreamIfNeeded failed \(error)")
                                        error.upload(toAnalytics: self.reportTitle + "-Save")
                                    }
                                } else {
                                    BugDataService.debugReport(self.reportTitle, "insert empty", completion: nil)
                                    PMLog.D("GRTJSONSerialization.mergeObjectsForEntityName failed \(String(describing: error))")
                                }
                            } catch let err as NSError {
                                err.upload(toAnalytics: self.reportTitle + "-TryCatch")
                                PMLog.D("fetchMessagesWithIDs failed \(err)")
                            }
                        }
                    } else {
                        
                        var details = ""
                        if let err = error {
                            details = err.description
                        }
                        BugDataService.debugReport(self.reportTitle, "Can't get the response Messages -- " + details, completion: nil)
                        PMLog.D("fetchMessagesWithIDs can't get the response Messages")
                    }
                }
                
                let request = FetchMessagesByID(msgIDs: messageIDs)
                sharedAPIService.GET(request, completion: completionWrapper)
            }
        }
    }
    
    
    // old functions
    var isFirstTimeSaveAttData : Bool = false
    
    /// downloadTask returns the download task for use with UIProgressView+AFNetworking
    func fetchAttachmentForAttachment(_ attachment: Attachment,
                                      customAuthCredential: AuthCredential? = nil,
                                      downloadTask: ((URLSessionDownloadTask) -> Void)?,
                                      completion:((URLResponse?, URL?, NSError?) -> Void)?)
    {
        if attachment.downloaded, let localURL = attachment.localURL {
            completion?(nil, localURL as URL, nil)
            return
        }
        
        // TODO: check for existing download tasks and return that task rather than start a new download
        queue { () -> Void in
            if attachment.managedObjectContext != nil {
                sharedAPIService.downloadAttachment(byID: attachment.attachmentID,
                                                    destinationDirectoryURL: FileManager.default.attachmentDirectory,
                                                    customAuthCredential: customAuthCredential,
                                                    downloadTask: downloadTask,
                                                    completion: { task, fileURL, error in
                                                        var error = error
                                                        if let context = attachment.managedObjectContext {
                                                            if let fileURL = fileURL {
                                                                attachment.localURL = fileURL
                                                                if #available(iOS 12, *) {
                                                                    if !self.isFirstTimeSaveAttData {
                                                                        attachment.fileData = try? Data(contentsOf: fileURL)
                                                                    }
                                                                } else {
                                                                    attachment.fileData = try? Data(contentsOf: fileURL)
                                                                }
                                                                context.performAndWait {
                                                                    error = context.saveUpstreamIfNeeded()
                                                                    if error != nil  {
                                                                        PMLog.D(" error: \(String(describing: error))")
                                                                    }
                                                                }
                                                            }
                                                        }
                                                        completion?(task, fileURL, error)
                })
            } else {
                PMLog.D("The attachment not exist")
                completion?(nil, nil, nil)
            }
        }
    }
    
    func ForcefetchDetailForMessage(_ message: Message, completion: @escaping CompletionFetchDetail) {
        queue {
            let completionWrapper: CompletionBlock = { task, response, error in
                let context = sharedCoreDataService.backgroundManagedObjectContext
                context.perform() {
                    var error: NSError?
                    if response != nil {
                        //TODO need check the respons code
                        if var msg: [String:Any] = response?["Message"] as? [String : Any] {
                            msg.removeValue(forKey: "Location")
                            msg.removeValue(forKey: "Starred")
                            msg.removeValue(forKey: "test")
                            
                            do {
                                if message.isDetailDownloaded, let time = msg["Time"] as? TimeInterval, let oldtime = message.time?.timeIntervalSince1970 {
                                    // remote time and local time are not empty
                                    if oldtime > time {
                                        DispatchQueue.main.async {
                                            completion(task, response, Message.ObjectIDContainer(message), error)
                                        }
                                        return
                                    }
                                }
                                
                                try GRTJSONSerialization.object(withEntityName: Message.Attributes.entityName, fromJSONDictionary: msg, in: context)
                                message.isDetailDownloaded = true
                                message.messageStatus = 1
                                self.queue(message, action: .read)
                                if message.unRead {
                                    self.updateCounter(markUnRead: false, on: message)
                                }
                                message.unRead = false
                                error = context.saveUpstreamIfNeeded()
                                
                                DispatchQueue.main.async {
                                    completion(task, response, Message.ObjectIDContainer(message), error)
                                }
                            } catch let ex as NSError {
                                DispatchQueue.main.async {
                                    completion(task, response, Message.ObjectIDContainer(message), ex)
                                }
                            }
                        } else {
                            DispatchQueue.main.async {
                                completion(task, response, Message.ObjectIDContainer(message), NSError.badResponse())
                            }
                        }
                    } else {
                        error = NSError.unableToParseResponse(response)
                        DispatchQueue.main.async {
                            completion(task, response, Message.ObjectIDContainer(message), error)
                        }
                    }
                    if error != nil  {
                        PMLog.D(" error: \(String(describing: error))")
                    }
                }
            }
            sharedAPIService.messageDetail(messageID: message.messageID, completion: completionWrapper)
        }
    }
    
    func fetchMessageDetailForMessage(_ message: Message, completion: @escaping CompletionFetchDetail) {
        if !message.isDetailDownloaded {
            queue {
                let completionWrapper: CompletionBlock = { task, response, error in
                    let context = sharedCoreDataService.backgroundManagedObjectContext
                    context.perform() {
                        if response != nil {
//                            PMLog.D(response?.json(prettyPrinted: true) ?? "")
                            //TODO need check the respons code
                            //PMLog.D("\(String(describing: response))")
                            if var msg: [String : Any] = response?["Message"] as? [String : Any] {
                                msg.removeValue(forKey: "Location")
                                msg.removeValue(forKey: "Starred")
                                msg.removeValue(forKey: "test")
                                do {
                                    if let message_n = try GRTJSONSerialization.object(withEntityName: Message.Attributes.entityName, fromJSONDictionary: msg, in: context) as? Message {
                                        message_n.messageStatus = 1
                                        message_n.isDetailDownloaded = true
                                        self.queue(message, action: .read)
                                        if message_n.unRead {
                                            self.updateCounter(markUnRead: false, on: message)
                                        }
                                        message_n.unRead = false
                                        
                                        let tmpError = context.saveUpstreamIfNeeded()
                                        DispatchQueue.main.async {
                                            completion(task, response, Message.ObjectIDContainer(message_n), tmpError)
                                        }
                                    } else {
                                        DispatchQueue.main.async {
                                            completion(task, response, nil, error)
                                        }
                                    }
                                } catch let ex as NSError {
                                    DispatchQueue.main.async {
                                        completion(task, response, nil, ex)
                                    }
                                }
                            } else {
                                DispatchQueue.main.async {
                                    completion(task, response, nil, error)
                                }
                                
                            }
                        } else {
                            DispatchQueue.main.async {
                                completion(task, response, nil, error)
                            }
                        }
                    }
                }
                sharedAPIService.messageDetail(messageID: message.messageID, completion: completionWrapper)
            }
        } else {
            sharedMessageDataService.mark(message: message, unRead: false)
            DispatchQueue.main.async {
                completion(nil, nil, Message.ObjectIDContainer(message), nil)
            }
        }
    }
    
    func fetchNotificationMessageDetail(_ messageID: String, completion: @escaping CompletionFetchDetail) {
        queue {
            let completionWrapper: CompletionBlock = { task, response, error in
                DispatchQueue.main.async {
                    let context = sharedCoreDataService.backgroundManagedObjectContext
                    context.perform() {
                        if response != nil {
                            //TODO need check the respons code
                            if var msg: [String : Any] = response?["Message"] as? [String : Any] {
                                msg.removeValue(forKey: "Location")
                                msg.removeValue(forKey: "Starred")
                                msg.removeValue(forKey: "test")
                                do {
                                    if let message_out = try GRTJSONSerialization.object(withEntityName: Message.Attributes.entityName, fromJSONDictionary: msg, in: context) as? Message {
                                        message_out.messageStatus = 1
                                        message_out.isDetailDownloaded = true
                                        self.queue(message_out, action: .read)
                                        if message_out.unRead == true {
                                            message_out.unRead = false
                                            self.updateCounter(markUnRead: false, on: message_out)
                                        }
                                        let tmpError = context.saveUpstreamIfNeeded()

                                        DispatchQueue.main.async {
                                            completion(task, response, Message.ObjectIDContainer(message_out), tmpError)
                                        }
                                    }
                                } catch let ex as NSError {
                                    DispatchQueue.main.async {
                                        completion(task, response, nil, ex)
                                    }
                                }
                            } else {
                                DispatchQueue.main.async {
                                    completion(task, response, nil, NSError.badResponse())
                                }
                            }
                        } else {
                            DispatchQueue.main.async {
                                completion(task, response, nil, error)
                            }
                        }
                    }
                }
            }
            
            let context = sharedCoreDataService.backgroundManagedObjectContext
            context.performAndWait {
                if let message = Message.messageForMessageID(messageID, inManagedObjectContext: context) {
                    if message.isDetailDownloaded {
                        completion(nil, nil, Message.ObjectIDContainer(message), nil)
                    } else {
                        sharedAPIService.messageDetail(messageID: messageID, completion: completionWrapper)
                    }
                } else {
                    sharedAPIService.messageDetail(messageID: messageID, completion: completionWrapper)
                }
            }
        }
        
    }
    
    
    // MARK : fuctions for only fetch the local cache
    
    /**
     fetch the message by location from local cache
     
     :param: location message location enum
     
     :returns: NSFetchedResultsController
     */
    func fetchedResults(by labelID: String) -> NSFetchedResultsController<NSFetchRequestResult>? {
        let moc = sharedCoreDataService.mainManagedObjectContext
//        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: Message.Attributes.entityName)
        //var predicates : [NSPredicate] = [NSPredicate(format: "(ANY labels.labelID =[cd] %@) AND (%K > 0)", labelID, Message.Attributes.messageStatus)]
//        if labelID == Message.Location.sent.rawValue || labelID == Message.Location.draft.rawValue {
//            let forSent = [Message.Location.trash, Message.Location.spam, Message.Location.archive].map {
//                return NSPredicate(format:"(SUBQUERY(labels, $a, $a.labelID =[cd] %@).@count == 0)", $0.rawValue)
//            }
//            predicates.append(contentsOf: forSent)
//            predicates.append(NSPredicate(format: "(SUBQUERY(labels, $a, $a.labelID MATCHES %@ AND $a.type == 1 AND $a.exclusive == true).@count == 0)", "(?!^\\d+$)^.+$"))
//        }
        
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: Message.Attributes.entityName)
        fetchRequest.predicate = NSPredicate(format: "(ANY labels.labelID =[cd] %@) AND (%K > %d)",
                                             labelID, Message.Attributes.messageStatus, 0)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: #keyPath(Message.time), ascending: false)]
        fetchRequest.fetchBatchSize = 30
        fetchRequest.includesPropertyValues = true
        return NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: moc, sectionNameKeyPath: nil, cacheName: nil)
    }
    
    /**
     fetch the message from local cache use message id
     
     :param: messageID String
     
     :returns: NSFetchedResultsController
     */
    func fetchedMessageControllerForID(_ messageID: String) -> NSFetchedResultsController<NSFetchRequestResult>? {
        let moc = sharedCoreDataService.mainManagedObjectContext
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: Message.Attributes.entityName)
        fetchRequest.predicate = NSPredicate(format: "%K == %@", Message.Attributes.messageID, messageID)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: Message.Attributes.time, ascending: false)]
        return NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: moc, sectionNameKeyPath: nil, cacheName: nil)
    }
    
    /**
     clean up function for clean up the local cache this will be called when:
     
     1. logout.
     2. use cache version bad.
     3. when session expired.
     
     */
    func launchCleanUpIfNeeded() {
        if !sharedUserDataService.isUserCredentialStored || !userCachedStatus.isAuthCacheOk() {
            cleanUp()            
            if (!userCachedStatus.isAuthCacheOk()) {
                sharedUserDataService.clean()
                userCachedStatus.resetAuthCache()
            }
            //need add not clean the important infomation here.
        }
    }
    
    /**
     clean all the local cache data.
     when use this :
     1. logout
     2. local cache version changed
     3. hacked action detacted
     4. use wraped manully.
     */
    func cleanUp() {
        self.cleanMessage()
        
        self.localNotificationService.unscheduleAllPendingNotifications()
        
        lastUpdatedStore.clear()
        sharedMessageQueue.clear()
        sharedFailedQueue.clear()
        
        //tempary for clean contact cache
        sharedLabelsDataService.cleanUp()
        sharedContactDataService.clean() //here need move to a general data service manager
    }
    
    fileprivate func cleanMessage() {
        if #available(iOS 12, *) {
            sharedMessageDataService.isFirstTimeSaveAttData = true
        }
        
        Message.deleteAll(inContext: sharedCoreDataService.mainManagedObjectContext) // will cascadely remove appropriate Attacments also
        UIApplication.setBadge(badge: 0)
        // good opportunity to remove all temp folders (they should be empty by this moment)
        FileManager.default.cleanTemporaryDirectory()
    }
    
    func search(_ query: String, page: Int, completion: (([Message.ObjectIDContainer]?, NSError?) -> Void)?) {
        let completionWrapper: CompletionBlock = {task, response, error in
            if error != nil {
                completion?(nil, error)
            }
            
            if let messagesArray = response?["Messages"] as? [[String : Any]] {
                let context = sharedCoreDataService.backgroundManagedObjectContext
                context.perform() {
                    do {
                        if let messages = try GRTJSONSerialization.objects(withEntityName: Message.Attributes.entityName, fromJSONArray: messagesArray, in: context) as? [Message] {
                            for message in messages {
                                message.messageStatus = 1
                            }
                            if let error = context.saveUpstreamIfNeeded() {
                                PMLog.D(" error: \(error)")
                            }

                            if error != nil  {
                                PMLog.D(" error: \(String(describing: error))")
                                completion?(nil, error)
                            } else {
                                completion?(messages.map(ObjectBox.init), error)
                            }
                        } else {
                            completion?(nil, error)
                        }
                    } catch let ex as NSError {
                        PMLog.D(" error: \(ex)")
                        if let completion = completion {
                            completion(nil, ex)
                        }
                    }
                }
            }
        }
        sharedAPIService.messageSearch(query, page: page, completion: completionWrapper)
    }
    
    func saveDraft(_ message : Message!) {
        if let context = message.managedObjectContext {
            context.performAndWait {
                if let error = context.saveUpstreamIfNeeded() {
                    PMLog.D(" error: \(error)")
                } else {
                    self.queue(message, action: .saveDraft)
                }
            }
        }
    }
    
    func deleteDraft (_ message : Message!) {
        let context = sharedCoreDataService.mainManagedObjectContext
        if let error = context.saveUpstreamIfNeeded() {
            PMLog.D(" error: \(error)")
        } else {
            self.queue(message, action: .delete)
        }
    }
    
    func purgeOldMessages() {
        // need fetch status bad messages
        let context = sharedCoreDataService.backgroundManagedObjectContext
        context.performAndWait {
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: Message.Attributes.entityName)
            fetchRequest.predicate = NSPredicate(format: "%K == 0", Message.Attributes.messageStatus)
            do {
                
                if let badMessages = try context.fetch(fetchRequest) as? [Message] {
                    var badIDs : [String] = []
                    for message in badMessages {
                        badIDs.append(message.messageID)
                    }
                    self.fetchMetadata(with: badIDs)
                }
            } catch let ex as NSError {
                ex.upload(toAnalytics: "purgeOldMessages")
                PMLog.D("error : \(ex)")
            }
        }
    }
    
    // MARK : old functions
    
    fileprivate func attachmentsForMessage(_ message: Message) -> [Attachment] {
        if let all = message.attachments.allObjects as? [Attachment] {
            return all
        }
        return []
    }
    
    fileprivate func draft(save messageID: String, writeQueueUUID: UUID, completion: CompletionBlock?) {
        let context = sharedCoreDataService.mainManagedObjectContext
        context.performAndWait {
            guard let objectID = sharedCoreDataService.managedObjectIDForURIRepresentation(messageID) else {
                // error: while trying to get objectID
                let _ = sharedMessageQueue.remove(writeQueueUUID)
                self.dequeueIfNeeded()
                completion?(nil, nil, NSError.badParameter(messageID))
                return
            }
            
            do {
                guard let message = try context.existingObject(with: objectID) as? Message else {
                    // error: object is not a Message
                    let _ = sharedMessageQueue.remove(writeQueueUUID)
                    self.dequeueIfNeeded()
                    completion?(nil, nil, NSError.badParameter(messageID))
                    return
                }
                
                let completionWrapper: CompletionBlock = { task, response, error in
                    guard let mess = response else {
                        if let errmsg = error?.localizedDescription {
                            NSError.alertSavingDraftError(details: errmsg)
                        }
                        // error: response nil
                        completion?(task, nil, error)
                        return
                    }
                    
                    guard let messageID = mess["ID"] as? String else {
                        // error: not ID field in response
                        completion?(task, nil, error)
                        return
                    }
                    
                    PMLog.D("SendAttachmentDebug == finish save draft!")
                    message.messageID = messageID
                    message.isDetailDownloaded = true
                
                    var hasTemp = false
                    let attachments = message.mutableSetValue(forKey: "attachments")
                    for att in attachments {
                        if let att = att as? Attachment {
                            if att.isTemp {
                                hasTemp = true
                                context.delete(att)
                            }
                            att.keyChanged = false
                        }
                    }
                
                
                    if let subject = mess["Subject"] as? String {
                        message.title = subject
                    }
                    if let timeValue = mess["Time"] {
                        if let timeString = timeValue as? NSString {
                            let time = timeString.doubleValue as TimeInterval
                            if time != 0 {
                                message.time = time.asDate()
                            }
                        } else if let dateNumber = timeValue as? NSNumber {
                            let time = dateNumber.doubleValue as TimeInterval
                            if time != 0 {
                                message.time = time.asDate()
                            }
                        }
                    }
                
                    if let error = context.saveUpstreamIfNeeded() {
                        PMLog.D(" error: \(error)")
                    }
                
                    if hasTemp {
                        do {
                            try GRTJSONSerialization.object(withEntityName: Message.Attributes.entityName, fromJSONDictionary: mess, in: context)
                            if let save_error = context.saveUpstreamIfNeeded() {
                                PMLog.D(" error: \(save_error)")
                            }
                        } catch let exc as NSError {
                            completion?(task, response, exc)
                            return
                        }
                    }
                    completion?(task, response, error)
                }
                
                PMLog.D("SendAttachmentDebug == start save draft!")
                if message.isDetailDownloaded && message.messageID != "0" {
                    let api = UpdateDraft(message: message, authCredential: message.cachedAuthCredential)
                    api.call({ (task, response, hasError) -> Void in
                        if hasError {
                            completionWrapper(task, nil, response?.error)
                        } else {
                            completionWrapper(task, response?.message, nil)
                        }
                    })
                } else {
                    let api = CreateDraft(message: message)
                    api.call({ (task, response, hasError) -> Void in
                        if hasError {
                            completionWrapper(task, nil, response?.error)
                        } else {
                            completionWrapper(task, response?.message, nil)
                        }
                    })
                }
            } catch let ex as NSError {
                // error: context thrown trying to get Message
                let _ = sharedMessageQueue.remove(writeQueueUUID)
                self.dequeueIfNeeded()
                completion?(nil, nil, ex)
                return
            }
        }
    }
    
    
    private func uploadPubKey(_ managedObjectID: String, writeQueueUUID: UUID, completion: CompletionBlock?) {
        let context = sharedCoreDataService.mainManagedObjectContext
        guard let objectID = sharedCoreDataService.managedObjectIDForURIRepresentation(managedObjectID),
            let managedObject = try? context.existingObject(with: objectID),
            let attachment = managedObject as? Attachment else
        {
            // nothing to send, dequeue request
            let _ = sharedMessageQueue.remove(writeQueueUUID)
            self.dequeueIfNeeded()
            
            completion?(nil, nil, NSError.badParameter(managedObjectID))
            return
        }
        
        var requests : [UserEmailPubKeys] = [UserEmailPubKeys]()
        let emails = attachment.message.allEmails
        for email in emails {
            requests.append(UserEmailPubKeys(email: email, authCredential: attachment.message.cachedAuthCredential))
        }
        
        firstly { () -> Guarantee<[Result<KeysResponse>]> in
            when(resolved: requests.promises)
        }.then { results -> Promise<Bool> in
            for result in results {
                switch result {
                case .fulfilled(let value):
                    if value.recipientType == 2 {
                        return .value(true)
                    }
                default:
                    break
                }
            }
           
            return .value(false)
        }.done { attach in
            if attach {
                self.uploadAttachmentWithAttachmentID(managedObjectID, writeQueueUUID: writeQueueUUID, completion: completion)
            } else {
                context.performAndWait {
                    context.delete( managedObject)
                    let _ = context.saveUpstreamIfNeeded()
                }
                completion?(nil, nil, nil)
            }
        }.catch { (error) in
            completion?(nil, nil, error as NSError)
        }
        return
    }
    
    private func uploadAttachmentWithAttachmentID (_ managedObjectID: String, writeQueueUUID: UUID, completion: CompletionBlock?) {
        let context = sharedCoreDataService.mainManagedObjectContext
        guard let objectID = sharedCoreDataService.managedObjectIDForURIRepresentation(managedObjectID),
            let managedObject = try? context.existingObject(with: objectID),
            let attachment = managedObject as? Attachment else
        {
            // nothing to send, dequeue request
            let _ = sharedMessageQueue.remove(writeQueueUUID)
            self.dequeueIfNeeded()
        
            completion?(nil, nil, NSError.badParameter(managedObjectID))
            return
        }
        
        var params = [
            "Filename": attachment.fileName,
            "MIMEType": attachment.mimeType,
            "MessageID": attachment.message.messageID
        ]
        
        if attachment.inline() {
            params["ContentID"] = attachment.contentID()
        }
        
        let addressID = attachment.message.cachedAddress?.address_id ?? attachment.message.getAddressID
        guard let key = attachment.message.cachedAddress?.keys.first ?? sharedUserDataService.getAddressKey(address_id: addressID) else {
            completion?(nil, nil, NSError.encryptionError())
            return
        }
        
        guard let passphrase = attachment.message.cachedPassphrase ?? sharedUserDataService.mailboxPassword else {
            completion?(nil, nil, NSError.lockError())
            return
        }
        
        guard let encryptedData = attachment.encrypt(byKey: key, mailbox_pwd: passphrase),
            let keyPacket = encryptedData.keyPacket,
            let dataPacket = encryptedData.dataPacket else
        {
            completion?(nil, nil, NSError.encryptionError())
            return
        }
        
        let signed = attachment.sign(byKey: key,
                                     userKeys: attachment.message.cachedUser?.userPrivateKeys ?? sharedUserDataService.userPrivateKeys,
                                     passphrase: passphrase)
        let completionWrapper: CompletionBlock = { task, response, error in
            PMLog.D("SendAttachmentDebug == finish upload att!")
            if error == nil,
                let attDict = response?["Attachment"] as? [String : Any],
                let id = attDict["ID"] as? String
            {
                attachment.attachmentID = id
                attachment.keyPacket = keyPacket.base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0))
                attachment.fileData = nil // encrypted attachment is successfully uploaded -> no longer need it cleartext
                
                // proper headers from BE - important for inline attachments
                if let headerInfoDict = attDict["Headers"] as? Dictionary<String, String> {
                    attachment.headerInfo = "{" + headerInfoDict.compactMap { " \"\($0)\":\"\($1)\" " }.joined(separator: ",") + "}"
                }
                
                if let fileUrl = attachment.localURL,
                    let _ = try? FileManager.default.removeItem(at: fileUrl)
                {
                    attachment.localURL = nil
                }
                
                if let error = context.saveUpstreamIfNeeded() {
                    PMLog.D(" error: \(error)")
                }
            }
            completion?(task, response, error)
        }
        
        PMLog.D("SendAttachmentDebug == start upload att!")
        sharedAPIService.upload( byUrl: Constants.App.API_HOST_URL + Constants.App.API_PATH + "/attachments",
                                 parameters: params,
                                 keyPackets: keyPacket,
                                 dataPacket: dataPacket,
                                 signature: signed,
                                 headers: ["x-pm-apiversion":3],
                                 authenticated: true,
                                 customAuthCredential: attachment.message.cachedAuthCredential,
                                 completion: completionWrapper)
    }
    
    private func deleteAttachmentWithAttachmentID (_ deleteObject: String, writeQueueUUID: UUID, completion: CompletionBlock?) {
        let context = sharedCoreDataService.mainManagedObjectContext
        context.performAndWait {
            var authCredential: AuthCredential?
            if let objectID = sharedCoreDataService.managedObjectIDForURIRepresentation(deleteObject),
                let managedObject = try? context.existingObject(with: objectID),
                let attachment = managedObject as? Attachment
            {
                authCredential = attachment.message.cachedAuthCredential
            }
            let api = DeleteAttachment(attID: deleteObject, authCredential: authCredential)
            api.call({ (task, response, hasError) -> Void in
                completion?(task, nil, nil)
            })
            return
        }
    }
    
    private func messageAction(_ managedObjectIds: [String], writeQueueUUID: UUID, action: String, completion: CompletionBlock?) {
        let context = sharedCoreDataService.mainManagedObjectContext
        context.performAndWait {
            let messages = managedObjectIds.compactMap { (id: String) -> Message? in
                if let objectID = sharedCoreDataService.managedObjectIDForURIRepresentation(id),
                    let managedObject = try? context.existingObject(with: objectID)
                {
                    return managedObject as? Message
                }
                return nil
            }
            let messageIds = messages.map { $0.messageID }
            let api = MessageActionRequest(action: action, ids: messageIds)
            api.call({ (task, response, hasError) in
                completion!(task, nil, nil)
            })
        }
    }
    
    /// delete a message
    ///
    /// - Parameters:
    ///   - messageIDs: must be the real message id. becuase the message is deleted before this triggered
    ///   - writeQueueUUID: queue UID
    ///   - action: action type. should .delete here
    ///   - completion: call back
    private func messageDelete(_ messageIDs: [String], writeQueueUUID: UUID, action: String, completion: CompletionBlock?) {
        let api = MessageActionRequest(action: action, ids: messageIDs)
        api.call({ (task, response, hasError) in
            completion!(task, nil, nil)
        })
    }
    
    private func empty(at location: Message.Location, completion: CompletionBlock?) {
        //TODO:: check is label valid
        if location != .spam && location != .trash && location != .draft {
            completion?(nil, nil, nil)
            return
        }
        self.empty(labelID: location.rawValue, completion: completion)
    }
    
    private func empty(labelID: String, completion: CompletionBlock?) {
        let api = EmptyMessage(labelID: labelID)
        api.call({ (task, response, hasError) -> Void in
            completion?(task, nil, nil)
        })
    }

    private func labelMessage(_ labelID: String, messageID: String, completion: CompletionBlock?) {
        let api = ApplyLabelToMessages(labelID: labelID, messages: [messageID])
        api.call({ (task, response, hasError) -> Void in
            completion?(task, nil, response?.error)
        })
    }
    
    private func unLabelMessage(_ labelID: String, messageID: String, completion: CompletionBlock?) {
        let api = RemoveLabelFromMessages(labelID: labelID, messages: [messageID])
        api.call({ (task, response, hasError) -> Void in
            completion?(task, nil, response?.error)
        })
    }
    
    //
    struct SendStatus : OptionSet {
        let rawValue: Int
        
        static let justStart             = SendStatus(rawValue: 0)
        static let fetchEmailOK          = SendStatus(rawValue: 1 << 0)
        static let getBody               = SendStatus(rawValue: 1 << 1)
        static let updateBuilder         = SendStatus(rawValue: 1 << 2)
        static let processKeyResponse    = SendStatus(rawValue: 1 << 3)
        static let checkMimeAndPlainText = SendStatus(rawValue: 1 << 4)
        static let setAtts               = SendStatus(rawValue: 1 << 5)
        static let goNext                = SendStatus(rawValue: 1 << 6)
        static let checkMime             = SendStatus(rawValue: 1 << 7)
        static let buildMime             = SendStatus(rawValue: 1 << 8)
        static let checkPlainText        = SendStatus(rawValue: 1 << 9)
        static let buildPlainText        = SendStatus(rawValue: 1 << 10)
        static let initBuilders          = SendStatus(rawValue: 1 << 11)
        static let encodeBody            = SendStatus(rawValue: 1 << 12)
        static let buildSend             = SendStatus(rawValue: 1 << 13)
        static let sending               = SendStatus(rawValue: 1 << 14)
        static let done                  = SendStatus(rawValue: 1 << 15)
        static let doneWithError         = SendStatus(rawValue: 1 << 16)
        static let exceptionCatched      = SendStatus(rawValue: 1 << 17)
    }
    
    
    private func send(byID messageID: String, writeQueueUUID: UUID, completion: CompletionBlock?) {
        let errorBlock: CompletionBlock = { task, response, error in
            // nothing to send, dequeue request
            let _ = sharedMessageQueue.remove(writeQueueUUID)
            completion?(task, response, error)
        }
        
        let context = sharedCoreDataService.mainManagedObjectContext
        context.performAndWait {
            guard let objectID = sharedCoreDataService.managedObjectIDForURIRepresentation(messageID),
                let message = context.find(with: objectID) as? Message else
            {
                    errorBlock(nil, nil, NSError.badParameter(messageID))
                    return
            }
            
            if message.messageID.isEmpty {//
                errorBlock(nil, nil, NSError.badParameter(messageID))
                return
            }
            
            if message.managedObjectContext == nil {
                NSError.alertLocalCacheErrorToast()
                let err = RuntimeError.bad_draft.error
                Analytics.shared.recordError(err)
                errorBlock(nil, nil, err)
                return
            }
            
            //start track status here :
            var status = SendStatus.justStart
            
            let userInfo = message.cachedUser ?? sharedUserDataService.userInfo
            let userPrivKeys = userInfo?.userPrivateKeys ?? sharedUserDataService.userPrivateKeys
            let addrPrivKeys = userInfo?.addressKeys ?? sharedUserDataService.addressKeys
            let newSchema = addrPrivKeys.newSchema
            
            guard let authCredential = message.cachedAuthCredential ?? AuthCredential.fetchFromKeychain(),
                let passphrase = message.cachedPassphrase ?? sharedUserDataService.mailboxPassword,
                let addressKey = (message.cachedAddress ?? message.defaultAddress)?.keys.first else
            {
                errorBlock(nil, nil, NSError.lockError())
                return
            }

            var requests : [UserEmailPubKeys] = [UserEmailPubKeys]()
            let emails = message.allEmails
            for email in emails {
                requests.append(UserEmailPubKeys(email: email, authCredential: authCredential))
            }
            // is encrypt outside
            let isEO = !message.password.isEmpty

            // get attachment
            let attachments = self.attachmentsForMessage(message)
            
            //create builder
            let sendBuilder = SendBuilder()
            
            //build contacts if user setup key pinning
            var contacts : [PreContact] = [PreContact]()
            firstly {
                //fech addresses contact
                sharedContactDataService.fetch(byEmails: emails, context: context)
            }.then { (cs) -> Guarantee<[Result<KeysResponse>]> in
                //Debug info
                status.insert(SendStatus.fetchEmailOK)
                // fech email keys from api
                contacts.append(contentsOf: cs)
                return when(resolved: requests.promises)
            }.then { results -> Promise<SendBuilder> in
                //Debug info
                status.insert(SendStatus.getBody)
                //all prebuild errors need pop up from here
                guard let splited = try message.split(),
                    let bodyData = splited.dataPacket,
                    let keyData = splited.keyPacket,
                    let session = newSchema ?
                        try keyData.getSessionFromPubKeyPackage(userKeys: userPrivKeys,
                                                                passphrase: passphrase,
                                                                keys: addrPrivKeys) :
                        try message.getSessionKey(keys: addrPrivKeys.binPrivKeys,
                                                  passphrase: passphrase) else {
                            throw RuntimeError.cant_decrypt.error
                }
                //Debug info
                status.insert(SendStatus.updateBuilder)
                guard let key = session.key else {
                    throw RuntimeError.cant_decrypt.error
                }
                sendBuilder.update(bodyData: bodyData, bodySession: key, algo: session.algo)
                sendBuilder.set(pwd: message.password, hit: message.passwordHint)
                //Debug info
                status.insert(SendStatus.processKeyResponse)
                
                for (index, result) in results.enumerated() {
                    switch result {
                    case .fulfilled(let value):
                        let req = requests[index]
                        //check contacts have pub key or not
                        if let contact = contacts.find(email: req.email) {
                            if value.recipientType == 1 {
                                //if type is internal check is key match with contact key
                                //compare the key if doesn't match
                                sendBuilder.add(addr: PreAddress(email: req.email, pubKey: value.firstKey(), pgpKey: contact.firstPgpKey, recipintType: value.recipientType, eo: isEO, mime: false, sign: true, pgpencrypt: false, plainText: contact.plainText))
                            } else {
                                //sendBuilder.add(addr: PreAddress(email: req.email, pubKey: nil, pgpKey: contact.pgpKey, recipintType: value.recipientType, eo: isEO, mime: true))
                                sendBuilder.add(addr: PreAddress(email: req.email, pubKey: nil, pgpKey: contact.firstPgpKey, recipintType: value.recipientType, eo: isEO, mime: contact.mime, sign: contact.sign, pgpencrypt: contact.encrypt, plainText: contact.plainText))
                            }
                        } else {
                            sendBuilder.add(addr: PreAddress(email: req.email, pubKey: value.firstKey(), pgpKey: nil, recipintType: value.recipientType, eo: isEO, mime: false, sign: false, pgpencrypt: false, plainText: false))
                        }
                    case .rejected(let error):
                        throw error
                    }
                }
                //Debug info
                status.insert(SendStatus.checkMimeAndPlainText)
                if sendBuilder.hasMime || sendBuilder.hasPlainText {
                    guard let clearbody = newSchema ?
                        try message.decryptBody(keys: addrPrivKeys,
                                                userKeys: userPrivKeys,
                                                passphrase: passphrase) :
                        try message.decryptBody(keys: addrPrivKeys,
                                                passphrase: passphrase) else {
                        throw RuntimeError.cant_decrypt.error
                    }
                    sendBuilder.set(clear: clearbody)
                }
                //Debug info
                status.insert(SendStatus.setAtts)
                
                for att in attachments {
                    if att.managedObjectContext != nil {
                        if let sessionPack = newSchema ?
                            try att.getSession(userKey: userPrivKeys,
                                               keys: addrPrivKeys) :
                            try att.getSession(keys: addrPrivKeys.binPrivKeys) {
                            guard let key = sessionPack.key else {
                                continue
                            }
                            sendBuilder.add(att: PreAttachment(id: att.attachmentID,
                                                               session: key,
                                                               algo: sessionPack.algo,
                                                               att: att))
                        }
                    }
                }
                //Debug info
                status.insert(SendStatus.goNext)
                
                return .value(sendBuilder)
            }.then{ (sendbuilder) -> Promise<SendBuilder> in
                //Debug info
                status.insert(SendStatus.checkMime)
                
                if !sendBuilder.hasMime {
                    return .value(sendBuilder)
                }
                //Debug info
                status.insert(SendStatus.buildMime)
                
                //build pgp sending mime body
                return sendBuilder.buildMime(senderKey: addressKey,
                                             passphrase: passphrase,
                                             userKeys: userPrivKeys,
                                             keys: addrPrivKeys,
                                             newSchema: newSchema)
            }.then{ (sendbuilder) -> Promise<SendBuilder> in
                //Debug info
                status.insert(SendStatus.checkPlainText)
                
                if !sendBuilder.hasPlainText {
                    return .value(sendBuilder)
                }
                //Debug info
                status.insert(SendStatus.buildPlainText)
                
                //build pgp sending mime body
                return sendBuilder.buildPlainText(senderKey: addressKey,
                                                  passphrase: passphrase,
                                                  userKeys: userPrivKeys,
                                                  keys: addrPrivKeys,
                                                  newSchema: newSchema)
            } .then { sendbuilder -> Guarantee<[Result<AddressPackageBase>]> in
                //Debug info
                status.insert(SendStatus.initBuilders)
                //build address packages
                return when(resolved: sendbuilder.promises)
            }.then { results -> Promise<ApiResponse> in
                //Debug info
                status.insert(SendStatus.encodeBody)
                
                //build api request
                let encodedBody = sendBuilder.bodyDataPacket.base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0))
                var msgs = [AddressPackageBase]()
                for res in results {
                    switch res {
                    case .fulfilled(let value):
                        msgs.append(value)
                    case .rejected(let error):
                        throw error
                    }
                }
                //Debug info
                status.insert(SendStatus.buildSend)
                
                let sendApi = SendMessage(messageID: message.messageID,
                                          expirationTime: message.expirationOffset,
                                          messagePackage: msgs,
                                          body: encodedBody,
                                          clearBody: sendBuilder.clearBodyPackage, clearAtts: sendBuilder.clearAtts,
                                          mimeDataPacket: sendBuilder.mimeBody, clearMimeBody: sendBuilder.clearMimeBodyPackage,
                                          plainTextDataPacket : sendBuilder.plainBody, clearPlainTextBody : sendBuilder.clearPlainBodyPackage,
                                          authCredential: authCredential)
                //Debug info
                status.insert(SendStatus.sending)
                
                return sendApi.run()
            }.done { (res) in
                //Debug info
                status.insert(SendStatus.done)
                
                let error = res.error
                if error == nil {
                    self.localNotificationService.unscheduleMessageSendingFailedNotification(.init(messageID: message.messageID))
                    
                    //TODO::
                    if message.contains(label: .draft) {
                        if isEO {
                            if sendBuilder.outSideUser {
                                message.isEncrypted =  NSNumber(value: Message.EncryptType.outEnc.rawValue)
                            } else {
                                message.isEncrypted = NSNumber(value: Message.EncryptType.inner.rawValue)
                            }
                        } else {
                            if sendBuilder.outSideUser {
                                message.isEncrypted = NSNumber(value: Message.EncryptType.outPlain.rawValue)
                            } else {
                                message.isEncrypted = NSNumber(value: Message.EncryptType.inner.rawValue)
                            }
                        }
                        if attachments.count > 0 {
                            message.numAttachments = NSNumber(value: attachments.count)
                        }
                        //TODO::fix later 1.7
                        message.mimeType = "text/html"
                        message.unRead = false
                        message.isDetailDownloaded = false
                        if let lid = message.remove(labelID: Message.Location.draft.rawValue), message.unRead {
                            self.updateCounter(plus: false, with: lid)
                        }
                        message.add(labelID: Message.Location.sent.rawValue)
                    }
                    
                    NSError.alertMessageSentToast()
                    if let error = context.saveUpstreamIfNeeded() {
                        PMLog.D(" error: \(error)")
                    } else {
                        self.markReplyStatus(message.orginalMessageID, action: message.action)
                    }
                } else {
                    //Debug info
                    status.insert(SendStatus.doneWithError)
                    
                    if error?.code == 9001 {
                        //here need let user to show the human check.
                        sharedMessageQueue.isRequiredHumanCheck = true
                        error?.alertSentErrorToast()
                    } else if error?.code == 15198 {
                        error?.alertSentErrorToast()
                    }  else {
                        error?.alertErrorToast()
                    }
                    NSError.alertMessageSentErrorToast()
                    BugDataService.sendingIssue(title: SendingErrorTitle,
                                                bug: error?.localizedDescription ?? "unknown",
                                                status: status.rawValue,
                                                emials: emails,
                                                attCount: attachments.count)
                    // show message now
                    self.localNotificationService.scheduleMessageSendingFailedNotification(.init(messageID: message.messageID,
                                                                                                 error: "\(LocalString._message_sent_failed_desc):\n\(error!.localizedDescription)",
                                                                                                 timeInterval: 1,
                                                                                                 subtitle: message.title))
                }
                completion?(nil, nil, error)
            }.catch { (error) in
                status.insert(SendStatus.exceptionCatched)
                
                let err = error as NSError
                PMLog.D(error.localizedDescription)
                if err.code == 9001 {
                    //here need let user to show the human check.
                    sharedMessageQueue.isRequiredHumanCheck = true
                    NSError.alertMessageSentError(details: err.localizedDescription)
                } else if err.code == 15198 {
                    NSError.alertMessageSentError(details: err.localizedDescription)
                }  else {
                    NSError.alertMessageSentError(details: err.localizedDescription)
                }
                
                // show message now
                self.localNotificationService.scheduleMessageSendingFailedNotification(.init(messageID: message.messageID,
                                                                                             error: "\(LocalString._messages_sending_failed_try_again):\n\(err.localizedDescription)",
                                                                                             timeInterval: 1,
                                                                                             subtitle: message.title))
                BugDataService.sendingIssue(title: SendingErrorTitle,
                                            bug: err.localizedDescription,
                                            status: status.rawValue,
                                            emials: emails,
                                            attCount: attachments.count)
                completion?(nil, nil, err)
            }
            return
        }
    }
    
    private func markReplyStatus(_ oriMsgID : String?, action : NSNumber?) {
        
            if let originMessageID = oriMsgID {
                if let act = action {
                    if !originMessageID.isEmpty {
                        if let fetchedMessageController = self.fetchedMessageControllerForID(originMessageID) {
                            do {
                                try fetchedMessageController.performFetch()
                                if let message : Message = fetchedMessageController.fetchedObjects?.first as? Message  {
                                    //{0|1|2} // Optional, reply = 0, reply all = 1, forward = 2
                                    if act == 0 {
                                        message.replied = true
                                    } else if act == 1 {
                                        message.repliedAll = true
                                    } else if act == 2{
                                        message.forwarded = true
                                    } else {
                                        //ignore
                                    }
                                    if let context = message.managedObjectContext {
                                        if let error = context.saveUpstreamIfNeeded() {
                                            PMLog.D(" error: \(error)")
                                        }
                                    }
                                }
                            } catch {
                                PMLog.D(" error: \(error)")
                            }
                        }
                    }
                }
            }
    }
    
    // MARK: Notifications
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(MessageDataService.didSignOutNotification(_:)),
                                               name: NSNotification.Name.didSignOut,
                                               object: nil)
        // TODO: add monitoring for didBecomeActive
    }
    
    @objc fileprivate func didSignOutNotification(_ notification: Notification) {
        cleanUp()
    }
    
    // MARK: Queue
    private func writeQueueCompletionBlockForElementID(_ elementID: UUID, messageID : String, actionString : String) -> CompletionBlock {
        return { task, response, error in
            sharedMessageQueue.isInProgress = false
            if error == nil {
                if let action = MessageAction(rawValue: actionString) {
                    if action == MessageAction.delete {
                        Message.deleteMessage(messageID)
                    }
                    
                    if action == .send {
                        //after sent, clean the other actions with same messageID from write queue (save and send)
                        sharedMessageQueue.removeDoubleSent(messageID: messageID, actions: [MessageAction.saveDraft.rawValue, MessageAction.send.rawValue])
                    }
                }
                let _ = sharedMessageQueue.remove(elementID)
                self.dequeueIfNeeded()
            } else {
                PMLog.D(" error: \(String(describing: error))")
                var statusCode = 200
                var errorCode = error?.code ?? 200
                var isInternetIssue = false
                if let errorUserInfo = error?.userInfo {
                    if let detail = errorUserInfo["com.alamofire.serialization.response.error.response"] as? HTTPURLResponse {
                        statusCode = detail.statusCode
                    }
                    else {
                        if errorCode == -1009 || errorCode == -1004 || errorCode == -1001 { //internet issue
                            if errorCode == -1001 {
                                NotificationCenter.default.post(Notification(name: NSNotification.Name.reachabilityChanged, object: 0, userInfo: nil))
                            } else {
                                NotificationCenter.default.post(Notification(name: NSNotification.Name.reachabilityChanged, object: 1, userInfo: nil))
                            }
                            isInternetIssue = true
                        }
                    }
                }
                
                if (statusCode == 404)
                {
                    if  let (_, object) = sharedMessageQueue.next() {
                        if let element = object as? [String : String] {
                            let count = element["count"]
                            PMLog.D("message queue count : \(String(describing: count))")
                            let _ = sharedMessageQueue.remove(elementID)
                        }
                    }
                }
                
                //need add try times and check internet status
                if statusCode == 500 && !isInternetIssue {
                    if  let (uuid, object) = sharedMessageQueue.next() {
                        if let element = object as? [String : String] {
                            let count = element["count"]
                            PMLog.D("message queue count : \(String(describing: count))")
                            let _ = sharedFailedQueue.add(uuid, object: element as NSCoding)
                            let _ = sharedMessageQueue.remove(elementID)
                        }
                    }
                }
                
                
                
                if statusCode == 200 && errorCode == 9001 {
                    
                } else if statusCode == 200 && errorCode > 1000 {
                    let _ = sharedMessageQueue.remove(elementID)
                } else if statusCode == 200 && errorCode < 200 && !isInternetIssue {
                    let _ = sharedMessageQueue.remove(elementID)
                }
                
                if statusCode != 200 && statusCode != 404 && statusCode != 500 && !isInternetIssue {
                    //show error
                    let _ = sharedMessageQueue.remove(elementID)
                    error?.upload(toAnalytics: QueueErrorTitle)
                }
                
                if !isInternetIssue && (errorCode != NSError.authCacheLocked().code) {
                    self.dequeueIfNeeded()
                } else {
                    if !sharedMessageQueue.isBlocked && self.readQueue.count > 0 {
                        PMLog.D("left redaQueue count : \(self.readQueue.count)")
                        self.readQueue.remove(at: 0)()
                        self.dequeueIfNeeded()
                    }
                }
            }
        }
    }
    
    var dequieNotify : (() -> Void)?
    
    func backgroundFetch(notify : (() -> Void)?) {
        self.dequeueIfNeeded(notify: notify)
    }
    
    private func dequeueIfNeeded(notify : (() -> Void)? = nil) {
        
        if notify == nil {
            if sharedMessageQueue.count <= 0 && readQueue.count <= 0 {
                self.dequieNotify?()
                self.dequieNotify = nil
            }
        } else {
            self.dequieNotify = notify
        }
        
        // for label action: data1 is `to`
        // for forder action: data1 is `from`  data2 is `to`
        if let (uuid, messageID, actionString, data1, data2) = sharedMessageQueue.nextMessage() {
            PMLog.D("SendAttachmentDebug == dequeue --- \(actionString)")
            if let action = MessageAction(rawValue: actionString) {
                sharedMessageQueue.isInProgress = true
                let completeHandler = writeQueueCompletionBlockForElementID(uuid, messageID: messageID, actionString: actionString)
                switch action {
                case .saveDraft:
                    self.draft(save: messageID, writeQueueUUID: uuid, completion: completeHandler)
                case .uploadAtt:
                    self.uploadAttachmentWithAttachmentID(messageID, writeQueueUUID: uuid, completion: completeHandler)
                case .uploadPubkey:
                    self.uploadPubKey(messageID, writeQueueUUID: uuid, completion: completeHandler)
                case .deleteAtt:
                    self.deleteAttachmentWithAttachmentID(messageID, writeQueueUUID: uuid, completion: completeHandler)
                case .send:
                    self.send(byID: messageID, writeQueueUUID: uuid, completion: completeHandler)
                case .emptyTrash:   // keep this as legacy option for 2-3 releases after 1.11.12
                    self.empty(at: .trash, completion: completeHandler)
                case .emptySpam:    // keep this as legacy option for 2-3 releases after 1.11.12
                    self.empty(at: .spam, completion: completeHandler)
                case .empty:
                    self.empty(labelID: data1, completion: completeHandler)
                case .read, .unread:
                    self.messageAction([messageID], writeQueueUUID: uuid, action: actionString, completion: completeHandler)
                case .delete:
                    self.messageDelete([messageID], writeQueueUUID: uuid, action: actionString, completion: completeHandler)
                case .label:
                    self.labelMessage(data1, messageID: messageID, completion: completeHandler)
                case .unlabel:
                    self.unLabelMessage(data1, messageID: messageID, completion: completeHandler)
                case .folder:
                    //later use data 1 to handle the failure
                    self.labelMessage(data2, messageID: messageID, completion: completeHandler)
                }
            } else {
                PMLog.D(" Unsupported action \(actionString), removing from queue.")
                let _ = sharedMessageQueue.remove(uuid)
            }
        } else if !sharedMessageQueue.isBlocked && readQueue.count > 0 { //sharedMessageQueue.count == 0 &&
            readQueue.remove(at: 0)()
            dequeueIfNeeded()
        }
    }
    
    func queue(_ message: Message, action: MessageAction, data1: String = "", data2: String = "") {
        self.cachePropertiesForBackground(in: message)
        if action == .saveDraft || action == .send || action == .read || action == .unread {
            let _ = sharedMessageQueue.addMessage(message.objectID.uriRepresentation().absoluteString, action: action, data1: data1, data2: data2)
        } else {
            if message.managedObjectContext != nil && !message.messageID.isEmpty {
                let _ = sharedMessageQueue.addMessage(message.messageID, action: action, data1: data1, data2: data2)
            }
        }
        dequeueIfNeeded()
    }
    
    fileprivate func queue(_ action: MessageAction, data1: String = "", data2: String = "") {
        let _ = sharedMessageQueue.addMessage("", action: action, data1: data1, data2: data2)
        dequeueIfNeeded()
    }
    
    fileprivate func queue(_ att: Attachment, action: MessageAction, data1: String = "", data2: String = "") {
        self.cachePropertiesForBackground(in: att.message)
        let _ = sharedMessageQueue.addMessage(att.objectID.uriRepresentation().absoluteString, action: action, data1: data1, data2: data2)
        dequeueIfNeeded()
    }
    
    fileprivate func queue(_ readBlock: @escaping ReadBlock) {
        readQueue.append(readBlock)
        dequeueIfNeeded()
    }
 
    
    func cleanLocalMessageCache(_ completion: CompletionBlock?) {
        let getLatestEventID = EventLatestIDRequest<EventLatestIDResponse>()
        getLatestEventID.call() { task, response, hasError in
            if response != nil && !hasError && !response!.eventID.isEmpty {
                let completionWrapper: CompletionBlock = { task, responseDict, error in
                    if error == nil {
                        lastUpdatedStore.clear()
                        lastUpdatedStore.lastEventID = response!.eventID
                    }
                    completion?(task, nil, error)
                }

                self.cleanMessage()
                sharedContactDataService.clean()
                sharedLabelsDataService.fetchLabels()
                self.fetchMessages(byLable: Message.Location.inbox.rawValue, time: 0, forceClean: false, completion: completionWrapper)
                sharedContactDataService.fetchContacts(completion: nil)
            }
        }
    }
    
    
    // MARK: process events
    
    /**
     this function to process the event logs
     
     :param: messages   the message event log
     :param: task       NSURL session task
     :param: completion complete call back
     */
    private func processEvents(messages: [[String : Any]], notificationMessageID: String?, task: URLSessionDataTask!, completion: CompletionBlock?) {
        struct IncrementalUpdateType {
            static let delete = 0
            static let insert = 1
            static let update1 = 2
            static let update2 = 3
        }
        
        // this serial dispatch queue prevents multiple messages from appearing when an incremental update is triggered while another is in progress
        self.incrementalUpdateQueue.sync {
            let context = sharedCoreDataService.backgroundManagedObjectContext
            context.perform { () -> Void in
                var error: NSError?
                var messagesNoCache : [String] = []
                for message in messages {
                    let msg = MessageEvent(event: message)
                    switch(msg.Action) {
                    case .some(IncrementalUpdateType.delete):
                        if let messageID = msg.ID {
                            if let message = Message.messageForMessageID(messageID, inManagedObjectContext: context) {
                                let labelObjs = message.mutableSetValue(forKey: "labels")
                                labelObjs.removeAllObjects()
                                message.setValue(labelObjs, forKey: "labels")
                                context.delete(message)
                            }
                        }
                    case .some(IncrementalUpdateType.insert), .some(IncrementalUpdateType.update1), .some(IncrementalUpdateType.update2):
                        if IncrementalUpdateType.insert == msg.Action {
                            if let cachedMessage = Message.messageForMessageID(msg.ID, inManagedObjectContext: context) {
                                if !cachedMessage.contains(label: .draft) && !cachedMessage.contains(label: .sent) {
                                    continue
                                }
                            }
                            if let notify_msg_id = notificationMessageID {
                                if notify_msg_id == msg.ID {
                                    let _ = msg.message?.removeValue(forKey: "Unread")
                                }
                            }
                            msg.message?["messageStatus"] = 1
                        }
                        
                        if let lo = msg.message?["Location"] as? Int {
                            if lo == 1 { //if it is a draft
                                if let exsitMes = Message.messageForMessageID(msg.ID , inManagedObjectContext: context) {
                                    if exsitMes.messageStatus == 1 {
                                        if let subject = msg.message?["Subject"] as? String {
                                            exsitMes.title = subject
                                        }
                                        if let timeValue = msg.message?["Time"] {
                                            if let timeString = timeValue as? NSString {
                                                let time = timeString.doubleValue as TimeInterval
                                                if time != 0 {
                                                    exsitMes.time = time.asDate()
                                                }
                                            } else if let dateNumber = timeValue as? NSNumber {
                                                let time = dateNumber.doubleValue as TimeInterval
                                                if time != 0 {
                                                    exsitMes.time = time.asDate()
                                                }
                                            }
                                        }
                                        continue
                                    }
                                }
                            }
                        }
                        
                        do {
                            if let messageObject = try GRTJSONSerialization.object(withEntityName: Message.Attributes.entityName, fromJSONDictionary: msg.message ?? [String : Any](), in: context) as? Message {
                                // apply the label changes
                                if let deleted = msg.message?["LabelIDsRemoved"] as? NSArray {
                                    for delete in deleted {
                                        let labelID = delete as! String
                                        if let label = Label.labelForLableID(labelID, inManagedObjectContext: context) {
                                            let labelObjs = messageObject.mutableSetValue(forKey: "labels")
                                            if labelObjs.count > 0 {
                                                labelObjs.remove(label)
                                                messageObject.setValue(labelObjs, forKey: "labels")
                                            }
                                        }
                                        if labelID == "1" {
                                            messageObject.isDetailDownloaded = false
                                        }
                                    }
                                }
                                
                                if let added = msg.message?["LabelIDsAdded"] as? NSArray {
                                    for add in added {
                                        if let label = Label.labelForLableID(add as! String, inManagedObjectContext: context) {
                                            let labelObjs = messageObject.mutableSetValue(forKey: "labels")
                                            labelObjs.add(label)
                                            messageObject.setValue(labelObjs, forKey: "labels")
                                        }
                                    }
                                }
                                
                                if let labels = msg.message?["LabelIDs"] as? NSArray {
                                    PMLog.D("\(labels)")
                                    //TODO : add later need to know whne it is happending
                                }
                                
                                if messageObject.messageStatus == 0 {
                                    if messageObject.subject.isEmpty {
                                        messagesNoCache.append(messageObject.messageID)
                                    } else {
                                        messageObject.messageStatus = 1
                                    }
                                }
                            } else {
                                // when GRTJSONSerialization inset returns no thing
                                if let messageid = msg.message?["ID"] as? String {
                                    messagesNoCache.append(messageid)
                                }
                                PMLog.D(" case .Some(IncrementalUpdateType.insert), .Some(IncrementalUpdateType.update1), .Some(IncrementalUpdateType.update2): insert empty")
                                BugDataService.debugReport("GRTJSONSerialization Insert", "insert empty", completion: nil)
                                
                            }
                        } catch let err as NSError {
                            // when GRTJSONSerialization insert failed
                            if let messageid = msg.message?["ID"] as? String {
                                messagesNoCache.append(messageid)
                            }
                            err.upload(toAnalytics: "GRTJSONSerialization Insert")
                            PMLog.D(" error: \(err)")
                        }
                    default:
                        PMLog.D(" unknown type in message: \(message)")
                    }
                }
                
                error = context.saveUpstreamIfNeeded()
                if error != nil  {
                    error?.upload(toAnalytics: "GRTJSONSerialization Save")
                    PMLog.D(" error: \(String(describing: error))")
                }
                self.fetchMetadata(with: messagesNoCache)
                DispatchQueue.main.async {
                    completion?(task, nil, error)
                    return
                }
            }
        }
    }
    
    /// Process contacts from event logs
    ///
    /// - Parameter contacts: contact events
    private func processEvents(contacts: [[String : Any]]?) {
        if let contacts = contacts {
            let context = sharedCoreDataService.backgroundManagedObjectContext
            context.perform { () -> Void in
                for contact in contacts {
                    let contactObj = ContactEvent(event: contact)
                    switch(contactObj.action) {
                    case .delete:
                        if let contactID = contactObj.ID {
                            if let tempContact = Contact.contactForContactID(contactID, inManagedObjectContext: context) {
                                context.delete(tempContact)
                            }
                        }
                        //save it earily
                        if let error = context.saveUpstreamIfNeeded()  {
                            PMLog.D(" error: \(error)")
                        }
                    case .insert, .update:
                        do {
                            if let outContacts = try GRTJSONSerialization.objects(withEntityName: Contact.Attributes.entityName,
                                                                                  fromJSONArray: contactObj.contacts,
                                                                                  in: context) as? [Contact] {
                                for c in outContacts {
                                    c.isDownloaded = false
                                }
                            }
                        } catch let ex as NSError {
                            PMLog.D(" error: \(ex)")
                        }
                        if let error = context.saveUpstreamIfNeeded() {
                            PMLog.D(" error: \(error)")
                        }
                    default:
                        PMLog.D(" unknown type in contact: \(contact)")
                    }
                }
       
            }
        }
    }
    
    /// Process contact emails this is like metadata update
    ///
    /// - Parameter contactEmails: contact email events
    private func processEvents(contactEmails: [[String : Any]]?) {
        guard let emails = contactEmails else {
            return
        }
        
        let context = sharedCoreDataService.backgroundManagedObjectContext
        context.perform { () -> Void in
            for email in emails {
                let emailObj = EmailEvent(event: email)
                switch(emailObj.action) {
                case .delete:
                    if let emailID = emailObj.ID {
                        if let tempEmail = Email.EmailForID(emailID, inManagedObjectContext: context) {
                            context.delete(tempEmail)
                        }
                    }
                case .insert, .update:
                    do {
                        if let outContacts = try GRTJSONSerialization.objects(withEntityName: Contact.Attributes.entityName,
                                                                              fromJSONArray: emailObj.contacts,
                                                                              in: context) as? [Contact] {
                            for c in outContacts {
                                c.isDownloaded = false
                            }
                        }
                        
                    } catch let ex as NSError {
                        PMLog.D(" error: \(ex)")
                    }
                default:
                    PMLog.D(" unknown type in contact: \(email)")
                }
            }
            
            if let error = context.saveUpstreamIfNeeded()  {
                PMLog.D(" error: \(error)")
            }
        }
    }
    
    /// Process Labels include Folders and Labels.
    ///
    /// - Parameter labels: labels events
    private func processEvents(labels: [[String : Any]]?) {
        struct IncrementalUpdateType {
            static let delete = 0
            static let insert = 1
            static let update = 2
        }
        
        if let labels = labels {
            // this serial dispatch queue prevents multiple messages from appearing when an incremental update is triggered while another is in progress
            self.incrementalUpdateQueue.sync {
                let context = sharedCoreDataService.backgroundManagedObjectContext
                context.perform { () -> Void in
                    for labelEvent in labels {
                        let label = LabelEvent(event: labelEvent)
                        switch(label.Action) {
                        case .some(IncrementalUpdateType.delete):
                            if let labelID = label.ID {
                                if let dLabel = Label.labelForLableID(labelID, inManagedObjectContext: context) {
                                    context.delete(dLabel)
                                }
                            }
                        case .some(IncrementalUpdateType.insert), .some(IncrementalUpdateType.update):
                            do {
                                if let new_or_update_label = label.label {
                                    try GRTJSONSerialization.object(withEntityName: Label.Attributes.entityName, fromJSONDictionary: new_or_update_label, in: context)
                                }
                            } catch let ex as NSError {
                                PMLog.D(" error: \(ex)")
                            }
                        default:
                            PMLog.D(" unknown type in message: \(label)")
                        }
                    }
                    if let error = context.saveUpstreamIfNeeded(){
                        PMLog.D(" error: \(error)")
                    }
                }
            }
        }
    }
    
    /// Process User information
    ///
    /// - Parameter userInfo: User dict
    private func processEvents(user: [String : Any]?) {
        guard let userEvent = user else {
            return
        }
        sharedUserDataService.updateFromEvents(userInfo: userEvent)
    }
    private func processEvents(userSettings: [String : Any]?) {
        guard let userSettingEvent = userSettings else {
            return
        }
        sharedUserDataService.updateFromEvents(userSettings: userSettingEvent)
    }
    private func processEvents(mailSettings: [String : Any]?) {
        guard let mailSettingEvent = mailSettings else {
            return
        }
        sharedUserDataService.updateFromEvents(mailSettings: mailSettingEvent)
    }
    private func processEvents(addresses: [[String : Any]]?) {
        guard let addrEvents = addresses else {
            return
        }
        self.incrementalUpdateQueue.sync {
            for addrEvent in addrEvents {
                let address = AddressEvent(event: addrEvent)
                switch(address.action) {
                case .delete:
                    if let addrID = address.ID {
                        sharedUserDataService.deleteFromEvents(addressID: addrID)
                    }
                case .insert, .update1:
                    guard let addrID = address.ID, let addrDict = address.address else {
                        break
                    }
                    let addrRes = AddressesResponse()
                    addrRes.parseAddr(res: addrDict)
                    
                    guard addrRes.addresses.count == 1, let parsedAddr = addrRes.addresses.first, parsedAddr.address_id == addrID else {
                        break
                    }
                    sharedUserDataService.setFromEvents(address: parsedAddr)
                    let _ = sharedUserDataService.activeUserKeys().result
                default:
                    PMLog.D(" unknown type in message: \(address)")
                }
            }
        }
    }
    
    /// Process Message count from event logs
    ///
    /// - Parameter counts: message count dict
    private func processEvents(counts: [[String : Any]]?) {
        guard let messageCounts = counts, messageCounts.count > 0 else {
            return
        }
        
        lastUpdatedStore.resetUnreadCounts()
        for count in messageCounts {
            if let labelID = count["LabelID"] as? String {
                guard let unread = count["Unread"] as? Int else {
                    continue
                }
                lastUpdatedStore.updateUnreadCountForKey(labelID, count: unread)
            }
        }
        
        var badgeNumber = lastUpdatedStore.unreadCountForKey(Message.Location.inbox.rawValue)
        if  badgeNumber < 0 {
            badgeNumber = 0
        }
        UIApplication.setBadge(badge: badgeNumber)
    }
    
    
    private func processEvents(space usedSpace : Int64?) {
        guard let usedSpace = usedSpace else {
            return
        }
        sharedUserDataService.update(usedSpace: usedSpace)
    }
}
