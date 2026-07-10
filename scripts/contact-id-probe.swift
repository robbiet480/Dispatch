// Contact-identifier probe (macOS side of the cross-device experiment).
// Prints name + CNContact.identifier for the first ~15 contacts, sorted by
// name, so the same listing from an iPhone probe can be diffed against it.
import Contacts
import Foundation

let store = CNContactStore()
let semaphore = DispatchSemaphore(value: 0)
var granted = false
store.requestAccess(for: .contacts) { ok, error in
    granted = ok
    if let error { FileHandle.standardError.write(Data("access error: \(error)\n".utf8)) }
    semaphore.signal()
}
semaphore.wait()
guard granted else {
    FileHandle.standardError.write(Data("Contacts access not granted to this terminal process.\n".utf8))
    exit(1)
}

let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactIdentifierKey] as [CNKeyDescriptor]
let request = CNContactFetchRequest(keysToFetch: keys)
request.sortOrder = .familyName
var rows: [(String, String)] = []
try store.enumerateContacts(with: request) { contact, stop in
    let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return }
    rows.append((name, contact.identifier))
    if rows.count >= 15 { stop.pointee = true }
}
print("=== macOS contact identifiers (\(rows.count)) ===")
for (name, id) in rows { print("\(id)  \(name)") }
