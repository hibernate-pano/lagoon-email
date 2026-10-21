import SwiftUI
import LagoonKit

/// 「改分组」 — choose a group, and choose how far the change reaches.
///
/// ## Why this is a sheet and not a confirmation dialog
///
/// A `confirmationDialog` can carry a message, but it cannot carry a
/// **per-option** explanation. The decision here is two-dimensional — which
/// group, and which scope — and the scope explanation has to sit next to
/// the scope buttons, because that is where the user decides. A dialog
/// would put one explanation above a flat list of buttons, and the user
/// would be reading one thing while choosing another.
///
/// The scope also has to be chosen **before** the group, or at least
/// alongside it: the two options produce genuinely different results, and
/// the narrow one is the safe default, so it is what a single click on the
/// menu lands on.
///
/// ## Why the safe default is 「只改这一封」
///
/// The user opened this from **one mail**. The broad option changes every
/// mail from that sender, which is a larger act than the gesture that
/// opened the sheet. So the sheet opens on the narrow scope, and the broad
/// option is a deliberate second choice — never the default.
struct OverrideScopeSheet: View {
    /// The sender whose mail is being re-filed. Shown in full, because
    /// "every mail from this sender" is only meaningful if the user can see
    /// which sender.
    let senderAddress: String
    /// The group the mail is in now, so the user can see where it came
    /// from.
    let currentGroup: BriefingGroup?
    /// The groups the user can move to. `.pinned` is excluded — pinning is
    /// its own verb.
    let availableGroups: [BriefingGroup]
    /// Called with the chosen group and scope.
    let onApply: (BriefingGroup, OverrideScope) -> Void

    @Environment(\.l10n) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var scope: OverrideScope = .message
    @State private var group: BriefingGroup

    init(
        senderAddress: String,
        currentGroup: BriefingGroup?,
        availableGroups: [BriefingGroup],
        onApply: @escaping (BriefingGroup, OverrideScope) -> Void
    ) {
        self.senderAddress = senderAddress
        self.currentGroup = currentGroup
        self.availableGroups = availableGroups
        self.onApply = onApply
        // The narrow scope is the default: the user opened this from one
        // mail, and the broad option changes more than the gesture implied.
        _scope = State(initialValue: .message)
        _group = State(initialValue: availableGroups.first ?? .needsReply)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.overrideScopeTitle)
                    .font(.headline)
                // Where the mail is now. "Move it out of 需要回复" is a
                // different decision from "move it somewhere", and the
                // current group is the one fact that makes the first
                // reading available.
                if let currentGroup {
                    Text(l10n.overrideCurrentGroup(l10n.groupTitle(currentGroup)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                // The scope's consequence, stated before the choice and
                // restated under the buttons: this is the sentence that
                // makes the difference between the two options visible.
                Text(scope == .message
                    ? l10n.overrideMessageScopeBody(sender: senderAddress)
                    : l10n.overrideSenderScopeBody(sender: senderAddress))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            Picker(l10n.overrideScopePrompt, selection: $scope) {
                Text(l10n.overrideScopeMessageOnly).tag(OverrideScope.message)
                Text(l10n.overrideScopeSenderAll).tag(OverrideScope.sender)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // The groups. A `Picker` in a menu style, because the sheet is
            // about *choosing*, and a menu picker is the shape macOS users
            // already know.
            Picker(l10n.overrideScopeTitle, selection: $group) {
                ForEach(availableGroups, id: \.self) { candidate in
                    Text(l10n.groupTitle(candidate)).tag(candidate)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            // The pointer to the other grouping mechanism. 「改分组」 and the
            // sidebar's 「我的分组」 both group mail, but they are two
            // different mechanisms — so the sheet says where the other one
            // lives instead of pretending they are the same thing.
            Text(l10n.overrideSidebarGroupsNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider()

            HStack {
                Spacer()
                // `dismiss()` is load-bearing: an empty button body would
                // leave the sheet open with no way out except the window's
                // close button — a dead end the user reaches by changing
                // their mind about the scope.
                Button(l10n.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(l10n.overrideScopeConfirm) {
                    onApply(group, scope)
                    // Close the sheet once the change is on its way. The
                    // request is async, so the sheet does not wait for it —
                    // the toast in the reader reports the outcome, and a
                    // sheet that stayed open would hide the mail the user
                    // is trying to re-check.
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460)
    }
}
