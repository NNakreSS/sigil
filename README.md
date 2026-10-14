# Sigil

<img src="Packaging/AppIcon-1024.png" width="96" align="right" alt="">

SSH sunucularını tek yerden yöneten bir macOS uygulaması (SwiftUI, macOS 14+).

Sunucuyu bir kez eklersin: alias, IP, kullanıcı adı ve şifre. Sigil o sunucuya özel bir anahtar üretir, sunucuya kurar, `~/.ssh/config` dosyasına kısayolu yazar ve anahtarı düzenli olarak yeniler. Sonra terminalde yazman gereken tek şey:

```
ssh alias
```

## Kimlik

Her sunucunun bir **mührü** vardır: yedi köşeli bir figür. Köşeleri, dönüşü ve vurgu noktası, sunucunun o anki anahtarının SHA-256 özetinden üretilir (`SigilCore/SigilGeometry.swift`).

- Aynı anahtar her zaman aynı mührü verir. Anahtar yenilenince mühür biçim değiştirir.
- Sunucu eklerken onay ekranında sunucunun kendi host key'inden üretilmiş bir mühür de gösterilir. Bu, parmak izinin görsel halidir.
- Uygulama ikonu, menü çubuğu simgesi ve boş ekranlardaki "nefes alan" mühür aynı sistemden gelir.

**Tasarım dili:**

- **Renkler:** mürekkep (`ink`), parşömen (`parchment`) ve tek bir vurgu rengi (`verdigris`). Alarm için hazır kırmızı yerine `cinnabar` kullanılır.
- **Yazı tipleri:** isim ve başlıklarda serif, terminalde görünen her şeyde monospace.
- **Hareket:**
  - Mühür biçim değiştirirken yaylı geçiş
  - Seçimde damga efekti
  - Sunucu eklerken mühürün adım adım çizilmesi
  - Bağlantı denetiminde nabız
  - Başarı anında dokunsal geri bildirim

  macOS'un "Hareketi azalt" ayarı açıksa hepsi kapanır.
- **Kısayollar:** ⌘K hızlı bağlan, ⌘N sunucu ekle, ⌘T terminalde bağlan, ⌘R bağlantıyı test et.

## Özellikler

- **İki anahtar deposu (sunucu başına seçilir):**
  - **1Password:** Anahtar 1Password'de üretilir ve hiç diske yazılmaz. ssh, 1Password SSH Agent üzerinden bağlanır ve her kullanım Touch ID ile onaylanır.
  - **macOS Keychain:** Anahtar dosyası rastgele bir passphrase ile şifrelenir, passphrase Keychain'de durur. Yenileme tamamen otomatiktir.
- **Güvenli ilk bağlantı:** Sunucunun parmak izi sen onaylamadan şifre gönderilmez. Şifre bir kez kullanılır, kaydedilmez. Bir adım başarısız olursa her şey geri alınır.
- **Kilitlenmeyen anahtar yenileme:** Yeni anahtar kurulur, yeni anahtarla giriş doğrulanır, sonra eskisi sunucudan silinir. Keychain anahtarları sessizce yenilenir. 1Password anahtarları için bildirim gelir ve tek tıkla yenilenir.
- **Menü çubuğu ve arka plan:** Pencere kapalıyken de çalışır. Girişte otomatik başlayabilir. Sunucu düşerse veya yenileme gerekirse bildirim gönderir.
- **Sunucu kayıtları:** Ulaşılabilirlik, anahtar yaşı ve parmak izi, etkinlik günlüğü ve sunucunun kendi `last` kaydı (başka makinelerden yapılan girişler dahil) görünür.
- **Otomatik güncelleme:** Sparkle ile, EdDSA imzalı ve notarize edilmiş sürümler GitHub Releases'ten gelir.
- **Gruplar ve ortamlar:** Sunucular klasörlere ayrılabilir. Production sunucularına bağlanmadan önce onay istenir ve sekmeleri kırmızıyla işaretlenir.
- **Terminal:**
  - Uygulama içinde sekmeli terminal açılır. Sunucular arasında tek tıkla ya da ⌘1…9 ile geçilir.
  - İstersen Terminal, iTerm2, Ghostty veya Warp kullanılabilir.
  - Hızlı bağlanmak için ⌘K.
- **İçe aktarma:** `~/.ssh/config` dosyasındaki sunucular aynı kısayolla Sigil'e taşınır. Mevcut erişiminle bağlanıldığı için şifre gerekmez. Eski blok silinmez, yedeklenip yorum satırına alınır.
- **Yabancı mühür denetimi:** Sunucunun `authorized_keys` dosyasındaki, Sigil dışından eklenmiş anahtarlar listelenir. Bu Mac'teki anahtarlarla eşleşenler etiketlenir. Her biri "tanıdık" olarak işaretlenebilir ya da tek tıkla kaldırılabilir.
- **Host key izleme:** Sunucunun mührü değişirse alarm verilir ve bağlantı durdurulur. Yeni mühür ancak bilinçli bir onayla kabul edilir.
- **Acil durum:** Tek tıkla tüm sunucularda anahtar yenilenir.
- **Sağlık:** Disk, bellek, yük, güncellemeler, yeniden başlatma gereği, çöken servisler ve SSL sertifikalarının bitiş tarihleri izlenir. Sorun çıkınca bildirim gelir.
- **Sertleştirme sihirbazı:** Şifreli girişi ve root girişini kısıtlar, ufw ve fail2ban kurar, otomatik güvenlik güncellemelerini açar. Erişimi etkileyen her değişiklik sunucudaki bir bekçi süreçle uygulanır. Sigil yeni bir bağlantıyla 45 saniye içinde doğrulamazsa sunucu değişikliği kendisi geri alır.
- **Tüneller:** Kayıtlı port yönlendirmeleri (ör. `localhost:15432 → db:5432`) tek tıkla açılır ve menü çubuğundan yönetilir.
- **Hızlı eylemler:** Kayıtlı komutlar birden çok sunucuda paralel çalıştırılır, her sunucunun çıktısı ayrı gösterilir.
- **ProxyJump:** Bir bastion sunucusu üzerinden bağlanılabilir. Host key taraması da bastion üzerinden yapılır.
- **Bağlantılar:** `sigil://connect/<alias>`, `sigil://open/<alias>` ve `sigil://quick` adresleri Shortcuts, Raycast ve Alfred ile kullanılabilir.

## Geliştirme

```bash
swift test                    # birim + 127.0.0.1'de geçici sshd'ye karşı uçtan uca testler
./scripts/make-app.sh         # build/Sigil.app (ad-hoc imzalı)
open build/Sigil.app
```

Gerçek `~/.ssh` klasörüne dokunmadan denemek için:

```bash
SIGIL_SANDBOX=/tmp/sd-try build/Sigil.app/Contents/MacOS/Sigil
```

Yayınlama adımları için [RELEASING.md](RELEASING.md) dosyasına bak.

## Güvenlik modeli

- Şifre ve passphrase'ler `SSH_ASKPASS` ile verilir. Komut satırında görünmezler, diske yazılmazlar.
- 1Password: `op item create` çıktısı private key içerdiği için hiç okunmaz. Kayıt bir etiketle bulunur ve yalnızca `public_key` ile `fingerprint` alanları istenir.
- `~/.ssh/config` dosyasına yalnızca bir `Include` satırı eklenir (öncesinde zaman damgalı yedek alınır). Senin kendi girdilerine dokunulmaz.
- Tüm girdiler katı doğrulanır: `-` ile başlayan değerler ve satır sonları reddedilir.
- Host key'ler OpenSSH kadar sıkı denetlenir: bilinen bir sunucu, kayıtlı anahtarlarından birini göstermezse bağlantı reddedilir ve yeni türde anahtar hiç eklenmez.
- Uygulama yalnızca kendi eklediği `known_hosts` kayıtlarını siler.
- Sunucudan gelen çıktı 1 MB ile sınırlıdır.
- Yayın derlemeleri hardened runtime ile imzalanır, notarize edilir ve build makinesine ait rpath'ler binary'den temizlenir.

## Sınırlar

- İlk kurulum için sunucuda şifreyle girişin açık olması gerekir.
- 1Password'de SSH Agent'ın kullandığı kasa Private, Personal ya da Employee olmalıdır.
- Aynı macOS kullanıcısıyla çalışan zararlı bir yazılıma karşı Keychain yöntemi sınırlı koruma sağlar. 1Password her kullanımda onay istediği için bu konuda daha güçlüdür.
