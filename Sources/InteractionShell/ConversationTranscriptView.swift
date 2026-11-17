import AppKit

/// Transcript data owns the conversation. Table cells are disposable projections.
@MainActor
final class ConversationTurn {
  struct Outcome {
    let result: String
    let status: String
    let tone: TaskPresentationOutcome
    let action: TaskPresentationAction?
    let retryable: Bool
  }

  let id = UUID()
  let userText: String
  private(set) var activities: [AgentActivityPresentation] = []
  var outcome: Outcome?
  var postResultStatus: String?
  var actionEnabled = true
  var processExpanded = false
  var measuredHeight: CGFloat = 100
  var resultHeight: CGFloat?

  init(userText: String) { self.userText = userText }

  func record(_ activity: AgentActivityPresentation) {
    guard outcome == nil else { return }
    if let index = activities.firstIndex(where: { $0.id == activity.id }) {
      activities[index] = activity
      if activity.status == .active { activities.insert(activities.remove(at: index), at: 0) }
    } else {
      activities.insert(activity, at: 0)
      if activities.count > 24 { activities.removeLast() }
    }
  }

  func resetForRetry() {
    activities.removeAll()
    outcome = nil
    postResultStatus = nil
    actionEnabled = true
    processExpanded = false
    resultHeight = nil
  }
}

@MainActor
private final class TranscriptCell: NSTableCellView {
  var turnID: UUID?
  var content: ConversationTurnView?

  func releaseContent() {
    content?.onHeightChange = nil
    content?.releaseResources()
    content?.removeFromSuperview()
    content = nil
    turnID = nil
  }

  func install(_ content: ConversationTurnView, id: UUID) {
    releaseContent()
    self.content = content
    turnID = id
    addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: leadingAnchor),
      content.trailingAnchor.constraint(equalTo: trailingAnchor),
      content.topAnchor.constraint(equalTo: topAnchor),
    ])
  }
}

/// View-based NSTableView supplies native scrolling, accessibility and row reuse.
/// Neither a transcript record nor a task binding holds a view or WKWebView.
@MainActor
final class ConversationTranscriptView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
  private static let cellID = NSUserInterfaceItemIdentifier("conversation-turn")
  private let table = NSTableView()
  private(set) var turns: [ConversationTurn] = []
  var onContentSizeChange: (() -> Void)?
  var onAction: ((ConversationTurn, TaskPresentationAction) -> Void)?
  var onRetry: ((ConversationTurn) -> Void)?
  private var measuring = false
  private var measurementScheduled = false
  private var generation: UInt64 = 0

  override init(frame: NSRect) {
    super.init(frame: frame)
    drawsBackground = false
    borderType = .noBorder
    hasVerticalScroller = true
    autohidesScrollers = true
    scrollerStyle = .overlay
    let column = NSTableColumn(identifier: Self.cellID)
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.backgroundColor = .clear
    table.style = .plain
    table.intercellSpacing = NSSize(width: 0, height: 20)
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.selectionHighlightStyle = .none
    table.allowsEmptySelection = true
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityLabel("会话历史")
    documentView = table
  }

  required init?(coder: NSCoder) { nil }

  override func reflectScrolledClipView(_ clipView: NSClipView) {
    super.reflectScrolledClipView(clipView)
    if !measuring { scheduleMeasurement() }
  }

  var contentHeight: CGFloat {
    turns.reduce(0) { $0 + $1.measuredHeight + table.intercellSpacing.height }
  }

  var followsLatest: Bool {
    table.frame.height - contentView.bounds.maxY <= 20
  }

  func reset() {
    generation &+= 1
    for row in 0..<table.numberOfRows {
      (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptCell)?
        .releaseContent()
    }
    turns.removeAll()
    table.reloadData()
  }

  func append(_ turn: ConversationTurn) {
    turns.append(turn)
    table.insertRows(at: IndexSet(integer: turns.count - 1), withAnimation: [])
  }

  func view(for turn: ConversationTurn) -> ConversationTurnView? {
    guard let row = turns.firstIndex(where: { $0 === turn }),
      let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptCell,
      cell.turnID == turn.id
    else { return nil }
    return cell.content
  }

  func update(_ turn: ConversationTurn, applying update: (ConversationTurnView) -> Void) {
    if let view = view(for: turn) { update(view) }
    scheduleMeasurement()
  }

  func layoutVisibleRows(followLatest: Bool) {
    guard !measuring else { return }
    measuring = true
    defer { measuring = false }
    table.frame.size.width = max(1, contentSize.width)
    table.tableColumns.first?.width = max(1, contentSize.width)
    table.layoutSubtreeIfNeeded()
    if followLatest, !turns.isEmpty { table.scrollRowToVisible(turns.count - 1) }
    let visible = table.rows(in: contentView.bounds)
    // AppKit may keep row views attached during an animation or reuse cycle.
    // The viewport, not that retention policy, owns expensive result resources.
    table.enumerateAvailableRowViews { rowView, row in
      if visible.location == NSNotFound || !NSLocationInRange(row, visible) {
        (rowView.view(atColumn: 0) as? TranscriptCell)?.releaseContent()
      }
    }
    guard visible.location != NSNotFound else { return }
    let anchor = table.row(at: NSPoint(x: 0, y: contentView.bounds.minY))
    let offset = anchor >= 0 ? contentView.bounds.minY - table.rect(ofRow: anchor).minY : 0
    var changed = IndexSet()
    for row in visible.location..<min(NSMaxRange(visible), turns.count) {
      guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TranscriptCell
      else { continue }
      if cell.content == nil { configure(cell, forRow: row) }
      guard let content = cell.content else { continue }
      cell.layoutSubtreeIfNeeded()
      content.layoutSubtreeIfNeeded()
      let height = max(44, ceil(content.fittingSize.height))
      if turns[row].outcome?.result.isEmpty == false {
        turns[row].resultHeight = content.measuredResultHeight
      }
      if abs(height - turns[row].measuredHeight) > 0.5 {
        turns[row].measuredHeight = height
        changed.insert(row)
      }
    }
    if !changed.isEmpty {
      table.noteHeightOfRows(withIndexesChanged: changed)
      if followLatest, !turns.isEmpty {
        // scrollRowToVisible aligns tall rows to their top; follow the bottom instead.
        contentView.scroll(
          to: NSPoint(x: 0, y: max(0, table.frame.height - contentView.bounds.height)))
      } else if anchor >= 0 {
        contentView.scroll(to: NSPoint(x: 0, y: max(0, table.rect(ofRow: anchor).minY + offset)))
      }
      reflectScrolledClipView(contentView)
      onContentSizeChange?()
    }
  }

  private func scheduleMeasurement() {
    guard !measurementScheduled else { return }
    measurementScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.measurementScheduled = false
      self.layoutVisibleRows(followLatest: self.followsLatest)
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { turns.count }
  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    turns[row].measuredHeight
  }
  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let cell =
      tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? TranscriptCell
      ?? TranscriptCell()
    cell.identifier = Self.cellID
    configure(cell, forRow: row)
    return cell
  }

  private func configure(_ cell: TranscriptCell, forRow row: Int) {
    let turn = turns[row]
    let content = ConversationTurnView(userText: turn.userText)
    content.restore(turn)
    cell.install(content, id: turn.id)
    let generation = self.generation
    content.onHeightChange = { [weak self, weak cell] in
      guard let self, self.generation == generation, cell?.turnID == turn.id else { return }
      self.scheduleMeasurement()
    }
    content.onProcessExpansion = { [weak turn] expanded in turn?.processExpanded = expanded }
    content.onAction = { [weak self, weak turn] action in
      guard let turn, turn.actionEnabled else { return }
      turn.actionEnabled = false
      self?.onAction?(turn, action)
    }
    content.onRetry = { [weak self, weak turn] in
      guard let turn else { return }
      self?.onRetry?(turn)
    }
    scheduleMeasurement()
  }

  func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
    // AppKit may retain reusable cells. Keep its reuse queue free of WebKit resources.
    (rowView.view(atColumn: 0) as? TranscriptCell)?.releaseContent()
  }
}
