//
//  JSON.swift
//  Core
//
//  Created by Nate Parrott on 3/9/25.
//

import Foundation

extension Encodable {
    var encodedAsJSONString: String {
        let data = try! JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8)!
    }
}

