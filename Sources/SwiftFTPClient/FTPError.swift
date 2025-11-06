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
            return "Connection Failed: \(message.cleanedFTPErrorMessage)"
        case .authenticationFailed(let message):
            return "Authentication Failed: \(message.cleanedFTPErrorMessage)"
        case .transferFailed(let message):
            return "Transfer Failed: \(message.cleanedFTPErrorMessage)"
        case .cancelled:
            return "Operation Cancelled"
        case .other(let message):
            return "Error: \(message.cleanedFTPErrorMessage)"
        }
    }
}

extension String {
    var cleanedFTPErrorMessage: String {
        return self.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }
}
