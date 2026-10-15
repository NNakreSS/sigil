import SigilCore
import SwiftUI

/// The tour: what Sigil does, one topic per page, with the shortcuts and a button to try each thing.
struct TourSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Environment(DeckModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State var page: Int

    struct Page {
        let symbol: String
        let tint: Color
        let title: String
        let lead: String
        let points: [(String, String?)]   // text, shortcut
    }

    static let pages: [Page] = [
        Page(symbol: "seal", tint: .accentInk, title: "Her sunucuya kendi mührü",
             lead: "Sunucuyu bir kez eklersin; gerisini Sigil yapar.",
             points: [("Adres, kullanıcı ve şifreyi bir kez gir; şifre bir kez kullanılır, saklanmaz.", "⌘N"),
                      ("Sigil o sunucuya özel bir anahtar üretir, kurar ve düzenli yeniler.", nil),
                      ("Terminalde artık yalnızca ssh <ad> yazman yeterli.", nil),
                      ("Var olan ~/.ssh/config sunucularını tek tıkla devral.", "⇧⌘I")]),
        Page(symbol: "touchid", tint: .verdigris, title: "Anahtar sende kalır",
             lead: "Gizli anahtar Mac’inden hiç çıkmaz; sunucuya yalnızca açık anahtar gider.",
             points: [("Secure Enclave: anahtar Mac’in güvenlik çipinde, girişte Touch ID.", nil),
                      ("Bir onay seçtiğin süre geçerli kalır; ekran kilitlenince biter.", nil),
                      ("Menü çubuğundaki kilit, onayları anında kapatır.", nil),
                      ("Bir şüphe varsa tüm anahtarları tek tuşla yenile.", "⌥⇧⌘R")]),
        Page(symbol: "terminal", tint: .accentInk, title: "Terminal, sekmeli ve hızlı",
             lead: "Sunucular arasında sekmelerle geç; tema ve yazı tipini kendine göre ayarla.",
             points: [("Seçili sunucuya bağlan", "⌘T"), ("Herhangi bir sunucuya hızlı bağlan", "⌘K"),
                      ("Sekmeler arasında geç", "⌘1…9"), ("Yan yana böl / birleştir", "⌘D"),
                      ("Çıktıda ara", "⌘F"), ("Yazı boyutu", "⌘+ ⌘-")]),
        Page(symbol: "command", tint: .amberInk, title: "Komut ezberleme",
             lead: "134 hazır komut, sunucunda neler kuruluysa ona göre.",
             points: [("Komut paleti: “disk”, “nginx log” yaz, seç", "⌘P"),
                      ("Yazarken öneri belirir, Tab tamamlar", "⇥"),
                      ("İsteğini yaz, yapay zekâ komut önersin (cihaz içi)", "⌘P"),
                      ("Seçtiğin hata metnini açıklat", "⇧⌘E")]),
        Page(symbol: "waveform.path.ecg", tint: .verdigris, title: "Sunucunu tanı, bakımını yap",
             lead: "Neyin bozuk olduğunu adıyla gör, düzeltmeyi tek yerden başlat.",
             points: [("Sağlık: disk, bellek, çöken servisler, güncellemeler, SSL", nil),
                      ("Güncelle: önce listeyi gör, sonra terminalde canlı izle", nil),
                      ("Yeniden başlat: geri gelene kadar bekler", nil),
                      ("Sertleştir: şifreli girişi kapat, güvenlik duvarı kur; hata olursa sunucu kendini geri alır", nil),
                      ("Sigil dışından eklenmiş anahtarları gör ve kaldır", nil)]),
        Page(symbol: "square.grid.2x2", tint: .accentInk, title: "Dosyalar, Docker, tüneller, erişim",
             lead: "Sunucu ekranındaki butonlardan.",
             points: [("Dosyalar: gez, önizle, sürükle-bırak yükle, indir", nil),
                      ("Docker: container’lar, loglar, yeniden başlatma", nil),
                      ("Tüneller: sunucudaki veritabanına Mac’inden güvenle bağlan", nil),
                      ("Erişim ver: arkadaşına şifre paylaşmadan, süreli giriş izni", nil)]),
    ]

    var body: some View {
        let p = Self.pages[page]
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Kapat") { finish() }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.top, 14)

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(p.tint.opacity(0.14)).frame(width: 64, height: 64)
                        Image(systemName: p.symbol).font(.system(size: 28, weight: .medium)).foregroundStyle(p.tint)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.title).font(.engraved(24, weight: .bold))
                        Text(p.lead).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(p.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(p.tint.opacity(0.8)).font(.callout)
                            Text(point.0).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if let key = point.1 {
                                Text(key).font(.callout.monospaced().weight(.semibold))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                }
                .padding(16)
                .background(Color.vellum, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline))
                tryButtons
            }
            .padding(.horizontal, 28).padding(.vertical, 8)
            .id(page)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))

            Spacer(minLength: 12)
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<Self.pages.count, id: \.self) { i in
                        Circle().fill(i == page ? Color.accentInk : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                            .onTapGesture { withAnimation(Motion.gentle) { page = i } }
                    }
                }
                Spacer()
                if page > 0 { Button("Geri") { withAnimation(Motion.gentle) { page -= 1 } } }
                if page < Self.pages.count - 1 {
                    Button("İleri") { withAnimation(Motion.gentle) { page += 1 } }
                        .buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    Button("Başla") { finish() }.buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
        }
        .frame(width: 620, height: 560)
        .background(Color.parchment)
    }

    /// "Try it" buttons for the page's topic.
    @ViewBuilder private var tryButtons: some View {
        let server = router.selection.flatMap { model.server($0) } ?? model.servers.first
        HStack(spacing: 10) {
            switch page {
            case 0:
                try_("Sunucu ekle", "plus") { router.showingAdd = true }
                if !model.importCandidates().isEmpty { try_("İçe aktar", "square.and.arrow.down") { router.showingImport = true } }
            case 1:
                try_("Anahtar ayarları", "key") { openSettings() }
            case 2:
                if let server { try_("\(server.alias)’e bağlan", "terminal") { router.connect(server) } }
            case 3:
                if let server {
                    try_("Komut paletini aç", "command") {
                        router.connect(server)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { router.terminals.showingPalette = true }
                    }
                }
            case 4:
                if let server { try_("\(server.alias) sunucusunu aç", "waveform.path.ecg") { router.selection = server.id; router.mode = .overview } }
            default:
                if let server { try_("Dosyaları aç", "folder") { router.panel = .init(serverID: server.id, kind: .files) } }
            }
        }
    }

    private func try_(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button {
            finish()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: action)
        } label: { Label(title, systemImage: symbol) }
        .buttonStyle(.bordered)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "tourSeen")
        dismiss()
    }
}

/// On the empty screen: what Sigil can do, each tile opening the tour at that topic.
struct FeatureTiles: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            ForEach(Array(TourSheet.pages.enumerated()), id: \.offset) { i, p in
                Button {
                    router.tourPage = i
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: p.symbol).font(.title3).foregroundStyle(p.tint)
                        Text(p.title).font(.engraved(14)).multilineTextAlignment(.leading)
                        Text(p.lead).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                    .padding(14)
                    .background(Color.vellum, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .frame(maxWidth: 660)
    }
}

/// On a newly added server: the next useful steps, ticked off as they happen; can be hidden.
struct NextStepsCard: View {
    @Environment(AppRouter.self) private var router
    @Environment(DeckModel.self) private var model
    let server: Server
    let harden: () -> Void
    let grant: () -> Void
    @AppStorage("nextStepsHidden") private var hiddenIDs = ""

    static func shouldShow(_ s: Server, hidden: String) -> Bool {
        !hidden.contains(s.id.uuidString) && Date().timeIntervalSince(s.createdAt) < 14 * 86400
    }

    var body: some View {
        if Self.shouldShow(server, hidden: hiddenIDs) {
            let hardened = server.events.contains { $0.message.hasPrefix("Sertleştirme uygulandı") }
            let connected = router.terminals.sessions.contains { $0.serverID == server.id }
                || UserDefaults.standard.stringArray(forKey: "connectedServers")?.contains(server.id.uuidString) == true
            Card(title: "Sırada ne var?", systemImage: "sparkles") {
                VStack(alignment: .leading, spacing: 8) {
                    step(true, "Sunucu eklendi, ona özel anahtar kuruldu", nil)
                    step(connected, "Bağlan ve terminalde ⌘P ile komut paletini dene", ("Bağlan", { router.connect(server) }))
                    step(server.health != nil, "Sağlığını ölç: disk, bellek, güncellemeler, çöken servisler",
                         ("Ölç", { Task { try? await model.collectHealth(server.id) } }))
                    step(hardened, "Sertleştir: şifreli girişi kapat, güvenlik duvarı ve fail2ban kur", ("Sertleştir…", harden))
                    step(!(server.grants ?? []).isEmpty, "İstersen bir arkadaşına kendi anahtarıyla erişim ver (isteğe bağlı)", ("Erişim ver…", grant))
                }
                HStack {
                    Button("Sigil’i tanı") { router.tourPage = 0 }.buttonStyle(.borderless).font(.caption)
                    Spacer()
                    Button("Bu kartı gizle") { hiddenIDs += server.id.uuidString + "," }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }

    private func step(_ done: Bool, _ text: String, _ action: (String, () -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.verdigris : .secondary)
                .contentTransition(.symbolEffect(.replace))
            Text(text).foregroundStyle(done ? .secondary : .primary).strikethrough(done, color: .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !done, let action { Button(action.0, action: action.1).controlSize(.small) }
        }
        .animation(Motion.quick, value: done)
    }
}
