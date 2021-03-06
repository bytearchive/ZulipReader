//
//  StreamController.swift
//  ZulipReader
//
//  Created by Frank Tan on 11/28/15.
//  Copyright © 2015 Frank Tan. All rights reserved.
//

import Foundation
import Alamofire
import SwiftyJSON
import Locksmith
import RealmSwift

protocol StreamControllerDelegate: class {
  func didFetchMessages(messages: [[TableCell]], deletedSections: NSRange, insertedSections: NSRange, insertedRows: [NSIndexPath], userAction: UserAction)
  
  func didFetchMessages()
  
  func setNotification(notification: Notification, show: Bool)
}

protocol SubscriptionDelegate: class {
  func didFetchSubscriptions(subscriptions: [String: String])
}

class Queue {
  lazy var refreshNetworkQueue: NSOperationQueue = {
    var queue = NSOperationQueue()
    queue.name = "refreshNetworkQueue"
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
  
  lazy var userNetworkQueue: NSOperationQueue = {
    var queue = NSOperationQueue()
    queue.name = "userNetworkQueue"
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
  
  lazy var prepQueue: NSOperationQueue = {
    var queue = NSOperationQueue()
    queue.name = "prepQueue"
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
  
  func cancelAll() {
    refreshNetworkQueue.cancelAllOperations()
    userNetworkQueue.cancelAllOperations()
    prepQueue.cancelAllOperations()
  }
  
  func cancelRefreshQueue() {
    refreshNetworkQueue.cancelAllOperations()
  }
}

class StreamController {
  weak var delegate: StreamControllerDelegate?
  weak var subscriptionDelegate: SubscriptionDelegate?
  
  private let realm: Realm
  private var subscription: [String:String] = [:]
  private var oldTableCells = [[TableCell]]()
  private var refreshTimer = NSTimer()
  private let queue = Queue()
  
  private var streamMinId = [String: Int]()
  private var refreshedMessageIds = Set<Int>()
  
  //refresh needs to be aware of narrow
  private var action = Action()
  
  init() {
    do {
      realm = try Realm()
    } catch let error as NSError {
      fatalError(String(error))
    }
  }
  
  func isLoggedIn() -> Bool {
    if let basicAuth = Locksmith.loadDataForUserAccount("default"),
      let authHead = basicAuth["Authorization"] as? String {
      Router.basicAuth = authHead
      
      self.resetRefreshTimer()
      return true
    }
    return false
  }
  
  private func resetRefreshTimer() {
    self.refreshTimer.invalidate()
    self.refreshTimer = NSTimer.scheduledTimerWithTimeInterval(3.0, target: self, selector: #selector(refreshData), userInfo: nil, repeats: true)
  }
  
  //TODO: why do I need @objc?
  //new messages are loaded on refreshQueue, called by timer
  @objc private func refreshData() {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)) {
      //we don't refresh until there's something to refresh
      if !self.oldTableCells.isEmpty {
        print("\n===refreshData===")
        //a generic action is used so we don't miss any new messages
        self.action.userAction = .Refresh
        var localAction = Action()
        localAction.userAction = .Refresh
        let messagesFromNetworkOperation = self.messagesFromNetwork(localAction)
        self.queue.refreshNetworkQueue.addOperation(messagesFromNetworkOperation)
      }
    }
  }
  
  //logout
  func clearData() {
    queue.cancelAll()
    refreshTimer.invalidate()
    for key in NSUserDefaults.standardUserDefaults().dictionaryRepresentation().keys {
      NSUserDefaults.standardUserDefaults().removeObjectForKey(key)
    }
    do {
      try realm.write {
        print("clearDefaults: deleting realm")
        realm.deleteAll()
      }
    }
    catch{print("could not clear realm")}
    print("clearDefaults: deleting keychain")
    do {
      try Locksmith.deleteDataForUserAccount("default")
    }
    catch {print("unable to clear locksmith")}
    Router.basicAuth = nil
  }
  
  func register() {
    let registration = RegistrationOperation()
    registration.completionBlock = {
      dispatch_async(dispatch_get_main_queue()) {
        let registrationResults = registration.getSubscriptionAndMaxID()
        self.subscription = registrationResults.0
        NSUserDefaults.standardUserDefaults().setInteger(registrationResults.1, forKey: "homeMax")
        self.subscriptionDelegate?.didFetchSubscriptions(self.subscription)
        self.loadStreamMessages(Action())
      }
    }
    queue.userNetworkQueue.addOperation(registration)
  }
  
  //Post Messages
  func postMessage(message: MessagePost, action: Action) {
    self.action = action
    createPostRequest(message)
      .andThen(AlamofireRequest)
      .start {result in
        switch result {
          
        case .Success(_):
          //generic refresh action
          if self.oldTableCells.flatten().isEmpty {
            self.action.userAction = UserAction.Focus
            self.loadStreamMessages(self.action)
          }
          else {
            self.refreshData()
          }
          
        case .Error(let boxedError):
          let error = boxedError.unbox
          print("PostMessage: \(error)")
        }
    }
  }
  
  private func createPostRequest(message: MessagePost) -> Future<URLRequestConvertible, ZulipErrorDomain> {
    let recipient: String
    if message.type == .Private {
      recipient = message.recipient.joinWithSeparator(",")
    } else {
      recipient = message.recipient[0]
    }
    let urlRequest: URLRequestConvertible = Router.PostMessage(type: message.type.description, content: message.content, to: recipient, subject: message.subject)
    return Future<URLRequestConvertible, ZulipErrorDomain>(value: urlRequest)
  }

  //create NSOperation to save new messages to realm from network
  private func messagesFromNetwork(action: Action) -> NSOperation {
    let urlToMessagesArray = URLToMessageArray(action: action, subscription: self.subscription)
    urlToMessagesArray.delegate = self
    return urlToMessagesArray
  }
  
  //create NSOperation to load messages from realm and convert to tablecells
  private func tableCellsFromRealm(action: Action, isLast: Bool) -> NSOperation {
    let messageArrayToTableCellArray = MessageArrayToTableCellArray(action: action, oldTableCells: self.oldTableCells, isLast: isLast)
    messageArrayToTableCellArray.delegate = self
    return messageArrayToTableCellArray
  }
  
  private var loading = false
  
  //MARK: Get Stream Messages
  func loadStreamMessages(action: Action) {
    print("\n==== NEW MSG LOAD ====")
    if self.loading {
      return
    }
    
    self.loading = true
    self.action = action
    
    //cancel previous operations when user makes a new request
    self.queue.cancelAll()
    self.resetRefreshTimer()
    let tableCellsFromRealmOperation = self.tableCellsFromRealm(action, isLast: false)
    self.queue.prepQueue.addOperation(tableCellsFromRealmOperation)
  }
  
  //clear refreshedMessageIds - only called when home button is pressed. A message ID can be stored but never loaded if more than <<default # of messages shown in view>> have been posted since the user last opened the app
  func clearRefreshedMessageId() {
    self.refreshedMessageIds.removeAll()
  }
}

//MARK: URLToMessagesArrayDelegate
extension StreamController: URLToMessageArrayDelegate {
  internal func urlToMessageArrayDidFinish(messages: [Message], userAction: UserAction) {
    switch userAction {
    case .Refresh:
      guard !messages.isEmpty else {return}
      
      //Add message id's to refreshedMessagesId
      let messageIds = messages.map {$0.id}
      for id in messageIds {
        self.refreshedMessageIds.insert(id)
      }
      
      self.shouldAddBadge(messages)
      
      //only proceed to loading new messages if user does not give additional input
      guard self.queue.prepQueue.operationCount == 0 && self.queue.userNetworkQueue.operationCount == 0 else {return}
      
    case .Focus: break
      
    case .ScrollUp:
      guard !messages.isEmpty else {
        dispatch_async(dispatch_get_main_queue()){
          self.delegate?.didFetchMessages()
        }
        self.loading = false
        return
      }
    }
    
    print("adding tableCellsFromRealmOperation")
    let tableCellsFromRealmOperation = self.tableCellsFromRealm(self.action, isLast: true)
    self.queue.prepQueue.addOperation(tableCellsFromRealmOperation)
  }
  
  //add badge after refresh network request
  private func shouldAddBadge(messages: [Message]) {
    guard !self.refreshedMessageIds.isEmpty else {return}
    
    //check if any of the newly refreshed messages will be added to the current narrow
    //this prevents badge blinking when the refreshed messages are within the scope of the current narrow
    let filteredRefresh = NSArray(array: messages).filteredArrayUsingPredicate(self.action.narrow.predicate())
    let filteredRefreshIds = (filteredRefresh as! [Message]).map {$0.id}
    
    guard !self.refreshedMessageIds.subtract(filteredRefreshIds).isEmpty else {return}
    
    self.delegate?.setNotification(.Badge, show: true)
  }
}

//MARK: MessagesArrayToTableCellArrayDelegate
extension StreamController: MessageArrayToTableCellArrayDelegate {
  internal func messageToTableCellArrayDidFinish(tableCells: [[TableCell]], deletedSections: NSRange, insertedSections: NSRange, insertedRows: [NSIndexPath], userAction: UserAction) {
    
    self.loading = false
    
    //show or hide badge as applicable
    self.badgeControl(tableCells)
    
    if insertedRows.isEmpty && userAction != UserAction.Focus {
      //The following statements run iff isLast = true
      dispatch_async(dispatch_get_main_queue()) {
        self.delegate?.didFetchMessages()
      }
      print("TableCell Delegate: insertedRows is empty")
      return
    }
    
    //oldTableCells is only reassigned if new messages are loaded
    self.oldTableCells = tableCells
    print("TableCell Delegate: TC's to TableView")
    
    //to mitigate race condition crashes
    self.queue.cancelRefreshQueue()
    
    var insertedSections = insertedSections
    var insertedRows = insertedRows
    var tableCells = tableCells
    
    if userAction == UserAction.Focus && insertedRows.isEmpty {
      insertedSections = NSMakeRange(0, 1)
      insertedRows = [NSIndexPath(forRow: 0, inSection: 0)]
      let defaultCell = makeDefaultCell()
      tableCells = [[defaultCell]]
    }
    
    dispatch_async(dispatch_get_main_queue()) {
      self.delegate?.didFetchMessages(tableCells, deletedSections: deletedSections, insertedSections: insertedSections, insertedRows: insertedRows, userAction: userAction)
    }
  }
  
  //control flow
  internal func realmNeedsMoreMessages() {
    let messagesFromNetworkOperation = self.messagesFromNetwork(self.action)
    self.queue.userNetworkQueue.addOperation(messagesFromNetworkOperation)
  }

  //remove badge and show new message notification
  private func badgeControl(tableCells: [[TableCell]]) {
    let tableCellIds = tableCells.flatten().map {$0.id}
    let messageIdIntersect = self.refreshedMessageIds.intersect(tableCellIds)
    
    for messageID in messageIdIntersect {
      self.refreshedMessageIds.remove(messageID)
    }
    
    print("MessagesArrayToTableCellArrayDelegate: # of refreshed messages: \(self.refreshedMessageIds.count)")
    
    if self.refreshedMessageIds.isEmpty {
      print("MessagesArrayToTableCellArrayDelegate: badge - false")
      dispatch_async(dispatch_get_main_queue()){
        self.delegate?.setNotification(.Badge, show: false)
      }
    }
    else {
      print("MessagesArrayToTableCellArrayDelegate: badge - true")
      print("refreshedIds: \(self.refreshedMessageIds)")
      dispatch_async(dispatch_get_main_queue()){
        self.delegate?.setNotification(.Badge, show: true)
      }
    }
    
    if !messageIdIntersect.isEmpty {
      dispatch_async(dispatch_get_main_queue()){
        self.delegate?.setNotification(Notification.NewMessage(messageCount: messageIdIntersect.count), show: true)
      }
    }
  }
  
  //create default cell if userAction = Focus and insertedRows is empty
  private func makeDefaultCell() -> TableCell {
    var defaultCell = TableCell()
    defaultCell.cellType = CellTypes.ExtendedCell
    defaultCell.type = self.action.narrow.type
    let textString = "No messages found. Start a conversation!"
    let attributedString = TextMunger.processMarkdown(textString)
    defaultCell.attributedContent = attributedString
    
    if defaultCell.type == .Private {
      defaultCell.privateFullName = Set(self.action.narrow.pmWith)
    }
    else {
      defaultCell.display_recipient = Set(self.action.narrow.stream)
      defaultCell.subject = "new topic"
      if let subject = self.action.narrow.subject {
        defaultCell.subject = subject
      }
    }
    return defaultCell
  }
}

