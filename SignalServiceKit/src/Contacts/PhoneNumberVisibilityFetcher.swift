//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

public protocol PhoneNumberVisibilityFetcher {
    /// Fetches whether or not a phone number is visible.
    func isPhoneNumberVisible(for recipient: SignalRecipient, tx: DBReadTransaction) -> Bool

    /// Pre-fetches state about visible phone numbers.
    ///
    /// This is useful during `SignalServiceAddressCache`'s `warmCaches` method
    /// because we're checking every ACI we know and expect there to be far more
    /// known ACIs than ACIs that are sharing their phone number.
    func fetchAll(tx: DBReadTransaction) throws -> BulkPhoneNumberVisibilityFetcher
}

private func _isPhoneNumberVisible(
    for recipient: SignalRecipient,
    localAci: () -> Aci?,
    isPhoneNumberShared: (Aci) -> Bool,
    isSystemContact: (_ phoneNumber: String) -> Bool
) -> Bool {
    // If there's no ACI, the phone number can't be hidden. (You hide a number
    // via your encrypted profile, and that only exists for ACIs.)
    guard let aci = recipient.aci, let phoneNumber = recipient.phoneNumber else {
        return true
    }
    return (aci == localAci()) || isPhoneNumberShared(aci) || isSystemContact(phoneNumber.stringValue)
}

public final class PhoneNumberVisibilityFetcherImpl: PhoneNumberVisibilityFetcher {
    private let contactsManager: any ContactsManagerProtocol
    private let tsAccountManager: any TSAccountManager
    private let userProfileStore: any UserProfileStore

    init(
        contactsManager: any ContactsManagerProtocol,
        tsAccountManager: any TSAccountManager,
        userProfileStore: any UserProfileStore
    ) {
        self.contactsManager = contactsManager
        self.tsAccountManager = tsAccountManager
        self.userProfileStore = userProfileStore
    }

    public func isPhoneNumberVisible(for recipient: SignalRecipient, tx: DBReadTransaction) -> Bool {
        return _isPhoneNumberVisible(
            for: recipient,
            localAci: {
                tsAccountManager.localIdentifiers(tx: tx)?.aci
            },
            isPhoneNumberShared: {
                userProfileStore.fetchUserProfiles(for: $0, tx: tx).first.isPhoneNumberSharedOrDefault
            },
            isSystemContact: {
                contactsManager.fetchSignalAccount(forPhoneNumber: $0, transaction: SDSDB.shimOnlyBridge(tx)) != nil
            }
        )
    }

    public func fetchAll(tx: DBReadTransaction) throws -> BulkPhoneNumberVisibilityFetcher {
        return BulkPhoneNumberVisibilityFetcher(
            localAci: tsAccountManager.localIdentifiers(tx: tx)?.aci,
            acisWithSharedPhoneNumbers: Set(
                try UserProfileFinder().fetchAcisWithSharedPhoneNumbers(tx: SDSDB.shimOnlyBridge(tx))
            ),
            phoneNumbersWithSystemContacts: Set(
                try SignalAccountFinder().fetchPhoneNumbers(tx: SDSDB.shimOnlyBridge(tx))
            )
        )
    }
}

public final class BulkPhoneNumberVisibilityFetcher {
    private let localAci: Aci?
    private let acisWithSharedPhoneNumbers: Set<Aci>
    private let phoneNumbersWithSystemContacts: Set<String>

    init(
        localAci: Aci?,
        acisWithSharedPhoneNumbers: Set<Aci>,
        phoneNumbersWithSystemContacts: Set<String>
    ) {
        self.localAci = localAci
        self.acisWithSharedPhoneNumbers = acisWithSharedPhoneNumbers
        self.phoneNumbersWithSystemContacts = phoneNumbersWithSystemContacts
    }

    func isPhoneNumberVisible(for recipient: SignalRecipient) -> Bool {
        return _isPhoneNumberVisible(
            for: recipient,
            localAci: { localAci },
            isPhoneNumberShared: { acisWithSharedPhoneNumbers.contains($0) },
            isSystemContact: { phoneNumbersWithSystemContacts.contains($0) }
        )
    }
}

#if TESTABLE_BUILD

final class MockPhoneNumberVisibilityFetcher: PhoneNumberVisibilityFetcher {
    var localAci: Aci?
    var acisWithSharedPhoneNumbers = Set<Aci>()
    var phoneNumbersWithSystemContacts = Set<String>()

    func isPhoneNumberVisible(for recipient: SignalRecipient, tx: DBReadTransaction) -> Bool {
        return try! fetchAll(tx: tx).isPhoneNumberVisible(for: recipient)
    }

    func fetchAll(tx: DBReadTransaction) throws -> BulkPhoneNumberVisibilityFetcher {
        return BulkPhoneNumberVisibilityFetcher(
            localAci: localAci,
            acisWithSharedPhoneNumbers: acisWithSharedPhoneNumbers,
            phoneNumbersWithSystemContacts: phoneNumbersWithSystemContacts
        )
    }
}

#endif
