<p align="center">
  <img src="Assets/kadmos-dock-1024.png" width="140" alt="Kadmos Logo" />
</p>

<h1 align="center">Kadmos</h1>

<p align="center">
  <strong>macOS 27 ("Golden Gate" / Liquid Glass) için yerel, güvenli ve sade düz metin editörü.</strong><br/>
  Windows 11 Notepad işlevselliğini Apple arayüz diline yedirilmiş biçimde sunar.
</p>

---

## Öne Çıkan Özellikler

- **Apple macOS 27 Liquid Glass Arayüzü:**
  - Safari tarzı birleşik başlık çubuğunda Liquid Glass sekmeler (`GlassEffectContainer` + `.glassEffect`), tam ekran uyumlu trafik ışığı hizalaması ve cam çubuğun altından akan belge görünümü.
  - Sekme başlığına tek tıklayarak dosya adı ve uzantısını (`adsız1.txt` → `deneme.yml`) doğrudan sekme içinden **Onayla** butonuyla değiştirme.
  - Apple **Writing Tools**, VoiceOver ve yerel yazdırma (`⌘P`, `⌘⇧P`) destekli saf AppKit `NSTextView` (TextKit 1) motoru.
- **Windows 11 Notepad ile Birebir Düz Metin İşlevleri:**
  - Çoklu sekme (`⌘N`), yeni pencere (`⌘⇧N`), kapatılan sekmeyi geri açma (`⌘⇧T`), sekme çoğaltma, yeni pencereye taşıma ve oturum kurtarma.
  - Yüzen Liquid Glass **Bul ve Değiştir** çubuğu (`⌘F`, `⌥⌘F`, `⌘G`/`F3`): Büyük/küçük harf, tam sözcük, başa sarma ve zaman aşımı korumalı Düzenli İfade (Regex).
  - **Satıra Git** (`⌘L`), **Saat/Tarih Ekle** (`F5`), **Sözcük Kaydırma** (`⌥Z`), **Yakınlaştırma** (`%10`–`%500`, parmak kıstırma ve `⌘ + kaydırma`).
  - **Durum Çubuğu:** Satır/sütun konumu, karakter/seçim/kelime sayacı, satır sonu (`LF` / `CRLF` / `CR`) ve kodlama (`UTF-8`, `UTF-8 BOM`, `UTF-16 LE/BE`, `Windows-1254`, `Windows-1252`, `ISO Latin 1`, `Mac OS Roman`) dönüştürme / yeniden açma.
  - Uzantı bazlı hariç tutmalı yazım denetimi, yazı tipi seçici (canlı önizlemeli) ve Sistem / Açık / Koyu tema.
- **Masaüstünde Sağ Tık → Yeni Kadmos Belgesi:**
  - Gömülü App Sandbox'lı `KadmosFinderSync` uzantısı sayesinde Masaüstü veya Finder klasörlerinde sağ tıklayarak **"Yeni Kadmos Belgesi"** (veya seçili dosyalar için **"Kadmos ile Aç"**) başlatılabilir.

---

## Güvenlik Mimarisi (`SECURITY.md`)

Kadmos, [SECURITY.md](SECURITY.md) gereksinimlerine uygun olarak **Profil A** (en kısıtlayıcı) güvenlik duruşuyla tasarlanmıştır:

- **App Sandbox + Hardened Runtime** açık; ağ erişimi (`network.client` / `network.server`), JIT, `disable-library-validation` ve `temporary-exception` izinleri **yoktur**.
- **0 harici paket bağımlılığı:** Yalnızca Apple sistem framework'leri (`AppKit`, `SwiftUI`, `FinderSync`, `UniformTypeIdentifiers`, `OSLog`).
- **Dosya açma anında sıfır kod çalıştırma:** `WebKit`/`WKWebView`, `eval`, `NSExpression`, `NSAppleScript`, `Process` ve modeline desteği yoktur.
- **Dosya sistemi sertleştirmesi:** TOCTOU-güvenli doğrudan `open()` + `fstat()`, symlink / `..` kapsam doğrulaması, `+x` biti olmadan atomik kayıt ve kapsayıcı içi `0700`/`0600` izinli oturum kasası (`SessionVault`).
- **Büyük dosya ve ReDoS koruması:** `50 MB` üstü sınırlı mod, `1 GB` üstü salt-okunur 256 KB akış modu, `.reportProgress` ile zaman aşımı kesmeli regex arama.
- **Trojan Source görünürlüğü:** Çift yönlü (Bidi) kontrol karakterleri, sıfır genişlikli karakterler ve gizli `U+FEFF` işaretleri varsayılan olarak vurgulanır.

---

## Kurulum & Kaynak Koddan Derleme

### Gereksinimler
- **macOS 26.0+** (Apple Silicon / Universal, macOS 27.2 üzerinde test edildi)
- **Xcode 27.2+** (`Swift 6.0` / `6.4.2`)

### 1. Testleri Çalıştırma (`KadmosCore`)
```bash
swift test
```

### 2. Uygulamayı Derleme, İmzalama ve Paketleme
```bash
./scripts/build_app.sh
```
Betik sırasıyla testleri çalıştırır, `Kadmos.xcodeproj` dosyasını üretir, Release derlemesini alır, içten dışa (`KadmosFinderSync.appex` önce, `Kadmos.app` sonra) Hardened Runtime (`--options runtime`) ile imzalar ve `dist/Kadmos.app` ile `dist/Kadmos.dmg` çıktılarını oluşturur.

### 3. Kurulum ve Finder Sağ Tık Eklentisi
1. `dist/Kadmos.app` paketini `/Applications/` klasörüne kopyalayın.
2. Masaüstü sağ tık menüsü için **Sistem Ayarları → Genel → Giriş Öğeleri ve Genişletmeler → Finder Genişletmeleri** altından **Kadmos Finder** anahtarını etkinleştirin.

---

## Proje Yapısı

```text
Kadmos/
├── Assets/                  # Uygulama ikonları (.icns, PNG)
├── Config/                  # Entitlements ve Info.plist dosyaları (Profil A)
├── Sources/
│   ├── KadmosCore/          # Kodlama, satır sonu, güvenlik, ReDoS-güvenli arama, Trojan tarayıcı, oturum kasası
│   ├── KadmosApp/           # SwiftUI + AppKit editör arayüzü, Safari tarzı sekmeler, ayarlar
│   └── KadmosFinderSync/    # Finder sağ tık uzantısı (.appex)
├── Tests/KadmosCoreTests/   # Birim ve güvenlik testleri (33 test)
├── scripts/                 # Xcode proje üretici ve derleme/imzalama betikleri
├── Package.swift
└── SECURITY.md
```

---

## Sorun Bildirme (Issues) & Katkı

Bir hata ile karşılaşırsanız, Finder eklentisinde sorun yaşarsanız veya yeni bir özellik önermek isterseniz lütfen **[GitHub Issues](../../issues)** sayfasından yeni bir kayıt açın.

> Güvenlik açıklarını herkese açık Issue olarak **açmayın**; lütfen [SECURITY.md](SECURITY.md) Bölüm 12'deki güvenlik bildirim sürecini kullanın.

## Lisans

Bu proje [MIT Lisansı](LICENSE) ile lisanslanmıştır.
