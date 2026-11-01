//! Can a Rust process read the Swift app's Keychain items?
//!
//! The Swift side (Sources/Lagoon/Services/KeychainStore.swift:92-102 and :336)
//! writes generic-password items with service in {lagoon.bodyKey,
//! lagoon.tokenKey, lagoon.apiTokenSecret, lagoon.envJSON}, account "primary",
//! into the DATA-PROTECTION keychain (kSecUseDataProtectionKeychain = true).
//!
//! This probe never asks for secret bytes: `load_data` stays false, so
//! SecItemCopyMatching returns attributes only. It prints counts and OSStatus
//! codes, never a secret.
//!
//! modes:
//!   (no args)        probe the app's services in both keychain locations
//!   --keychain PATH   ~ control experiment: search a throwaway keychain we create

use security_framework::item::{ItemClass, ItemSearchOptions, Limit, SearchResult};
use security_framework::os::macos::keychain::SecKeychain;

const SERVICES: [&str; 4] = [
    "lagoon.bodyKey",
    "lagoon.tokenKey",
    "lagoon.apiTokenSecret",
    "lagoon.envJSON",
];

fn search(service: &str, account: Option<&str>, dp: bool, kc: Option<&SecKeychain>) -> (usize, i32) {
    let mut opts = ItemSearchOptions::new();
    opts.class(ItemClass::generic_password())
        .service(service)
        .load_refs(false)
        .load_attributes(true)
        .limit(Limit::All);
    if let Some(a) = account {
        opts.account(a);
    }
    match kc {
        Some(kc) => {
            opts.keychains(std::slice::from_ref(kc));
        }
        None => {
            if dp {
                opts.ignore_legacy_keychains();
            }
        }
    }
    match opts.search() {
        Ok(results) => (
            results
                .iter()
                .filter(|r| !matches!(r, SearchResult::Ref(_)))
                .count(),
            0,
        ),
        Err(e) => (0, e.code()),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(|s| s.as_str()) == Some("--keychain") {
        let path = &args[1];
        let kc = SecKeychain::open(path).expect("open keychain");
        println!("control: searching throwaway keychain {path}");
        let (n, err) = search("lagoon.probe", Some("primary"), false, Some(&kc));
        println!("  service=lagoon.probe account=primary -> items={n} osstatus={err}");
        return;
    }

    // Account is left unset on purpose: a wrong account string would look
    // exactly like "item absent" (errSecItemNotFound), which is the mistake
    // this probe exists to avoid.
    println!("probe: attributes-only SecItemCopyMatching; secrets are never requested");
    println!("{:<24} {:>14} {:>16}", "service", "dp_keychain", "login_keychain");
    for svc in SERVICES {
        let (dp_n, dp_err) = search(svc, None, true, None);
        let (lk_n, lk_err) = search(svc, None, false, None);
        let fmt = |n: usize, err: i32| {
            if err != 0 {
                format!("err {err}")
            } else {
                format!("{n} item(s)")
            }
        };
        println!(
            "{:<24} {:>14} {:>16}",
            svc,
            fmt(dp_n, dp_err),
            fmt(lk_n, lk_err)
        );
    }
}
