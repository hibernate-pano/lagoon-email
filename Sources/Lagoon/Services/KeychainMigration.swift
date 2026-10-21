import Foundation
import Security

/// The plan for moving a secret from the file-based keychain to the
/// data-protection keychain.
///
/// ## Why this is a pure function
///
/// The migration has one rule that is easy to get wrong and expensive when
/// you do: **never delete the old copy until the new copy is verified**.
/// The rule is also invisible to the type system — it lives in the order of
/// three calls — so it is expressed here as data, decided without touching
/// the Keychain, and tested without touching the Keychain either. A test
/// that needs a real Keychain is a test that hangs on a machine whose
/// Keychain is waiting for authorization, which is exactly the situation
/// this code exists for.
public enum KeychainMigrationPlan: Equatable {
    /// Nothing to do: the value is already in the destination.
    case alreadyPresent
    /// The value is in the source only: copy, verify, then delete.
    case move
    /// The source could not be read. Do not touch anything.
    ///
    /// The reason this is its own case rather than "missing": a failed read
    /// is not proof of absence. If the read is treated as "there is nothing
    /// there", the caller will happily write a fresh default over a secret
    /// that is still sitting in the old keychain — and then, on the next
    /// successful read of the old location, find two different answers.
    case sourceUnreadable
    /// The value is in neither location: there is nothing to migrate.
    case nothingToMigrate

    /// Whether the caller may write a default when the source has no value.
    ///
    /// Only `true` for `.nothingToMigrate`. A failed read must never lead
    /// to a default being written.
    public var mayWriteDefault: Bool {
        self == .nothingToMigrate
    }
}

/// Decides what to do with one secret, from the two read results.
///
/// Both reads are *inputs*, so the decision can be tested without a
/// Keychain — which is the only way to test it on a machine whose Keychain
/// is blocked.
public func keychainMigrationPlan(
    destination: KeychainRead<Data>,
    source: KeychainRead<Data>
) -> KeychainMigrationPlan {
    switch destination {
    case .found:
        // Already migrated (or freshly written). The source is left alone:
        // deleting it is not this function's job, and doing it here would
        // mean deleting a value this code never verified.
        return .alreadyPresent
    case .failed:
        // The destination could not be read. That is not proof that the
        // value is absent there, so nothing may be written.
        return .sourceUnreadable
    case .missing:
        break
    }

    switch source {
    case .found:
        return .move
    case .failed:
        // The source is unreadable. Report it; do not treat as absent.
        return .sourceUnreadable
    case .missing:
        return .nothingToMigrate
    }
}

/// Whether a copy may be treated as landed, from the read-back of the
/// destination.
///
/// ## Why this is separate from the copy itself
///
/// "The old copy may be deleted" is the single irreversible decision in the
/// migration, and it must not be made by the `catch` that happens to sit
/// next to the write. It is decided here, from the read-back alone, so the
/// rule can be tested without a Keychain:
///
/// * the destination reads back **exactly** the bytes that were written —
///   only then is the copy proven;
/// * anything else (a different value, no item, an unreadable item) is a
///   failed copy, and the old item stays where it is.
///
/// A write that silently failed, or one that a *different* writer raced, is
/// indistinguishable from success at the `SecItemUpdate` return code — which
/// is why the comparison is against the bytes, not against the status.
public func keychainCopyIsVerified(source: Data, readBack: KeychainRead<Data>) -> Bool {
    switch readBack {
    case .found(let written):
        return written == source
    case .missing, .failed:
        return false
    }
}

/// The result of running a migration.
public enum KeychainMigrationOutcome: Equatable {
    /// The value was already in the destination.
    case alreadyPresent
    /// The value was copied to the destination and the old copy removed.
    case moved
    /// The value was copied and verified, but the old copy could not be
    /// removed.
    ///
    /// This is a success with a leftover, not a failure: the new copy is
    /// good, so the app works, and the old copy is harmless because reads
    /// prefer the destination.
    case copiedOldCopyKept
    /// There was nothing to migrate.
    case nothingToMigrate
    /// The source could not be read, so nothing was touched.
    case sourceUnreadable
    /// The copy to the destination failed. The old copy is intact.
    case copyFailed
}

/// Copies one secret from the file-based keychain to the data-protection
/// keychain, in the only safe order: **copy, verify, then delete**.
///
/// ## Why the order is not negotiable
///
/// The old copy is the user's only copy of their account id, their token
/// key, their body key and their API token. Deleting it before the new one
/// is proven readable means a failure anywhere in the middle destroys the
/// secret: the user has to re-connect and re-enter their QQ auth code, and
/// the body key's loss drops every cached mail body. So:
///
/// 1. **copy** — write the value to the destination.
/// 2. **verify** — read it back from the destination and compare. A write
///    that silently failed is worse than no write.
/// 3. **delete** — only now, and only the item this function just wrote.
///
/// A failure at step 1 or 2 leaves the old copy exactly where it was.
///
/// ## Why the source read has a deadline
///
/// The source is the file-based keychain, which is exactly where a
/// signature-mismatched item lives — and reading its data can block
/// forever. So the source read goes through `KeychainReader`, which
/// returns within a bounded time and reports "present but unreadable"
/// rather than hanging. When that happens the outcome is
/// `sourceUnreadable` and **nothing is touched**: the value stays where
/// it is, and the user is told that the Keychain needs their attention.
public func migrateKeychainItem(
    service: String,
    source: KeychainLocation = .file,
    destination: KeychainLocation = .dataProtection,
    timeout: TimeInterval = KeychainReader.readTimeout
) async -> KeychainMigrationOutcome {
    // 0. Decide, without touching anything.
    //
    // Both reads name their location explicitly. A location-less read would
    // search both and, with a value in the source, would answer "found"
    // for *both* inputs — so the plan could never see `destination:
    // .missing, source: .found` and the migration would never run. Worse,
    // it would make a copy that had failed look verified, because the
    // read-back would find the old copy.
    let sourceRead = await KeychainReader.readRaw(
        service: service,
        location: source,
        timeout: timeout
    )
    let destinationRead = await KeychainReader.readRaw(
        service: service,
        location: destination,
        timeout: timeout
    )

    switch keychainMigrationPlan(destination: destinationRead, source: sourceRead) {
    case .alreadyPresent:
        return .alreadyPresent
    case .sourceUnreadable:
        return .sourceUnreadable
    case .nothingToMigrate:
        return .nothingToMigrate
    case .move:
        break
    }

    // 1. Copy.
    guard case .found(let value) = sourceRead else {
        return .sourceUnreadable
    }
    do {
        try KeychainStore.save(data: value, service: service, location: destination)
    } catch {
        // The old copy is untouched. Report the failure.
        return .copyFailed
    }

    // 2. Verify: read it back and compare. Never trust the write.
    //
    // The verification read goes through the *bounded* reader as well: the
    // destination is normally painless, but "normally" is not a guarantee
    // worth betting the boot on, and a migration that hangs is a boot that
    // never finishes.
    let readBack = await KeychainReader.readRaw(
        service: service,
        location: destination,
        timeout: timeout
    )
    guard keychainCopyIsVerified(source: value, readBack: readBack) else {
        // The write did not land, or cannot be proven. The old copy stays.
        return .copyFailed
    }

    // 3. Only now is it safe to remove the old copy.
    let deleteStatus = SecItemDelete(
        KeychainStore.deleteQuery(service: service, location: source) as CFDictionary
    )
    guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
        // The new copy is good; the old one stays. Harmless.
        return .copiedOldCopyKept
    }
    return .moved
}
