import Foundation
import Security

/// How the running build's identity is anchored, and what that means for
/// the Keychain.
///
/// ## Why this type exists
///
/// A file-based Keychain item's access list is bound to the **code
/// signature** of the app that created it. The binding key is the app's
/// *designated requirement* — and there are two kinds:
///
/// * **ad-hoc** (`cdhash H"…"`) — the hash of *this exact build*. The next
///   rebuild produces a different hash, the stored access list no longer
///   matches, and macOS raises an authorization prompt. The prompt is
///   raised by a background `SecurityAgent` that has no window, so the
///   read blocks in `mach_msg2_trap` forever. From the app's side the
///   symptom is a hang on 「服务器启动中」 with no window and no
///   listening port.
/// * **certificate-anchored** (`identifier "com.lagoon.email" and anchor
///   apple generic and certificate leaf[subject.CN] = "…"`) — stable
///   across rebuilds, because it names the certificate rather than the
///   bytes. The stored access list keeps matching and nothing prompts.
///
/// ## The measured truth, and why it is in the code
///
/// This was not reasoned out; it was measured on the machine that reported
/// the hang, with two *different* binaries signed with the same
/// certificate, so the only variable was the build:
///
/// | signature | access list | read after a rebuild |
/// |---|---|---|
/// | ad-hoc | default | **hung** (5 of 5) |
/// | ad-hoc | explicit self-ACL | **hung** (5 of 5) |
/// | certificate | default | ok (5 of 5) |
/// | certificate | explicit self-ACL | ok (5 of 5) |
///
/// The second row is the important one, and it is the reason this type
/// refuses to pretend: **an explicit access list does not rescue an ad-hoc
/// build.** `SecTrustedApplicationCreateFromPath` on ad-hoc code captures
/// the *cdhash* requirement, so the explicit list is exactly as unstable
/// as the default one. Writing it would produce an item that *looks* like
/// it has a durable trust anchor and does not.
///
/// So the honest answer is not "always set an access list". It is: know
/// which kind of anchor the build has, and use the access-list mechanism
/// only when it means something.
///
/// ## Why the detection is a runtime question
///
/// The build's identity is not a compile-time property. The same source
/// tree produces a certificate-anchored bundle on a machine that has a
/// usable certificate and an ad-hoc bundle on one that does not — and
/// `scripts/build-app.sh` chooses per machine, on purpose. So the app
/// asks the system what it actually is, at runtime, rather than assuming.
public enum KeychainTrust: Equatable, Sendable {
    /// The build is anchored to a certificate: the requirement is stable
    /// across rebuilds, and a Keychain item written by this build stays
    /// readable by the next one.
    case designatedRequirement(String)

    /// The build is ad-hoc: the requirement is this build's cdhash, and a
    /// Keychain item written by this build will need re-authorization
    /// after the next rebuild.
    case codeDirectoryHash(String)

    /// Whether the trust anchor survives a rebuild.
    ///
    /// `false` means the app's secrets are tied to *this build*. The next
    /// `swift build` mints a new cdhash, the stored access lists stop
    /// matching, and every launch asks for permission it cannot show.
    public var isStable: Bool {
        if case .designatedRequirement = self { return true }
        return false
    }

    /// The requirement text, whichever kind it is.
    public var requirement: String {
        switch self {
        case .designatedRequirement(let text): return text
        case .codeDirectoryHash(let text): return text
        }
    }

    /// What the running build's trust anchor actually is.
    ///
    /// Reads the *designated requirement* of the running code — the same
    /// thing `codesign -d -r-` prints for the bundle. An unsigned or
    /// ad-hoc process has no certificate anchor, and macOS then expresses
    /// its requirement as a cdhash; that is the shape this type reports as
    /// `.codeDirectoryHash`.
    ///
    /// The lookup cannot fail in a way that matters: a process that cannot
    /// describe its own requirement is a process that should not be writing
    /// secrets, and the caller treats "unknown" as "not stable".
    public static var current: KeychainTrust {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return .codeDirectoryHash("unknown")
        }
        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(
            code as! SecStaticCode, SecCSFlags(rawValue: 0), &requirement
        )
        guard status == errSecSuccess, let requirement else {
            return .codeDirectoryHash("unknown")
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(rawValue: 0), &text) == errSecSuccess,
              let text else {
            return .codeDirectoryHash("unknown")
        }
        let rendered = String(text)
        // A cdhash requirement names the hash of this build. Anything else
        // names a certificate (or a chain) and therefore survives a rebuild.
        if rendered.contains("cdhash") {
            return .codeDirectoryHash(rendered)
        }
        return .designatedRequirement(rendered)
    }
}
