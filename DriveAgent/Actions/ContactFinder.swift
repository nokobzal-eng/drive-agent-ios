import Contacts
import Foundation

struct ContactMatch {
    let name: String
    let phone: String
}

enum ContactFinder {
    private static let store = CNContactStore()

    static func requestAccess() async {
        _ = try? await store.requestAccess(for: .contacts)
    }

    static func find(_ query: String) throws -> [ContactMatch] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: query)
        return try store.unifiedContacts(matching: predicate, keysToFetch: keys).compactMap { contact in
            let mobile = contact.phoneNumbers.first {
                $0.label == CNLabelPhoneNumberMobile || $0.label == CNLabelPhoneNumberiPhone
            }
            guard let number = (mobile ?? contact.phoneNumbers.first)?.value.stringValue else { return nil }
            let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            return ContactMatch(name: name, phone: number)
        }
    }
}
