#if os(macOS)
import Foundation
import Combine

/// Whether the local MCP server is up, for Settings → MCP to render.
@MainActor
public final class MCPServerStatus: ObservableObject {
    public static let shared = MCPServerStatus()

    public enum State: Equatable {
        case starting
        case running
        case failed(String)
    }

    @Published public private(set) var state: State = .starting

    public var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    func set(_ state: State) {
        self.state = state
    }
}
#endif
