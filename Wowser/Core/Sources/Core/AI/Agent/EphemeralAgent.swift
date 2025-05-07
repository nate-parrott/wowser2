import Foundation
import Combine

class EphemeralAgent: AgentThreadStore {
    @Published var model: ThreadModel

    init(model: ThreadModel) {
        self.model = model
    }

    func readThreadModel() async -> ThreadModel {
        model
    }
    
    func modifyThreadModel<ReturnVal>(_ callback: @escaping (inout ThreadModel) -> ReturnVal) async -> ReturnVal {
        callback(&model)
    }

    func threadModelPublisher() -> AnyPublisher<ThreadModel, Never> {
        $model.eraseToAnyPublisher()
    }
}
