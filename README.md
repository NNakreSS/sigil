<div align="center">

<img src="Packaging/AppIcon-1024.png" width="128" alt="Sigil uygulama ikonu">

# Sigil

**Her sunucuya kendi mührü.**

SSH sunucularını tek yerden yöneten, anahtarları senin yerine üreten, kuran ve yenileyen bir macOS uygulaması.

[![CI](https://github.com/NNakreSS/sigil/actions/workflows/ci.yml/badge.svg)](https://github.com/NNakreSS/sigil/actions/workflows/ci.yml)
[![Son sürüm](https://img.shields.io/github/v/release/NNakreSS/sigil?label=s%C3%BCr%C3%BCm&color=534AB7)](https://github.com/NNakreSS/sigil/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-26215C)
[![Lisans: MIT](https://img.shields.io/badge/lisans-MIT-0F6E56)](LICENSE)

[**İndir**](https://github.com/NNakreSS/sigil/releases/latest) · [Güvenlik](#güvenlik-sade-bir-dille) · [Özellikler](#özellikler) · [Geliştirme](#geliştirme)

</div>

---

Sunucuyu bir kez eklersin: alias, IP, kullanıcı adı ve şifre. Sigil gerisini halleder:

1. Sunucunun parmak izini gösterir, sen onaylarsın.
2. O sunucuya **özel** bir anahtar üretir: Mac'in güvenlik çipinde (Secure Enclave), 1Password'de ya da macOS Keychain'de.
3. Açık anahtarı sunucuya kurar ve yeni anahtarla girişi doğrular. Şifre bu adımdan sonra bir daha kullanılmaz ve hiçbir yere kaydedilmez.
4. `~/.ssh/config` dosyasına kısayolu yazar ve anahtarı düzenli olarak yeniler.

Sonra terminalde yazman gereken tek şey:

```
ssh webserver
```

## Güvenlik, sade bir dille

<p align="center">
  <img src="docs/how-it-works.svg" width="100%" alt="Sunucuna kilit gider, anahtar sende kalır: gizli anahtar Mac'teki kasada (Secure Enclave, 1Password ya da Keychain) doğar ve hiç dışarı çıkmaz; sunucuya yalnızca açık anahtar takılır, girişte yalnızca Touch ID ile atılan imza gider.">
</p>

Bir SSH aracına sunucu şifreni ve 1Password'ünü emanet etmeden önce aklına gelen soruların cevapları aşağıda. Her cevap kodda doğrulanabilir.

<details>
<summary><b>1Password'ü bağlarsam diğer şifrelerim, kartlarım, notlarım okunur mu?</b></summary>
<br>

Hayır. Sigil 1Password'le yalnızca resmi `op` komut satırı aracıyla konuşur ve yalnızca aşağıdaki komutları çalıştırır. Bunların dışında bir komut yok ([`OnePasswordService.swift`](Sources/SigilCore/OnePasswordService.swift)):

| Komut | Neden | Sigil'in gördüğü |
|---|---|---|
| `op account list` | 1Password bağlı mı? | Yalnızca "bağlı / değil" bilgisini kullanır |
| `op vault list` | SSH Agent'ın kasasını (Private / Personal / Employee) bulmak | Kasa adları |
| `op item create --category ssh` | Yeni anahtar üretmek | **Hiçbir şey.** Çıktı private key içerdiği için okunmadan atılır |
| `op item list --tags sigil-…` | Az önce üretilen kaydı bulmak | Yalnızca o etiketi taşıyan kaydın kimliği |
| `op item get --fields public_key,fingerprint` | Açık anahtarı sunucuya kurmak | Açık anahtar ve parmak izi |
| `op item delete --archive` | Yenilenen eski anahtarı kaldırmak | Hiçbir şey. Kayıt silinmez, Arşiv'e taşınır |

- Başka bir kaydın içeriğini isteyen tek bir satır bile yok. Diğer kayıtların adları bile listelenmez.
- `op` her yeni oturum için 1Password'ün kendi penceresinde onay ister. Onay vermezsen hiçbir şey çalışmaz.
- O pencere **hesabın tamamına erişim** ister. Bu 1Password'ün kuralıdır: `op` aracına kayıt ya da kasa bazında sınırlı izin verilemiyor. Sigil'in bu erişimle ne yaptığı yukarıdaki tabloyla sınırlı, kod açık. Onay bir süre kullanılmayınca kendiliğinden düşer.
- Sigil `op`'u yalnızca senin başlattığın bir 1Password işleminde çağırır: sunucu ekleme, anahtar yenileme ya da kurulum ekranındaki **Kontrol Et**. Uygulama açılırken ya da arka planda 1Password penceresi çıkmaz.
- Daha fazla ayrım istersen 1Password'ü hiç bağlamadan macOS Keychain seçeneğini kullanabilirsin.
</details>

<details>
<summary><b>Private key'im bir yere gider mi?</b></summary>
<br>

- **Secure Enclave seçeneğinde (varsayılan):** Anahtar Mac'in güvenlik çipinde üretilir ve **hiçbir şekilde** dışarı çıkarılamaz: ne Sigil, ne macOS, ne de Mac'e erişen biri onu kopyalayabilir. Diskte yalnızca ssh'a hangi anahtarı kullanacağını söyleyen, gizli bilgi içermeyen bir dosya durur.
- **1Password seçeneğinde:** Anahtar 1Password'ün içinde üretilir ve hiç diske yazılmaz. `ssh` bağlanırken sunucu bir soru gönderir. 1Password SSH Agent, sen Touch ID ile onaylayınca bu soruyu imzalar. Dışarı çıkan şey anahtar değil, yalnızca o tek girişe ait imzadır.
- **Keychain seçeneğinde:** Anahtar `~/.ssh/sigil/keys` altında, 192 bit rastgele bir parolayla şifrelenmiş olarak durur. Parola macOS Keychain'de saklanır.

Her durumda sunucuya yalnızca **açık** anahtar gider. Açık anahtar, adı üstünde, gizli değildir: onunla giriş yapılamaz.
</details>

<details>
<summary><b>Mac'im açıkken başında oturan biri sunucularıma girebilir mi?</b></summary>
<br>

Bu, anahtarın nerede durduğuna bağlı:

| Anahtar deposu | Terminal'den `ssh sunucum` yazan biri |
|---|---|
| **Secure Enclave** | Touch ID istenir; parmak izin olmadan giremez, Sigil'i hiç açmasa da. Onay verdikten sonra, seçtiğin süre boyunca (varsayılan 15 dakika) aynı sunucuya açılan bağlantılar tekrar sormaz; ekran kilitlenince, Mac uyuyunca ya da Sigil kapanınca bu süre hemen biter. Her bağlantıda sormasını istersen Ayarlar → Anahtarlar. Pencerede istekte bulunan olarak **“ctkcard”** yazar: bu, anahtarı Secure Enclave'de tutan macOS servisidir. |
| **1Password** | 1Password onay ister. 1Password açıksa ve o uygulamaya daha önce izin verdiysen sormadan geçebilir; 1Password'ün otomatik kilit süresini kısa tut. |
| **Keychain** | Mac'in kilidi açıkken **sormadan girer.** Bu korumayı istiyorsan Secure Enclave'i seç. |

Secure Enclave sunucularına Sigil arka planda hiç bağlanmaz: durum, sağlık ve anahtar denetimi yalnızca sen istediğinde, Touch ID ile yapılır.
</details>

<details>
<summary><b>Sunucu şifrem saklanıyor mu?</b></summary>
<br>

Hayır. Şifre yalnızca ilk kurulumda, bellekte tutulur ve bir kez kullanılır:

- `ssh`'a komut satırıyla değil `SSH_ASKPASS` mekanizmasıyla verilir. `ps` gibi araçlarda görünmez, diske yazılmaz.
- Sunucunun parmak izini onaylamadan **gönderilmez**. Böylece araya giren sahte bir sunucu şifreni alamaz.
- Kurulum bitince unutulur. Bir adım başarısız olursa yarım kalan her şey geri alınır.
</details>

<details>
<summary><b>SSH bağlantım dinlenebilir ya da ele geçirilebilir mi?</b></summary>
<br>

- SSH trafiği uçtan uca şifrelidir. Sigil bunu değiştirmez, OpenSSH'ın kendisini kullanır.
- Her bağlantıda `StrictHostKeyChecking=yes` kullanılır. Sunucunun kimliği (host key) ilk gün sen onaylayınca kaydedilir. Sonradan değişirse, örneğin biri araya girmeye çalışırsa, bağlantı durdurulur ve bir uyarı çıkar. Yeni kimlik ancak bilerek onaylarsan kabul edilir.
- Sigil sunucudaki `authorized_keys` dosyasını da denetler. Sigil dışından eklenmiş anahtarları gösterir, bunları tanıdık olarak işaretleyebilir ya da kaldırabilirsin.
</details>

<details>
<summary><b>Sigil benim hakkımda bir yere veri gönderiyor mu?</b></summary>
<br>

Hayır. Sigil'in hesap sistemi, sunucusu ya da analitiği yok. Kendiliğinden internete yalnızca iki yerden çıkar:

1. **SSH ile kendi sunucularına.**
2. **GitHub'a, güncelleme kontrolü için.** Sparkle `appcast.xml` dosyasını indirir. Güncellemeler EdDSA ile imzalıdır, imzası tutmayan bir dosya kurulmaz.

Kodda bunların dışında yalnızca **sen açarsan** çalışan ağ istekleri var: Ayarlar → Terminal → Kod yardımında "Claude" ya da "Gemini" (kendi API anahtarınla) seçilirse, öneri istediğin anda isteğin (ya da seçtiğin terminal metni) ve sunucunun işletim sistemi ile kurulu araçların listesi Anthropic'e ya da Google'a gönderilir. Sunucu adresi, kullanıcı adı ve anahtarlar gönderilmez. Ücretsiz Gemini API katmanında Google gönderilenleri ürünlerini geliştirmek için kullanabilir. Varsayılan kod yardımı Apple'ın cihaz içi modelidir ve Mac'ten hiçbir şey çıkmaz. 1Password seçeneğinde, ürettiğin anahtar 1Password'ün kendi şifreli senkronizasyonuyla kasana kaydedilir. Bu, 1Password'ün normal işleyişidir.
</details>

<details>
<summary><b>İndirdiğim uygulamanın bu koddan derlendiğini nasıl bilebilirim?</b></summary>
<br>

- Sürümler, bu depodaki [Release iş akışıyla](.github/workflows/release.yml) GitHub Actions üzerinde derlenir. Derleme kayıtları herkese açıktır.
- Uygulama Apple Developer ID ile imzalanır ve Apple tarafından notarize edilir. İmzayı kendin kontrol edebilirsin:

  ```bash
  codesign -dv --verbose=2 /Applications/Sigil.app
  ```
  ```bash
  spctl --assess --verbose /Applications/Sigil.app
  ```
- İmzalama anahtarları yalnızca GitHub'ın şifreli secret deposunda tutulur. Depoda ya da derleme kayıtlarında bulunmazlar.
</details>

<details>
<summary><b>Mac'im çalınırsa ya da bir anahtarın sızdığından şüphelenirsem?</b></summary>
<br>

- Secure Enclave ve 1Password anahtarları Touch ID olmadan kullanılamaz. Keychain anahtarları Mac'in kilidiyle korunur.
- Secure Enclave anahtarı Mac'e bağlıdır, yedeklenemez. Mac kaybolursa sunucuya şifrenle girip yeni bir anahtar eklersin. Bu yüzden **Güvenliği güçlendir** sihirbazı bu sunucularda şifreli girişi varsayılan olarak açık bırakır.
- **Acil durum** (⌥⇧⌘R) tek tıkla bütün sunucularda anahtarı yeniler. Eski anahtarlar sunuculardan silinir.
- Yenileme hiçbir zaman seni dışarıda bırakmaz. Önce yeni anahtar kurulur, yeni anahtarla giriş doğrulanır, ancak ondan sonra eskisi kaldırılır.
</details>

**Dürüst sınırlar**

- Aynı macOS kullanıcısıyla çalışan zararlı bir yazılım, Keychain seçeneğinde anahtarlara ulaşabilir. Secure Enclave ve 1Password her kullanımda onay istediği için bu konuda daha güçlüdür.
- Secure Enclave seçeneği macOS 26 ve Touch ID'li bir Mac gerektirir. Diğer Mac'lerde 1Password ya da Keychain kullanılır.
- Secure Enclave anahtarını silmek Touch ID istemez. Mac'ine erişen biri anahtarı kullanamaz ama silebilir; bu durumda sunucuya şifrenle girersin.
- İlk kurulum için sunucuda şifreyle girişin açık olması gerekir. Kurulumdan sonra **Güvenliği güçlendir** sihirbazıyla kapatabilirsin.

## Özellikler

| | |
|---|---|
| **Üç anahtar deposu** | Sunucu başına Secure Enclave (Mac'in güvenlik çipi, girişte Touch ID), 1Password (onayla) ya da macOS Keychain (tam otomatik yenileme). |
| **Onay penceresi** | Bir Touch ID onayı seçtiğin süre (varsayılan 15 dakika) aynı sunucuya açılan bağlantıları kapsar: Sigil, terminal sekmeleri ve Terminal'den `ssh`. Ekran kilitlenince, Mac uyuyunca ya da menü çubuğundaki kilitle hemen biter. Anahtar yenileme ve güvenlik güçlendirme doğrulaması her zaman yeni onay ister. |
| **Kilitlenmeyen yenileme** | Yeni anahtarla giriş doğrulanmadan eskisi silinmez. 1Password anahtarları için bildirim ve tek tıkla yenileme. |
| **Gömülü terminal** | Sekmeli terminal, ⌘1…9 ile geçiş, yan yana bölme (⌘D), geçmişte arama (⌘F), yazı boyutu, 8 renk teması, yazı tipi ve imleç ayarları. İstersen Terminal, iTerm2, Ghostty veya Warp. |
| **Komut paleti (⌘P)** | Türkçe açıklamalı 134 hazır komut; sunucuda neler kurulu olduğuna göre süzülür (Docker yoksa Docker komutları çıkmaz). Boşluklu komutlar önce değerleri sorar, sistemi değiştirenler işaretlidir. |
| **Tab ile tamamlama** | Yazarken en uygun komut altta belirir, Tab tamamlar. Öneri yoksa Tab sunucunun kendi tamamlamasına gider. |
| **Kod yardımı** | “son bir saatteki nginx hatalarını göster” gibi bir isteği komuta çevirir; seçili hata metnini açıklar (⇧⌘E). Varsayılan Apple’ın cihaz içi modeli (Mac’ten bir şey çıkmaz); istersen kendi Claude ya da Gemini API anahtarınla. Öneriler asla kendiliğinden çalışmaz ve Sigil şüpheli komutları işaretler. |
| **Bakım** | Sunucuyu güncelle (önce paket listesi, sonra terminalde canlı `apt upgrade`) ve yeniden başlat (geri gelene kadar bekler, kaç saniye kapalı kaldığını söyler). |
| **SSH izin listesi** | Tek tıkla “yalnızca benim IP’me izin ver”: SSH portu güvenlik duvarında (ufw) yalnızca seçtiğin adreslere açılır, web gibi diğer servisler etkilenmez. Sigil bu Mac’in adresini kendisi bulur, listede olmadan uygulamaz ve 45 saniye içinde yeni bir bağlantıyla doğrulayamazsa sunucu eski kurallara döner. |
| **Tek tıkla uygulama kur** | Docker, Grafana + Prometheus (hazır sunucu panosuyla), Uptime Kuma, Dozzle, Glances, Portainer, Dockge, PostgreSQL, MariaDB, Redis, Adminer, n8n, Gitea, Vaultwarden. Erişimi her kurulumda sen seçersin: yalnızca tünel (internete hiç açılmaz, Sigil Mac’ine getirir), alan adı + otomatik HTTPS (Caddy; girişi olmayan uygulamaların önüne şifre koyar) ya da herkese açık port. Şifreler rastgele üretilir, sunucuda yalnızca root’un okuyabildiği `.env`’de ve bu Mac’in Keychain’inde durur. Güncelle, durdur, günlükler, kaldır (veriler silinmez). Kendi docker compose dosyanı tarif olarak kaydedip her sunucuya tek tıkla kurabilirsin. |
| **Erişim ver** | Bir arkadaşının açık anahtarıyla, şifre paylaşmadan giriş izni: kendi hesabı ya da seninki, süreli (sunucu kendisi uygular), IP sınırlı; tek tıkla geri alınır. |
| **Dosyalar** | Kendi penceresinde: sunucudaki dosyalarda gezin, önizle (taşınabilir, satır kaydırmalı önizleme penceresi), sürükle-bırak yükle, indir, yeniden adlandır, sil, o klasörde terminal aç. Tek bağlantı, tek Touch ID. |
| **Docker** | Kendi penceresinde: container’lar compose projesine göre gruplu, CPU/bellek, son loglar ayrı pencerede, canlı log ve container içinde kabuk terminalde, başlat/durdur/yeniden başlat/sil. |
| **Hızlı bağlan** | ⌘K ile ara ve bağlan. Production sunucuları kırmızıyla işaretlenir ve bağlanmadan önce onay ister. |
| **İçe aktarma** | `~/.ssh/config` dosyasındaki sunucular şifre gerekmeden taşınır. Eski blok silinmez, yedeklenip yorum satırına alınır. |
| **Yabancı anahtar denetimi** | `authorized_keys` içindeki tanımadığın anahtarlar listelenir. Tek tıkla kaldırılabilir. |
| **Host key izleme** | Sunucunun kimliği değişirse alarm verilir, bağlantı durur. |
| **Sağlık paneli** | Disk, bellek, yük, bekleyen güncellemeler (hangi paketler), çöken servisler (hangileri), yeniden başlatmayı isteyen paketler, SSL bitiş tarihleri. Sorun çıkınca bildirim gelir. |
| **Güvenliği güçlendir** | Şifreli girişi ve root girişini kısıtlar; ufw, fail2ban ve otomatik güvenlik güncellemelerini kurar. Sunucudaki bir bekçi süreç, Sigil 45 saniye içinde yeni bir bağlantıyla doğrulamazsa her şeyi geri alır. |
| **Tüneller** | Sunucudaki, dışarıya kapalı bir servisi (veritabanı, Redis, yönetim paneli) şifreli SSH üzerinden Mac'ine getirir: `localhost:15432 → sunucuda 5432`. Sunucuda port açılmaz; tek tıkla açılır, Sigil kapanınca kapanır. |
| **Hızlı eylemler** | Kayıtlı komutlar birden çok sunucuda paralel çalışır, çıktılar ayrı gösterilir. |
| **ProxyJump** | Bastion sunucusu üzerinden bağlantı; host key taraması da bastion üzerinden yapılır. |
| **Arka plan** | Menü çubuğunda çalışır, girişte açılabilir, bildirim gönderir. |
| **Bağlantılar** | `sigil://connect/<alias>`, `sigil://open/<alias>`, `sigil://quick`: Shortcuts, Raycast ve Alfred ile kullanılabilir. |
| **Temalar** | Uygulamanın tamamı için Gece (varsayılan), Grafit, Orman gecesi, Mürekkep ve Gün ışığı; ya da macOS'a göre Otomatik. Terminalin kendi 8 renk teması ayrıca seçilir. |
| **Yönlendirme** | İlk açılışta kısa bir tur (Yardım → Sigil'i Tanı), boş ekranda özellik kutuları, yeni sunucuda “Sırada ne var?” kartı ve her kartta ne işe yaradığını anlatan (?) açıklamaları. |
| **Otomatik güncelleme** | İmzalı ve notarize edilmiş sürümler GitHub Releases'ten Sparkle ile gelir. |

## Mühür

Her sunucunun yedi köşeli bir mührü vardır. Köşeleri, dönüşü ve vurgu noktası, sunucunun o anki anahtarının SHA-256 özetinden üretilir ([`SigilGeometry.swift`](Sources/SigilCore/SigilGeometry.swift)).

- Aynı anahtar her zaman aynı mührü verir. Anahtar yenilenince mühür biçim değiştirir.
- Sunucu eklerken sunucunun kendi host key'inden üretilen mühür de gösterilir. Bu, parmak izinin görsel halidir.
- Uygulama ikonu, menü çubuğu simgesi ve boş ekranlardaki "nefes alan" mühür aynı sistemden gelir.

Görünüm temalarla değişir (Ayarlar → Görünüm). Varsayılan **Gece**: derin lacivert zemin, köşelerde hafif ışıltı, cam kartlar ve mühür gibi basılan, tek renk ailesinden gradyanlı ana butonlar. **Mürekkep** teması Sigil'in ilk kimliğini korur: parşömen zemin ve serif başlıklar. Terminalde görünen her şey monospace yazılır. Hareketler macOS'un "Hareketi azalt" ayarına uyar.

## Kurulum

1. [Son sürümün](https://github.com/NNakreSS/sigil/releases/latest) `.dmg` dosyasını indir.
2. Sigil'i **Applications** klasörüne sürükle ve aç. Yanlış yerden açarsan Sigil kendini taşımayı teklif eder.
3. İlk açılışta kısa bir kurulum ekranı anahtar deposunu (Secure Enclave, 1Password ya da Keychain) seçmene yardım eder.

1Password seçeneği için 1Password 8, **Ayarlar → Geliştirici** altında *SSH Agent* ve *1Password CLI ile entegrasyon* seçeneklerinin açık olması ve `op` CLI'ın kurulu olması gerekir.

## Geliştirme

```bash
swift test                    # birim testleri + 127.0.0.1'de geçici sshd'ye karşı uçtan uca testler
./scripts/make-app.sh         # build/Sigil.app (ad-hoc imzalı)
open build/Sigil.app
```

Kurulu Sigil'in yerine o anki kodu (aynı sunucular ve ayarlarla) açmak için:

```bash
./scripts/try-local.sh
```

Gerçek `~/.ssh` klasörüne dokunmadan denemek için:

```bash
SIGIL_SANDBOX=/tmp/sd-try build/Sigil.app/Contents/MacOS/Sigil
```

Her özelliği gerçek bir sunucuya benzeyen bir şeye karşı denemek için Docker'da atılabilir bir Ubuntu 24.04 sunucusu (systemd, nginx, ufw, fail2ban, Docker) hazır: `scripts/test-server/start.sh` (ayrıntılar [scripts/test-server/README.md](scripts/test-server/README.md)).

<details>
<summary>Teknik güvenlik notları</summary>
<br>

- Şifre ve passphrase'ler `SSH_ASKPASS` ile, 0700 izinli geçici bir yardımcı üzerinden verilir. Değer yalnızca alt sürecin ortam değişkenindedir.
- Her `ssh` çağrısı `-F /dev/null`, `StrictHostKeyChecking=yes` ve Sigil'in kendi `known_hosts` dosyasıyla yapılır.
- `~/.ssh/config` dosyasına yalnızca bir `Include` satırı eklenir; öncesinde zaman damgalı yedek alınır.
- Tüm girdiler katı doğrulanır: `-` ile başlayan değerler ve satır sonları reddedilir.
- Bilinen bir sunucu kayıtlı anahtarlarından birini göstermezse bağlantı reddedilir ve yeni türde anahtar sessizce eklenmez.
- Uygulama yalnızca kendi eklediği `known_hosts` kayıtlarını siler.
- Sunucudan gelen çıktı akış başına 1 MB ile sınırlıdır.
- Yayın derlemeleri hardened runtime ile imzalanır, notarize edilir ve build makinesine ait rpath'ler binary'den temizlenir.
</details>

Yayınlama adımları için [RELEASING.md](RELEASING.md) dosyasına bak.

## Lisans

[MIT](LICENSE). Kullanılan kütüphaneler: [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT) ve [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT).
