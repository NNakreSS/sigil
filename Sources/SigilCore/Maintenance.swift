import Foundation

/// A package `apt` would upgrade.
public struct UpgradablePackage: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var version: String
    public var security: Bool
}

/// Updating and restarting a server. Updates run in a terminal tab so the user watches apt work (and can answer a
/// sudo password prompt); the preview and the restart run in the background.
public enum MaintenanceScript {
    /// Lists upgradable packages after a quiet `apt-get update` when Sigil may (root or password-less sudo), so the
    /// preview reflects today's archive rather than a stale cache.
    static let preview = #"""
    S=""; [ "$(id -u)" -eq 0 ] || S="sudo -n"
    $S apt-get -qq update >/dev/null 2>&1
    apt list --upgradable 2>/dev/null | tail -n +2
    exit 0
    """#

    /// One line for `ssh -t <alias> '<this>'`: update and upgrade (including the new packages a kernel update needs),
    /// say whether a restart is needed, then leave the user in a shell on the server.
    public static let updateCommand = [
        #"S=""; [ "$(id -u)" -eq 0 ] || S=sudo"#,
        #"echo "Sigil: paket listesi yenileniyor…""#,
        #"$S env DEBIAN_FRONTEND=noninteractive apt-get update"#,
        #"&& $S env DEBIAN_FRONTEND=noninteractive apt-get -y --with-new-pkgs -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade"#,
        #"; rc=$?; echo"#,
        #"; if [ $rc -eq 0 ]; then echo "Sigil: güncelleme tamamlandı."; else echo "Sigil: güncelleme hata verdi (çıkış kodu $rc)."; fi"#,
        #"; if [ -f /var/run/reboot-required ]; then echo "Sigil: yeniden başlatma gerekiyor. Sigil’de “Yeniden başlat”ı kullanabilirsin."; fi"#,
        #"; echo; exec "${SHELL:-/bin/sh}" -l"#,
    ].joined(separator: " ")

    /// Schedules the restart two seconds out, detached, so this ssh session ends cleanly first.
    /// Exit 3: not root and sudo would ask for a password.
    static let reboot = #"""
    if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then exit 3; fi
    S=""; [ "$(id -u)" -eq 0 ] || S="sudo -n"
    # sudo first, so the whole job runs as root (and Sigil's sudo-with-password helper covers it).
    $S nohup sh -c "sleep 2; systemctl reboot || reboot" </dev/null >/dev/null 2>&1 &
    echo scheduled
    """#

    /// `apt list --upgradable` lines: `name/suite[,suite] version arch [upgradable from: old]`.
    public static func parseUpgradable(_ text: String) -> [UpgradablePackage] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let slash = line.firstIndex(of: "/") else { return nil }
            let name = String(line[..<slash])
            let rest = line[line.index(after: slash)...].split(separator: " ")
            guard !name.isEmpty, rest.count >= 2 else { return nil }
            return UpgradablePackage(name: name, version: String(rest[1]), security: rest[0].contains("-security"))
        }
        .sorted { ($0.security ? 0 : 1, $0.name) < ($1.security ? 0 : 1, $1.name) }
    }
}

extension RemoteService {
    public func upgradablePackages(target: RemoteTarget, auth: RemoteAuth) async throws -> [UpgradablePackage] {
        let r = try await execute(target, auth, "sh -s", stdin: MaintenanceScript.preview, timeout: 180)
        guard r.exitCode != 255, !r.timedOut else { throw failure(r, auth) }
        return MaintenanceScript.parseUpgradable(r.stdout)
    }

    func scheduleReboot(target: RemoteTarget, auth: RemoteAuth) async throws {
        let r = try await execute(target, auth, "sh -s", stdin: MaintenanceScript.reboot)
        if r.exitCode == 3 {
            throw DeckError.ssh("Bu kullanıcı için sudo parola istiyor. Yeniden başlatmayı terminalden yap: sudo reboot")
        }
        guard r.succeeded, r.stdout.contains("scheduled") else { throw failure(r, auth) }
    }
}

public enum RebootPhase: Equatable, Sendable {
    case requesting, goingDown, comingUp, verifying
}

extension DeckModel {
    public func upgradablePackages(_ id: UUID) async throws -> [UpgradablePackage] {
        guard let s = server(id) else { throw DeckError.notFound }
        return try await withBusy(id, "Güncellemeler denetleniyor") {
            try await remote.upgradablePackages(target: sharedTarget(for: s), auth: auth(s.store, s.keyFileName))
        }
    }

    /// Restarts the server and waits for it to come back. Returns how long it was unreachable.
    /// Reachability is watched with ssh-keyscan (no key use, so no Touch ID prompts while waiting).
    @discardableResult
    public func reboot(_ id: UUID, progress: @MainActor (RebootPhase) -> Void = { _ in },
                       timeout: TimeInterval = 600, pollEvery: TimeInterval = 3) async throws -> TimeInterval {
        guard let s = server(id) else { throw DeckError.notFound }
        return try await withBusy(id, "Yeniden başlatılıyor") {
            progress(.requesting)
            try await remote.scheduleReboot(target: sharedTarget(for: s), auth: auth(s.store, s.keyFileName))
            log(id, .warning, "Yeniden başlatma istendi.")

            progress(.goingDown)
            let deadline = Date().addingTimeInterval(timeout)
            func answering() async -> Bool { (try? await scanKeys(host: s.host, port: s.port, jumpID: s.jumpServerID)) != nil }
            var downSince: Date?
            // Wait for it to stop answering (a quick restart may be missed; then the boot time tells).
            let downDeadline = Date().addingTimeInterval(min(120, timeout))
            while Date() < downDeadline {
                if !(await answering()) { downSince = Date(); break }
                try await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
            }
            let start = downSince ?? Date()

            progress(.comingUp)
            while Date() < deadline {
                if await answering() {
                    let downtime = Date().timeIntervalSince(start)
                    progress(.verifying)
                    update(id) { $0.lastCheckedAt = Date(); $0.lastReachable = true }
                    log(id, .info, "Yeniden başlatıldı; \(Int(downtime)) saniyede geri geldi.")
                    return downtime
                }
                try await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
            }
            update(id) { $0.lastCheckedAt = Date(); $0.lastReachable = false }
            log(id, .error, "Yeniden başlatıldıktan sonra \(Int(timeout / 60)) dakika içinde geri gelmedi.")
            throw DeckError.ssh("Sunucu \(Int(timeout / 60)) dakika içinde geri gelmedi. Sağlayıcının konsolundan kontrol et.")
        }
    }
}
