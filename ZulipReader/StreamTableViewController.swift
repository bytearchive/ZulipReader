//
//  StreamTableViewController.swift
//  ZulipReader
//
//  Created by Frank Tan on 11/23/15.
//  Copyright © 2015 Frank Tan. All rights reserved.
//

import UIKit
import SlackTextViewController

class StreamTableViewController: NotificationNavViewController {
  
  enum State {
    case Home, Stream, Subject
  }
  
  var state: State = .Home
  var data: StreamController?
  var messages = [[TableCell]]()
  var action = Action()
  
  var refreshControl: UIRefreshControl?
  
  override func viewDidLoad() {
    super.viewDidLoad()
    self.viewDidLoadSettings()
  }
  
  func viewDidLoadSettings() {
    state = .Home
    
    self.data = StreamController()
    self.sideMenuTableViewController = SideMenuTableViewController()
    
    //optional type so streamController can be deallocated on logout
    guard let data = data else {fatalError()}
    
    //Set delegates
    data.delegate = self
    self.sideMenuTableViewController?.delegate = self
    data.subscriptionDelegate = self.sideMenuTableViewController
    
    self.refreshSettings()
  }
  
  override func viewDidAppear(animated: Bool) {
    super.viewDidAppear(animated)
    self.loadData()
  }
  
  func loadData() {
    //slack textview controller makes tableView an optional type
    guard let data = data, let tableView = tableView else {fatalError()}

    if !data.isLoggedIn() {
      let controller = LoginViewController()
      presentViewController(controller, animated: true, completion: nil)
    }
    else {
      tableView.showLoading()
      data.register()
    }
  }
  
  //MARK: Scroll Up RefreshControl
  func refreshSettings() {
    let tableViewController = UITableViewController()
    tableViewController.tableView = self.tableView
    let refresh = UIRefreshControl()
    refresh.addTarget(self, action: #selector(StreamTableViewController.refresh(_:)), forControlEvents: .ValueChanged)
    tableViewController.refreshControl = refresh

  }
  
  func refresh(refreshControl: UIRefreshControl) {
    self.refreshControl = refreshControl
    guard let data = data else {fatalError()}
    self.action.userAction = .ScrollUp
    data.loadStreamMessages(self.action)
  }
  
  //MARK: TableViewDelegate
  override func tableView(tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    let headerCell = messages[section][0]
    let headerType = headerCell.type
    let cell: ZulipTableViewCell
    
    switch headerType {
    case .Stream:
      cell = tableView.dequeueReusableCellWithIdentifier("StreamHeaderNavCell") as! StreamHeaderNavCell
      let navCell = cell as! StreamHeaderNavCell
      navCell.delegate = self
      
    case .Private:
      cell = tableView.dequeueReusableCellWithIdentifier("StreamHeaderPrivateCell") as! StreamHeaderPrivateCell
      let privateCell = cell as! StreamHeaderPrivateCell
      privateCell.delegate = self
    }
    
    cell.configure(headerCell)
    return configureHeaderView(cell)
  }
  
  func configureHeaderView(cell: ZulipTableViewCell) -> UIView {
    guard let tableView = tableView else {fatalError()}

    let originalFrame = cell.frame
    cell.frame = CGRect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: tableView.frame.width, height: originalFrame.height))
    let headerView = UIView(frame: cell.frame)
    headerView.addSubview(cell)
    return headerView
  }
  
  override func tableView(tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    return 27.0
  }
  
  override func tableView(tableView: UITableView, estimatedHeightForRowAtIndexPath indexPath: NSIndexPath) -> CGFloat {
    //estimatedHeight is a (very) rough approximation of row height. Seems to help with scrolling and "jumpiness" caused by new message loading
    let message = messages[indexPath.section][indexPath.row]
    let estimatedHeight = message.attributedContent.length/40 * 30 + 50
    if estimatedHeight < 300 {
      return 300.0
    }
    
    return CGFloat(estimatedHeight)
  }
  
  override func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
    tableView.deselectRowAtIndexPath(indexPath, animated: true)
  }
  
  //MARK: TableViewDataSource
  override func numberOfSectionsInTableView(tableView: UITableView) -> Int {
    return messages.count
  }
  
  override func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return messages[section].count
  }
  
  override func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
    let message = messages[indexPath.section][indexPath.row]
    let cell: ZulipTableViewCell
    
    switch message.cellType {
    case .StreamCell:
      cell = tableView.dequeueReusableCellWithIdentifier(message.cellType.string) as! StreamCell
      let streamCell = cell as! StreamCell
      streamCell.delegate = self
    case .ExtendedCell:
      cell = tableView.dequeueReusableCellWithIdentifier(message.cellType.string) as! StreamExtendedCell
    }
    cell.configure(message)
    return cell
  }

  func logout() {
    //clear all the data
    guard let data = data, let tableView = tableView else {fatalError()}
    data.clearData()
    self.data = nil
    self.sideMenuTableViewController = nil
    self.refreshControl = nil
    self.state = .Home
    self.messages = [[TableCell]]()
    self.action = Action()
    
    //reload the controller
    tableView.reloadData()
    self.viewDidLoadSettings()
    self.loadData()
  }
  
  func focusAction(narrow: Narrow) {
    self.action = Action(narrow: narrow, action: .Focus)
    guard let data = data else {fatalError()}
    data.loadStreamMessages(self.action)
    UIApplication.sharedApplication().networkActivityIndicatorVisible = true
  }
  
  func prepareNarrow(narrow: Narrow, navTitle: String) {
    self.transitionToBlur(true)
    self.focusAction(narrow)
    
    guard navTitle != self.navBarTitle.titleButton.currentTitle! else {return}

    self.setNavBarTitle(false, title: navTitle)
  }
  
  //MARK: SLKTextViewController
  //Right button only appears in .Subject
  override func didPressRightButton(sender: AnyObject!) {
    self.textView.refreshFirstResponder()
    let sentMessage: String = self.textView.text
    
    //Either pmWith or stream will be empty []
    let pmWith = self.action.narrow.pmWith
    let stream = self.action.narrow.stream
    let recipient = pmWith + stream
    
    let subject = self.action.narrow.subject
    
    let messagePost = MessagePost(content: sentMessage, recipient: recipient, subject: subject)
    
    //TODO: update this to reflect the latest multitasking changes - self.action.userAction
    self.action.userAction = .Refresh
    guard let data = data else {fatalError()}
    data.postMessage(messagePost, action: self.action)
    super.didPressRightButton(sender)
  }
}

//MARK: NavBar Target
extension StreamTableViewController {
  func homeButtonDidTouch(sender: AnyObject) {
    state = .Home
    let narrow = Narrow()
    
    //just to be absolutely sure that badge is removed when we're on the main view
    self.setNotification(.Badge, show: false)
    data?.clearRefreshedMessageId()
    
    self.prepareNarrow(narrow, navTitle: "Stream")
  }
}

//MARK: StreamControllerDelegate
extension StreamTableViewController: StreamControllerDelegate {
  func setNotification(notification: Notification, show: Bool) {
    switch notification {
    case .Badge:
      self.showNavBarBadge(show)
      
    default:
      self.setNavBarTitle(true, title: self.navBarTitle.title)
    }
  }
  
  func didFetchMessages() {
    //called if no new messages are found
    if let refresh = self.refreshControl {
      if refresh.refreshing {
        self.refreshControl!.endRefreshing()
      }
    }
    UIApplication.sharedApplication().networkActivityIndicatorVisible = false
    self.transitionToBlur(false)
  }
  
  func didFetchMessages(messages: [[TableCell]], deletedSections: NSRange, insertedSections: NSRange, insertedRows: [NSIndexPath], userAction: UserAction) {
//    let methodStart = NSDate()
    guard let tableView = tableView else {fatalError()}

    tableView.hideLoading()
    print("UITVC: old sections: \(self.messages.count)")
    self.messages = messages
    
    print("UITVC: new sections: \(self.messages.count)")
    print("UITVC: inserted sections: \(insertedSections)")
    print("UITVC: deleted sections: \(deletedSections)")
    
//    let updateStart = NSDate()
    tableView.beginUpdates()
    tableView.deleteSections(NSIndexSet(indexesInRange: deletedSections), withRowAnimation: .None)
    tableView.insertSections(NSIndexSet(indexesInRange: insertedSections), withRowAnimation: .None)
    tableView.insertRowsAtIndexPaths(insertedRows, withRowAnimation: .None)
    tableView.endUpdates()
//    print("update Time: \(updateStart.timeIntervalSinceNow)")

    
    if let refresh = self.refreshControl  {
      if refresh.refreshing {
        self.refreshControl!.endRefreshing()
      }
    }
    
    //turn off network activity indicator
    UIApplication.sharedApplication().networkActivityIndicatorVisible = false
//    let visualStart = NSDate()
    
    switch self.state {
    case .Subject:
      self.setTextInputbarHidden(false, animated: true)
    default:
      self.setTextInputbarHidden(true, animated: true)
    }
    
//    print("visual Time 1: \(visualStart.timeIntervalSinceNow)")

    //TODO: scrolling to the last row at indexpath is a major resource drain
    //scroll to last tableview cell if user action is not refresh
    if userAction != .Refresh {
      if let lastIndexPath = insertedRows.last {
        tableView.selectRowAtIndexPath(lastIndexPath, animated: false, scrollPosition: .Bottom)
        tableView.deselectRowAtIndexPath(lastIndexPath, animated: false)
        self.setNavBarTitle(false, title: self.navBarTitle.title)
      }
    }
//    print("visual Time 2: \(visualStart.timeIntervalSinceNow)")

    self.transitionToBlur(false)
//    print("visual Time 3: \(visualStart.timeIntervalSinceNow)")

//    print("didFetchMessages Time: \(methodStart.timeIntervalSinceNow)")
  }
}

//MARK: StreamCellDelegate
extension StreamTableViewController: StreamCellDelegate {
  func userImageDidTouch(message: TableCell) {
    print("in table view controller!")
    state = .Subject
    let pmWith = [message.sender_email]
    let narrowString = "[[\"is\", \"private\"],[\"pm-with\",\"\(message.sender_email)\"]]"
    let narrow = Narrow(narrowString: narrowString, pmWith: pmWith)
    
    self.prepareNarrow(narrow, navTitle: "PM")
  }
}

//MARK: StreamHeaderNavCellDelegate
extension StreamTableViewController: StreamHeaderNavCellDelegate {
  func narrowStream(stream: String) {
    state = .Stream
    
    let narrowString = "[[\"stream\", \"\(stream)\"]]"
    let narrow = Narrow(narrowString: narrowString, stream: stream)
    
    self.prepareNarrow(narrow, navTitle: stream)
  }
  
  func narrowSubject(stream: String, subject: String) {
    state = .Subject
    
    let narrowString = "[[\"stream\", \"\(stream)\"],[\"topic\",\"\(subject)\"]]"
    let narrow = Narrow(narrowString: narrowString, stream: stream, subject: subject)
    
    self.prepareNarrow(narrow, navTitle: subject)
  }
}

//MARK: StreamHeaderPrivateCellDelegate
extension StreamTableViewController: StreamHeaderPrivateCellDelegate {
  func narrowConversation(message: TableCell) {
    state = .Subject
    
    let pmWith = message.pmWith.sort()
    let emailString = pmWith.joinWithSeparator(",")
    let narrowString = "[[\"is\", \"private\"],[\"pm-with\",\"\(emailString)\"]]"
    let narrow = Narrow(narrowString: narrowString, pmWith: pmWith)
    
    self.prepareNarrow(narrow, navTitle: "PM")
  }
}

//MARK: SideMenuDelegate
extension StreamTableViewController: SideMenuDelegate {
  func sideMenuDidTouch(selection: String) {
    state = .Stream
    let narrow: Narrow
    switch selection {
    case "Private":
      let narrowString = "[[\"is\", \"\(selection.lowercaseString)\"]]"
      narrow = Narrow(narrowString: narrowString, type: .Private)
    case "Mentioned":
      let narrowString = "[[\"is\", \"\(selection.lowercaseString)\"]]"
      narrow = Narrow(narrowString: narrowString, mentioned: true)
    case "Logout":
      self.logout()
      return
    default:
      let narrowString = "[[\"stream\", \"\(selection)\"]]"
      narrow = Narrow(narrowString: narrowString, stream: selection)
    }
    
    self.prepareNarrow(narrow, navTitle: selection)
  }
}