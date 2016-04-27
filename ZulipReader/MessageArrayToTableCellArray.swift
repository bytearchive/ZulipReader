//
//  MessageArrayToTableCellArray.swift
//  ZulipReader
//
//  Created by Frank Tan on 3/22/16.
//  Copyright © 2016 Frank Tan. All rights reserved.
//

import Foundation
import RealmSwift

protocol MessageArrayToTableCellArrayDelegate: class {
  func messageToTableCellArrayDidFinish(tableCells: [[TableCell]], deletedSections: NSRange, insertedSections: NSRange, insertedRows: [NSIndexPath], userAction: UserAction)
  
  func realmNeedsMoreMessages()
}

class MessageArrayToTableCellArray: NSOperation {
  
  weak var delegate: MessageArrayToTableCellArrayDelegate?
  private let action: Action
  private var oldTableCells = [[TableCell]]()
  private let isLast: Bool
  
  //NSOperation Output
  private var tableCells = [[TableCell]]()
  private var deletedSections = NSRange()
  private var insertedSections = NSRange()
  private var insertedRows = [NSIndexPath]()
  
  init(action: Action, oldTableCells: [[TableCell]], isLast: Bool) {
    self.action = action
    self.oldTableCells = oldTableCells
    self.isLast = isLast
  }
  
  override func main() {
    let realm: Realm
    do {
      realm = try Realm()
    } catch {fatalError()}
    
    let narrowPredicate = action.narrow.predicate()
    let userAction = action.userAction
    //returns predicate based on current table max and narrow min
    let idPredicate = minMaxPredicate()
    
    //realm messages returns all the messages
    let realmMessages = NSArray(array: realm.objects(Message)
      .filter(idPredicate)
      .sorted("id", ascending: true)
      .map {$0})
    
    
    //This second layer of filtering is necessary because Realm can't recognize "ALL"
    //This approach is inefficient because we're not taking advantage of realm's lazy initiation...
    let allFilteredMessages = realmMessages.filteredArrayUsingPredicate(narrowPredicate) as! [Message]
    
    let flatOldTableCells = oldTableCells.flatten()
    //messageThreshold triggers a network call if thres isn't met
    //Focus case included for clarity
    var messageThreshold = 30
    switch userAction {
    case .Focus:
      messageThreshold = 30
    case .ScrollUp:
      messageThreshold += flatOldTableCells.count
    case .Refresh:
      let lastOldTableCellId = flatOldTableCells.last!.id
      messageThreshold = flatOldTableCells.count +
        allFilteredMessages.reduce(0, combine: {total, msg in
        if msg.id > lastOldTableCellId {
          return total + 1
        }
        return total
      })
    }
    
    if self.cancelled {
      return
    }
    
    if userAction == .Refresh && messageThreshold == flatOldTableCells.count {
      print("TCOp: Refresh - no new msgs in current narrow")
      //TODO: call delegate to add badge to home button
      return
    }
    
    if isLast == false && allFilteredMessages.count < messageThreshold {
      self.delegate?.realmNeedsMoreMessages()
      print("TCOp: MessageArrayToTableCellArray: less than \(messageThreshold) msgs")
      return
    }
    
    print("TCOp: computing realm messages")
    let allReversedMessages = Array(allFilteredMessages.reverse())
    var _tableCellMessages = [Message]()
    for counter in 0 ..< min(messageThreshold, allFilteredMessages.count) {
      _tableCellMessages.append(allReversedMessages[counter])
    }
    
    let tableCellMessages = Array(_tableCellMessages.reverse())
    
    if self.cancelled {
      return
    }
    
    let realmTableCells = self.messageToTableCell(tableCellMessages)
    
    if self.cancelled {
      return
    }

    self.tableCells = realmTableCells
    (self.deletedSections, self.insertedSections, self.insertedRows) = self.findTableUpdates(realmTableCells, action: userAction)
    
    if self.cancelled {
      return
    }
    
    self.delegate?.messageToTableCellArrayDidFinish(tableCells, deletedSections: deletedSections, insertedSections: insertedSections, insertedRows: insertedRows, userAction: self.action.userAction)
  }
  
  func minMaxPredicate() -> NSPredicate {
    //min & max message indices are stored in NSUserDefaults
    let defaults = NSUserDefaults.standardUserDefaults()
    
    //network delegate called if id's are 0
    let homeMinId = defaults.integerForKey("homeMin")
    let homeMaxId = defaults.integerForKey("homeMax")
    
    var minId = homeMinId
    let maxId = homeMaxId
    
    if let narrowString = self.action.narrow.narrowString {
      minId = defaults.integerForKey(narrowString)
    }
    
    //make predicates
    let minIdPredicate = NSPredicate(format: "id >= %d", minId)
    let maxIdPredicate = NSPredicate(format: "id <= %d", maxId)
    let andPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [minIdPredicate, maxIdPredicate])
    print("TCOp: MessageArrayToTableCell Array idPredicate: \(andPredicate)")
    return andPredicate
  }
  
  private func findTableUpdates(realmTableCells: [[TableCell]], action: UserAction) -> (deletedSections: NSRange, insertedSections: NSRange, insertedRows: [NSIndexPath]) {
    
    //find the differences between oldTableCells and the new messages to be loaded
    var deletedSections = NSRange()
    var insertedSections = NSRange()
    var insertedRows = [NSIndexPath]()
    
    let flatRealmTableCells = realmTableCells.flatMap {$0}
    
    switch action {
    case .Focus:
      deletedSections = NSMakeRange(0, oldTableCells.count)
      insertedSections = NSMakeRange(0, realmTableCells.count)
      insertedRows = flatRealmTableCells.map {NSIndexPath(forRow: $0.row, inSection: $0.section)}
      
    case .ScrollUp:
      let oldTableCellsId = self.oldTableCells.flatMap {$0}.map {$0.id}
      insertedSections = NSMakeRange(0, realmTableCells.count - oldTableCells.count)
      for section in 0...insertedSections.length {
        for tableCell in realmTableCells[section] {
          if !oldTableCellsId.contains(tableCell.id) {
            insertedRows.append(NSIndexPath(forRow: tableCell.row, inSection: section))
          }
        }
      }
      
    case .Refresh:
      let flatOldTableCells = self.oldTableCells.flatMap {$0}
      let oldTableCellsId = flatOldTableCells.map {$0.id}
      guard let lastOldTableCell = flatOldTableCells.last else {break}
      
      let rangeLength = realmTableCells.count - oldTableCells.count
      
      insertedSections = NSMakeRange(lastOldTableCell.section + 1, rangeLength)
      
      let firstSection = lastOldTableCell.section
      let lastSection = firstSection + rangeLength
      
      for section in firstSection...lastSection {
        for tableCell in realmTableCells[section] {
          if !oldTableCellsId.contains(tableCell.id) {
            insertedRows.append(NSIndexPath(forRow: tableCell.row, inSection: section))
          }
        }
      }
    }
    
    //TODO: Add a check to verify that deleted/inserted Sections and insertedRows matches the number of messages that should appear. If not, action = .Focus to force a complete recalculation
    
    print("TCOp: action: \(action)")
    print("TCOp: deletedSections: \(deletedSections)")
    print("TCOp: insertedSections: \(insertedSections)")
    print("TCOp: insertedRows: \(insertedRows.count)")
    return (deletedSections, insertedSections, insertedRows)
  }
  
  private func messageToTableCell(messages: [Message]) -> [[TableCell]] {
    var previous = TableCell()
    var result = [[TableCell]()]
    var sectionCounter = 0
    var rowCounter = 0
    
    for message in messages {
      var cell = TableCell(message)
      let messageContent = message.content
      let attributedContent = TextMunger.processMarkdown(messageContent)
      cell.attributedContent = attributedContent
      
      if previous.isEmpty {
        result[sectionCounter].append(cell)
        previous = cell
        continue
      }
      
      if previous.display_recipient != cell.display_recipient ||
        previous.subject != cell.subject ||
        previous.type != cell.type {
        
        sectionCounter += 1
        rowCounter = 0
        cell.section = sectionCounter
        cell.row = rowCounter
        result.append([cell])
      }
      else {
        if previous.sender_full_name == cell.sender_full_name {
          cell.cellType = CellTypes.ExtendedCell
        }
        
        rowCounter += 1
        cell.section = sectionCounter
        cell.row = rowCounter
        result[sectionCounter].append(cell)
      }
      previous = cell
    }
    
    return result
  }
}