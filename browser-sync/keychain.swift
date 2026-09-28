// Small native Keychain adapter. Snapshot bytes travel over stdin/stdout, never argv.
import Foundation
import Security

func fail() -> Never {
    FileHandle.standardError.write(Data("Keychain operation failed\n".utf8))
    exit(1)
}
let args = CommandLine.arguments
if args.count != 3 { fail() }
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "ai.macleodlabs.claude_sessions.browser",
    kSecAttrAccount as String: args[2]
]
switch args[1] {
case "save":
    let data = FileHandle.standardInput.readDataToEndOfFile()
    if data.count > 1_000_000 || data.isEmpty { fail() }
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
        var item = query
        item[kSecValueData as String] = data
        if SecItemAdd(item as CFDictionary, nil) != errSecSuccess { fail() }
    } else if status != errSecSuccess { fail() }
case "load":
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    if SecItemCopyMatching(lookup as CFDictionary, &result) != errSecSuccess { fail() }
    guard let data = result as? Data else { fail() }
    FileHandle.standardOutput.write(data)
default:
    fail()
}
