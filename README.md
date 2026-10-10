# iCam — iPhone'u Mac'te web kamerası olarak kullanın

iCam, Apple'ın **Süreklilik Kamerası** (Continuity Camera) özelliğinin açık kaynaklı bir benzeridir.
iPhone'un kamerası Mac'te **gerçek bir web kamerası** olarak görünür: FaceTime, Zoom, Teams,
Google Meet (Chrome/Safari), Photo Booth, OBS, QuickTime ve kamera kullanan diğer tüm uygulamalarda
**“iCam iPhone Camera”** olarak seçilebilir.

| | |
|---|---|
| Görüntü | 1920×1080, 30 fps (uygulamalar 1280×720 de seçebilir) |
| Bağlantı | **USB kablo** (usbmuxd tüneli, en düşük gecikme) veya **Wi-Fi** (Bonjour + eşler arası Wi-Fi) |
| Kodek | Donanım H.264 (düşük gecikmeli hız kontrolü) veya HEVC |
| Gecikme | USB'de tipik olarak ~1–2 kare; Wi-Fi'da ağa bağlı |
| Gereksinimler | macOS 14+, iOS 17+, Xcode 16+, ücretli Apple Developer hesabı |

## Nasıl çalışır?

```
 iPhone (iCam uygulaması)                        Mac
┌──────────────────────────────┐      ┌──────────────────────────────────────────────┐
│ AVCaptureSession 1080p30     │      │ iCam menü çubuğu uygulaması                  │
│   ↓ 420v, dik tutulmuş kare   │ USB  │   usbmuxd / Bonjour ile keşif, oto-bağlanma │
│ VideoToolbox H.264/HEVC      │─────▶│   ↓                                          │
│   (B-frame yok, düşük gecikme)│ veya │ VideoToolbox donanım çözücü (IOSurface)      │
│   ↓                           │ Wi-Fi│   ↓                                          │
│ TCP + çerçeveli protokol     │◀─────│ CoreMediaIO “sink” akışı                     │
│   (kare onayı = tıkanıklık    │ ack  ├──────────────────────────────────────────────┤
│    kontrolü)                  │      │ iCam Kamera Uzantısı (CMIO Camera Extension) │
└──────────────────────────────┘      │   → tüm uygulamalara web kamerası olarak     │
                                      └──────────────────────────────────────────────┘
```

* **Kendiliğinden açılır/kapanır** – Mac'te bir uygulama kamerayı açtığında iPhone kamerası
  otomatik başlar, kimse kullanmayınca (3 sn sonra) kapanır. Pil ve ısı tasarrufu sağlar.
* **USB öncelikli** – Wi-Fi ile bağlıyken kablo takılırsa yayın kesintisiz biçimde USB'ye geçer.
* **Uçtan uca tıkanıklık kontrolü** – Mac her kareyi çözdükten sonra onaylar. Bağlantı yetişemezse
  iPhone yeni kareleri *kodlamadan önce* atlar (referans zinciri bozulmaz, anahtar kare gerekmez) ve
  bit hızını düşürür; bağlantı rahatlayınca bit hızını kademeli olarak yükseltir.
* **Sıfır kopya** – Çözülen IOSurface kareleri doğrudan kamera uzantısına aktarılır; 1080p yatay
  görüntüde ölçekleme/kopyalama yapılmaz.
* **Asla donmayan kamera** – Canlı görüntü yokken uzantı, durumu anlatan bir bekleme ekranı üretir
  (“iPhone'unuzda iCam'i açın”, “Kamera başlatılıyor…” vb.).
* **Mac'ten kontrol** – Menü çubuğundan lens (0.5×/1×/2×-5×/Ön), yakınlaştırma, ayna, sabitleme;
  canlı önizleme, fps / bit hızı / gecikme istatistikleri, iPhone pil ve ısı durumu.
* **iPhone ekranı kararır** – Yayın başladıktan 12 sn sonra ekran siyaha döner (OLED'de güç tasarrufu);
  dokununca önizleme geri gelir. Ekran kilitlenmez.
* Dikey tutulan iPhone için “kareyi doldur” veya “tümünü göster” seçeneği.
* Türkçe ve İngilizce arayüz.

## Kurulum

### 1. İmzalamayı ayarlayın

`Config/Signing.xcconfig` dosyasını açın ve iki satırı doldurun:

```
DEVELOPMENT_TEAM = ABCDE12345          // Xcode › Settings › Accounts'taki Team ID
BUNDLE_ID_PREFIX = com.adiniz.icam     // size ait bir ters-DNS öneki
```

> Kamera uzantısı bir **sistem uzantısıdır**; `System Extension` yeteneği ücretli Apple Developer
> hesabı gerektirir (ücretsiz kişisel ekip ile yüklenemez).

### 2. iPhone uygulaması

1. `iCam.xcodeproj`'u Xcode ile açın.
2. Şema olarak **iCam (iOS)**'u, hedef olarak iPhone'unuzu seçip çalıştırın (⌘R).
3. İlk açılışta kamera ve (Wi-Fi kullanacaksanız) Yerel Ağ izinlerini verin.

### 3. Mac uygulaması

Sistem uzantıları yalnızca **/Applications** klasöründeki uygulamalardan yüklenebilir. En kolay yol:

```bash
./scripts/install-mac.sh
```

Bu betik Release derlemesi yapar, `iCam.app`'i `/Applications`'a kopyalar ve açar. (Elle yapmak için:
**iCam (macOS)** şemasını derleyin, *Products › iCam.app › Show in Finder* ile bulup
`/Applications`'a kopyalayın ve oradan açın.)

İlk açılışta:

1. macOS kamera uzantısı için onay ister: **Sistem Ayarları › Genel › Giriş Öğeleri ve Uzantılar ›
   Kamera Uzantıları** (macOS 14'te *Gizlilik ve Güvenlik*) bölümünden **iCam**'i açın.
2. Mac uygulaması kamera iznini sorar — izin verin (sanal kameraya görüntü göndermek için gerekir).
3. iCam menü çubuğuna yerleşir ve oturum açılışında otomatik başlar.

### 4. Kullanım

1. iPhone'da iCam'i açın.
2. Kabloyla bağlayın (ilk seferde iPhone'da **Güven**'e dokunun) veya aynı Wi-Fi ağında olun.
3. Herhangi bir uygulamada kamera olarak **iCam iPhone Camera**'yı seçin. Bu kadar.

En iyi sonuç için iPhone'u **yatay** ve **arka kamera** Mac'e (size) bakacak şekilde konumlandırın.

## Sorun giderme

| Belirti | Çözüm |
|---|---|
| Menüde “Move iCam to the Applications folder” | Uygulamayı `/Applications`'a kopyalayıp oradan açın. |
| Kamera uygulamalarda görünmüyor | Uzantının onaylandığını kontrol edin; kamera uygulamasını yeniden başlatın. `systemextensionsctl list` ile durumu görebilirsiniz. |
| “iPhone bulunamadı” (USB) | iPhone'da iCam açık mı? Kabloyu takıp “Güven”e dokundunuz mu? Finder'da iPhone görünüyor mu? |
| “iPhone bulunamadı” (Wi-Fi) | iPhone ve Mac'te Yerel Ağ izinlerini kontrol edin (Ayarlar › Gizlilik › Yerel Ağ). |
| Görüntü takılıyor (Wi-Fi) | iCam bit hızını otomatik düşürür; yine de en iyi deneyim için USB kullanın veya 5 GHz ağa geçin. |
| Uzantıyı değiştirdim ama eski sürüm çalışıyor | `Config/Signing.xcconfig` içinde `CURRENT_PROJECT_VERSION`'ı artırın; macOS yalnızca yeni sürüm numarasında uzantıyı değiştirir. |
| Uzantıyı kaldırmak | `/Applications/iCam.app`'i çöpe atın (macOS uzantıyı kaldırır) veya `systemextensionsctl uninstall <TeamID> <bundle id>`. |

Günlükler için Konsol uygulamasında `app.icam` alt sistemini filtreleyin.

## Sınırlamalar

* iOS, arka plandaki uygulamaların kamerayı kullanmasına izin vermez; iCam yayın sırasında
  **önde ve açık** kalmalıdır (ekran kilitlenmez, otomatik kararır). Apple'ın kendi Süreklilik
  Kamerası bu kısıtlamaya tabi değildir.
* Mikrofon aktarımı yoktur (yalnızca görüntü).
* Masa Görünümü / Center Stage gibi Apple'a özel efektler yoktur. Apple silicon Mac'lerde macOS'in
  Denetim Merkezi'ndeki video efektleri desteklendiği ölçüde kullanılabilir.

## Proje yapısı

```
Shared/                   İki uygulamanın ortak kablo protokolü (çerçeveleme, mesajlar)
iOS/Sources/              iPhone uygulaması
  CameraCapture.swift       AVCaptureSession, lens seçimi, döndürme, 1080p30 format seçimi
  VideoEncoder.swift        VideoToolbox H.264/HEVC, düşük gecikme ayarları
  StreamPipeline.swift      kamera → kodlayıcı → ağ, tıkanıklık ve bit hızı kontrolü
  PeerServer.swift          USB (loopback) + Wi-Fi (Bonjour) dinleyicileri
  PhoneModel.swift          durum yönetimi, ContentView.swift arayüz
macOS/Shared/             Uygulama + uzantı ortak sabitleri (cihaz UUID'leri, özel özellikler)
macOS/App/Sources/        Mac menü çubuğu uygulaması
  USBMux.swift              usbmuxd istemcisi (USB üzerinden TCP tüneli)
  PhoneBrowser.swift        Bonjour keşfi
  DeviceManager.swift       bağlantı politikası, USB/Wi-Fi geçişi, talep yönetimi
  PhoneConnection.swift     protokol oturumu, ping/RTT, kare onayları
  VideoDecoder.swift        VideoToolbox donanım çözücü
  VideoPipeline.swift       1080p'ye uydurma, önizleme ve sanal kameraya dağıtım
  VirtualCameraSink.swift   CoreMediaIO sink akışı, talep (demand) takibi
  ExtensionManager.swift    sistem uzantısı kurulumu
macOS/CameraExtension/    CoreMediaIO kamera uzantısı (sanal web kamerası)
Tests/                    Protokol testleri
tools/                    Xcode projesi, ikon ve yerelleştirme üreteçleri
```

`iCam.xcodeproj` depoya dahildir. Kaynak dosya ekleyip çıkarırsanız
`python3 tools/gen_xcodeproj.py` ile yeniden üretin.

### Testler

```bash
# Kablo protokolü (çerçeveleme, parçalı okuma, mesajlar) — her platformda
swiftc -parse-as-library Shared/ICamProtocol.swift Shared/MessageFraming.swift \
  Tests/ProtocolTests.swift -o /tmp/protocol-tests && /tmp/protocol-tests

# Uçtan uca video zinciri (macOS): iPhone kodlayıcısı → kablo → Mac çözücüsü → 1080p uydurma
swiftc -parse-as-library Shared/*.swift macOS/Shared/*.swift iOS/Sources/VideoEncoder.swift \
  macOS/App/Sources/VideoDecoder.swift macOS/App/Sources/VideoPipeline.swift \
  macOS/CameraExtension/Sources/PlaceholderRenderer.swift \
  Tests/PipelineTests.swift -o /tmp/pipeline-tests && /tmp/pipeline-tests
```

Her push'ta GitHub Actions iPhone ve Mac hedeflerini derler ve bu iki test paketini çalıştırır.
