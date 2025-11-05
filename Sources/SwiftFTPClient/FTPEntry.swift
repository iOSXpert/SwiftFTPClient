//
//  FTPEntry.swift
//  SwiftFTPClient
//
//  Created by Daniel Nauerz on 05.11.25.
//

import Foundation

public struct FTPEntry {
    public let name: String
    public let isDirectory: Bool
    public let size: Int64?
    public let modified: Date?
}
