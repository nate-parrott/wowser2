import JavaScriptCore
import System
import Foundation

public struct WExtensionState: Equatable, Codable {
    public var extensions = [ID<WExtension>: WExtension]()
}

public class WExtensionStore: DataStore<WExtensionState> {
    public static let shared = WExtensionStore(persistenceKey: "WExtensionStore", defaultModel: .init(), queue: .extensionsQueue)
    
    private var instances = [ID<WExtension>: WExtensionInstance]() {
        didSet {
            Queue.extensionsQueue.assertCurrent()
        }
    }
    
    public func reloadFromDisk() {
        // TODO: check js hashes; recreate any changed instances
    }
}

extension Queue {
    static let extensionsQueue = Queue(id: "ExtensionsQueue", queue: DispatchQueue(label: "ExtensionsQueue", qos: .default))
}


public struct WExtension: Equatable, Codable {
    public var id: ID<WExtension>
    public var folderPath: FilePath
    public var jsHash: String // if jshash changes, we need to reload
}

class WExtensionInstance {
    let id: ID<WExtension>
    let path: FilePath
    let ctx: JSContext
    // TODO: give us a js context with access to BrowserJSRuntime
    
    init(ext: WExtension) {
        self.id = ext.id
        self.path = ext.folderPath
        assertNotOnMainThread()
        self.ctx = JSContext()
        loadFromDisk()
    }
    
    func loadFromDisk() {
        // TODO
    }
}

let WExtensionInterfaceDocs = """

interface WExtension {
    // TODO: Provide apis for hooks
    search?: (query: String) async => SearchResult[]

    // handles extension url schemes
    serveExtensionHTTPPage?: (urlReq: URLReq) async => URLResponse
}

interface WExtensionHost {
    getBaseURLForExtensionHTTP(): string; e.g. wext://myExtName/
    setSearchableActions(actions: SearchableAction[]) // e.g. 'New Note'
    setNewMenuEntries(entries: NewMenuEntry[])
}

"""
