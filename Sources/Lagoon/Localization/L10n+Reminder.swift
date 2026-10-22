import Foundation

/// The strings that keep the reminder promise honest.
///
/// ## Why this file exists
///
/// A reminder is the one feature in the app whose whole value is a
/// promise about the future: 「到点会提醒你」. Every other promise the
/// app makes is discharged inside the app, where a failure can be shown
/// right away. This one is discharged by the operating system, minutes
/// or hours later, with the app closed — so the only moment at which
/// the user can be told "this will not happen" is the moment they set
/// it.
///
/// That is what these strings are for. They live in their own file so
/// the feature that says what it does and the feature that defines it
/// can change without both editing the same 2000-line file.
///
/// ## What they must never do
///
/// They must not promise delivery the app cannot guarantee. Delivery
/// needs the system's permission, and the system's permission is
/// something the user grants — or does not. So the copy states the
/// condition ("with system notifications on") instead of the hope
/// ("you will be notified"), and the reminder sheet is where the
/// condition is made explicit.
extension L10n {
    // MARK: - Delivery: the reminder sheet

    /// Shown in the reminder sheet when the system cannot ring it.
    ///
    /// The wording is about what happens, not about what is missing:
    /// "this will not ring" is a fact the user can act on, while "you
    /// have not enabled notifications" is a configuration detail that
    /// makes them go looking for a switch they may not be able to find.
    public var reminderNotificationsOff: String {
        pick(
            "系统通知未开启，这个提醒到点不会响。",
            "System notifications are off — this reminder will not ring."
        )
    }

    /// The line under that warning: why the notification matters.
    public var reminderNotificationsOffHelp: String {
        pick(
            "提醒要靠系统通知才能在到点时找到你。",
            "A reminder needs system notifications to reach you on time."
        )
    }

    /// The button that turns notifications on from the reminder sheet.
    public var reminderEnableNotifications: String {
        pick("开启通知", "Turn on notifications")
    }

    /// Shown when the system refused the permission.
    ///
    /// The app cannot ask again — the system's answer is final until
    /// the user changes it in System Settings — so the copy says where
    /// the change happens instead of offering a button that would do
    /// nothing.
    public var reminderNotificationsDeniedHelp: String {
        pick(
            "系统通知已被拒绝。到「系统设置 › 通知」里允许 Lagoon，提醒才会响。",
            "Notifications are turned off for Lagoon. Allow them in System Settings › Notifications for the reminder to ring."
        )
    }

    /// Shown after the reminder is stored, while the system still
    /// cannot ring it.
    ///
    /// It says two things, because both are true and the user needs
    /// both: the reminder is saved (it is on the list, it is not lost),
    /// and it will not ring (the system is not going to deliver it).
    public var reminderSavedNotArmed: String {
        pick(
            "提醒已保存，但到点不会响——系统通知没开。",
            "Reminder saved, but it will not ring — system notifications are off."
        )
    }

    /// The button that accepts the outcome and closes the sheet.
    public var reminderAcknowledge: String { pick("知道了", "Got it") }

    // MARK: - Delivery: the reminders panel

    /// The title on the banner that says the reminders cannot ring.
    public var reminderNotArmedTitle: String {
        pick("提醒不会响", "Reminders will not ring")
    }

    /// The banner detail: how many, and why.
    public func reminderNotArmedDetail(_ count: Int) -> String {
        pick(
            "\(count) 个提醒已保存，但系统通知未开启，到点不会响。",
            "\(count) reminder\(count == 1 ? "" : "s") saved, but system notifications are off — they will not ring."
        )
    }

    /// The line under the list: how many reminders the system is holding.
    ///
    /// It is a count of what the system is actually holding, so it is
    /// the number the system would ring for — not the number of rows on
    /// the list.
    public func reminderArmedCount(_ count: Int) -> String {
        pick(
            "已安排 \(count) 个到点提醒",
            "\(count) reminder\(count == 1 ? "" : "s") armed"
        )
    }

    // MARK: - The confirmation

    /// The confirmation after a reminder was stored.
    ///
    /// It states what was stored and when it is due, and nothing more.
    /// A confirmation that said "you will be reminded" would be a
    /// promise — and the delivery depends on a switch the user may
    /// have left off. The caveat belongs in the sheet, where the user
    /// can act on it.
    public func reminderSetConfirmation(_ date: Date) -> String {
        let when = reminderDateFormatter.string(from: date)
        return pick("已设好提醒，\(when)。", "Reminder set for \(when).")
    }
}
