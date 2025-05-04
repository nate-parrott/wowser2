//
//  Bool.swift
//  Core
//
//  Created by Nate Parrott on 5/4/25.
//

extension Bool {
    var nilIfFalse: Bool? {
        self == true ? true : nil
    }
}
