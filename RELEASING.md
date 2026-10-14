# Yayınlama

`v1.2.3` biçiminde bir tag push'landığında GitHub Actions (`.github/workflows/release.yml`) şunları yapar:

1. Testleri çalıştırır.
2. Universal (Apple Silicon + Intel) derler.
3. Developer ID ile hardened runtime açık imzalar.
4. Apple'a notarize ettirip staple eder.
5. DMG üretir, onu da imzalar, notarize eder ve staple eder.
6. Sparkle appcast'ini EdDSA ile imzalar.
7. DMG ve `appcast.xml`'i GitHub Releases'e yükler.

Kurulu uygulamalar güncellemeyi `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml` adresinden bulur. Bu yüzden **depo ve release'ler herkese açık olmalı**.

## Bir kerelik kurulum

Aşağıdaki gizli değerleri **1Password'de** bir kayıtta saklaman önerilir. Örnekler bu kaydın adını "Sigil Release" olarak varsayar. `gh secret set` komutlarını `op read` ile beslersen değerler ne ekranda görünür ne de diske yazılır.

### 1. Developer ID sertifikası

1. Xcode → Settings → Accounts → Apple ID'ni seç → **Manage Certificates** → `+` → **Developer ID Application**.
2. Keychain Access'te sertifikayı ve private key'ini birlikte sağ tıkla → **Export** → `.p12` olarak, güçlü bir parolayla kaydet.
3. `.p12` dosyasını ve parolasını 1Password'e ekle, sonra diskteki dosyayı sil.

İmza kimliğinin tam adını şu komutla görebilirsin. Çıktı `Developer ID Application: Ad Soyad (TEAMID)` biçiminde olur.

```bash
security find-identity -v -p codesigning
```

### 2. Notarization için App Store Connect API anahtarı

App Store Connect → Users and Access → Integrations → **Team Keys** → `+` → rol: **Developer**.

`.p8` dosyası yalnızca bir kez indirilebilir. **Key ID** ve **Issuer ID** değerlerini not al. Üçünü de 1Password'e koy.

### 3. Sparkle güncelleme anahtarı (EdDSA)

```bash
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

Komut public key'i yazdırır, private key'i de login Keychain'e kaydeder. CI için private key'i dışa aktar, 1Password'e koy ve dosyayı sil:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private.key
```

> ⚠️ Bu private key'i kaybedersen mevcut kullanıcılar bir daha güncelleme alamaz. Sızarsa da başkası sahte güncelleme yayınlayabilir. Yedeği 1Password'de olmalı.

### 4. GitHub secret'ları ve değişkenleri

```bash
op read "op://Private/Sigil Release/DeveloperID.p12" | base64 | gh secret set DEVELOPER_ID_P12_BASE64
op read "op://Private/Sigil Release/p12 password"   | gh secret set DEVELOPER_ID_P12_PASSWORD
op read "op://Private/Sigil Release/AuthKey.p8"     | gh secret set NOTARY_KEY_P8
op read "op://Private/Sigil Release/key id"         | gh secret set NOTARY_KEY_ID
op read "op://Private/Sigil Release/issuer id"      | gh secret set NOTARY_ISSUER_ID
op read "op://Private/Sigil Release/sparkle private"| gh secret set SPARKLE_PRIVATE_KEY

gh variable set SIGN_IDENTITY      --body "Developer ID Application: Ad Soyad (TEAMID)"
gh variable set SPARKLE_PUBLIC_KEY --body "<generate_keys çıktısındaki public key>"
```

## Sürüm çıkarmak

```bash
git tag v1.0.0
git push origin v1.0.0
```

İş akışını Actions sekmesinden izle. Notarization genellikle birkaç dakika sürer.

## Yerelde

Yerel denemeler için:

- `./scripts/make-app.sh`: ad-hoc imzalı geliştirme derlemesi.
- `./scripts/release.sh`: tam yayın akışı. Yukarıdaki değerleri ortam değişkeni olarak ister. Notarization için `NOTARY_PROFILE` ile bir `notarytool store-credentials` profili de kullanılabilir.
