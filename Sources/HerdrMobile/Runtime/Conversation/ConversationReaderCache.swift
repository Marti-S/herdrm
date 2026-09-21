import Foundation
import HerdrKit

/// Owns the pane-scoped transcript readers independently of SwiftUI screen identity.
/// A replacement screen may appear before the old one disappears, so the cached
/// ViewModel preserves its viewer-counted lifecycle across view reconstruction.
@MainActor
final class ConversationReaderCache {
  private var readers: [FleetPaneRef: ConversationReaderViewModel] = [:]
  private var sessionPaths: [FleetPaneRef: String?] = [:]

  func reader(
    for ref: FleetPaneRef,
    agent: AgentInfo,
    transport: any MobileTransport
  ) -> ConversationReaderViewModel {
    let sessionPath = agent.agentSessionPath.flatMap {
      FileRangeRead.isAllowedSessionPath($0) ? $0 : nil
    }
    if let existing = readers[ref], sessionPaths[ref] == sessionPath {
      return existing
    }

    let provider: any AgentTranscriptProvider
    if let sessionPath {
      provider = AtomicSessionTranscriptProvider(
        transport: transport,
        paneID: ref.paneID,
        sessionPath: sessionPath
      )
    } else {
      provider = HerdrPaneTranscriptProvider(
        transport: transport,
        paneID: ref.paneID
      )
    }

    let reader = ConversationReaderViewModel(provider: provider)
    readers[ref] = reader
    sessionPaths[ref] = sessionPath
    return reader
  }
}
