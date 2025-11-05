//
//  FTPError.swift
//  
//
//  Created by Alexander Ruiz Ponce on 14/09/24.
//

import Foundation

/// Represents errors that can occur during FTP operations.
public enum FTPError: Error {
    case connectionFailed(String)
    case authenticationFailed(String)
    case transferFailed(String)
    case cancelled
    case other(String)

    public var localizedDescription: String {
        switch self {
        case .connectionFailed(let message):
            return "Connection Failed: \(message)"
        case .authenticationFailed(let message):
            return "Authentication Failed: \(message)"
        case .transferFailed(let message):
            return "Transfer Failed: \(message)"
        case .cancelled:
            return "Operation Cancelled"
        case .other(let message):
            return "Error: \(message)"
        }
    }
}
