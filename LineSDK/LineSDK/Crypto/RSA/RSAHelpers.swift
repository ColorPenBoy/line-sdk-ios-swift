//
//  RSAHelpers.swift
//
//  Copyright (c) 2016-present, LINE Corporation. All rights reserved.
//
//  You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
//  copy and distribute this software in source code or binary form for use
//  in connection with the web services and APIs provided by LINE Corporation.
//
//  As with any software that integrates with the LINE Corporation platform, your use of this software
//  is subject to the LINE Developers Agreement [http://terms2.line.me/LINE_Developers_Agreement].
//  This copyright notice shall be included in all copies or substantial portions of the software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
//  INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//  DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

import Foundation
import CommonCrypto

extension Data {
    /// Data with x509 stripped from a provided ASN.1 DER public key.
    /// The DER data will be returned as is, if no header contained.
    /// We need to do this on Apple's platform for accepting a key.
    // http://blog.flirble.org/2011/01/05/rsa-public-key-openssl-ios/
    func x509HeaserStripped() throws -> Data {
        let count = self.count / MemoryLayout<CUnsignedChar>.size
        
        guard count > 0 else {
            throw CryptoError.RSAFailed(reason: .invalidDERKey(data: self, reason: "The input key is empty."))
        }
        
        var bytes = [UInt8](self)
        
        // Check the first byte
        var index = 0
        guard bytes[index] == ASN1Type.sequence.byte else {
            throw CryptoError.RSAFailed(
                reason: .invalidDERKey(
                    data: self,
                    reason: "The input key is invalid. ASN.1 structure requires 0x30 (SEQUENCE) as its first byte"
                )
            )
        }
        
        // octets length
        index += 1
        if bytes[index] > 0x80 {
            index += Int(bytes[index]) - 0x80 + 1
        } else {
            index += 1
        }
        
        // If the target == 0x02, it is an INTEGER. There is no X509 header contained. We could just return the
        // input DER data as is.
        if bytes[index] == ASN1Type.integer.byte { return self }
        
        // Handle X.509 key now. PKCS #1 rsaEncryption szOID_RSA_RSA, it should look like this:
        // 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00
        guard bytes[index] == 0x30 else {
            throw CryptoError.RSAFailed(
                reason: .invalidX509Header(
                    data: self, index: index, reason: "Expects byte 0x30, but found \(bytes[index])"
                )
            )
        }
        
        index += 15
        if bytes[index] != 0x03 {
            throw CryptoError.RSAFailed(
                reason: .invalidX509Header(
                    data: self, index: index, reason: "Expects byte 0x03, but found \(bytes[index])"
                )
            )
        }
        
        index += 1
        if bytes[index] > 0x80 {
            index += Int(bytes[index]) - 0x80 + 1
        } else {
            index += 1
        }
        
        // End of header
        guard bytes[index] == 0 else {
            throw CryptoError.RSAFailed(
                reason: .invalidX509Header(
                    data: self, index: index, reason: "Expects byte 0x00, but found \(bytes[index])"
                )
            )
        }
        
        index += 1
        
        let strippedKeyBytes = [UInt8](bytes[index...self.count - 1])
        let data = Data(bytes: UnsafePointer<UInt8>(strippedKeyBytes), count: self.count - index)
        
        return data
    }
}

extension SecKey {
    
    enum KeyClass {
        case publicKey
        case privateKey
    }
    
    // Create a general key from DER raw data.
    static func createKey(derData data: Data, keyClass: KeyClass) throws -> SecKey {
        let keyClass = keyClass == .publicKey ? kSecAttrKeyClassPublic : kSecAttrKeyClassPrivate
        let sizeInBits = data.count * MemoryLayout<UInt8>.size
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: keyClass,
            kSecAttrKeySizeInBits: NSNumber(value: sizeInBits)
        ]
        
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error) else {
            let reason = String(describing: error)
            throw CryptoError.RSAFailed(reason: .createKeyFailed(data: data, reason: reason))
        }
        
        return key
    }
    
    static func createPublicKey(certificateData data: Data) throws -> SecKey {
        guard let certData = SecCertificateCreateWithData(nil, data as CFData) else {
            throw CryptoError.RSAFailed(
                reason: .createKeyFailed(data: data, reason: "The data is not a valid DER-encoded X.509 certificate"))
        }
        
        // Get public key from certData
        if #available(iOS 10.3, *) {
            guard let key = SecCertificateCopyPublicKey(certData) else {
                throw CryptoError.RSAFailed(
                    reason: .createKeyFailed(data: data, reason: "Cannot copy public key from certificate"))
            }
            return key
        } else {
            throw CryptoError.generalError(
                reason: .operationNotSupported(
                    reason: "Loading public key from certificate not supported below iOS 10.3.")
            )
        }
    }
}

extension String {
    /// Returns a base64 encoded string with markers stripped.
    func markerStrippedBase64() throws -> String {
        var lines = components(separatedBy: "\n").filter { line in
            return !line.hasPrefix(RSA.Constant.beginMarker) && !line.hasPrefix(RSA.Constant.endMarker)
        }
        
        guard lines.count != 0 else {
            throw CryptoError.RSAFailed(reason: .invalidPEMKey(string: self, reason: "Empty PEM key after stripping."))
        }
        
        // Strip off carriage returns in case.
        lines = lines.map { $0.replacingOccurrences(of: "\r", with: "") }
        return lines.joined(separator: "")
    }
}

extension RSA {
    struct Constant {
        static let beginMarker = "-----BEGIN"
        static let endMarker = "-----END"
    }
}

/// Possible ASN.1 types.
/// See https://en.wikipedia.org/wiki/Abstract_Syntax_Notation_One
/// for more information.
enum ASN1Type {
    case sequence
    case integer
    
    var byte: UInt8 {
        switch self {
        case .sequence: return 0x30
        case .integer: return 0x02
        }
    }
}
