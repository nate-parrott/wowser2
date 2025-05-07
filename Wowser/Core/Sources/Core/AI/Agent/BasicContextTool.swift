import Foundation
import ChatToys

struct BasicContextTool: Tool {
    private var dateAndHourAsString: String {
        // Written by Phil
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM dd, yyyy 'at' h a"
        return formatter.string(from: Date())
    }

    func contextToInsertAtBeginningOfThread(context: ToolContext) async throws -> String? {
        var lines = [String]()
        lines.append("Current date: \(dateAndHourAsString)")
        return lines.joined(separator: "\n")
    }
}
