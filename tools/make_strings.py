#!/usr/bin/env python3
"""Writes the Turkish string catalogs (Localizable / InfoPlist .xcstrings).

Run from the repository root:  python3 tools/make_strings.py
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

IOS = {
    "Settings": "Ayarlar",
    "Connected to %@": "Bağlı: %@",
    "The camera turns on automatically when an app on your Mac uses it.":
        "Mac'inizdeki bir uygulama kamerayı kullandığında kamera otomatik olarak açılır.",
    "Waiting for your Mac": "Mac'iniz bekleniyor",
    "Connect this iPhone with a cable or put it on the same Wi-Fi network, then open iCam on your Mac.":
        "Bu iPhone'u kabloyla bağlayın ya da aynı Wi-Fi ağına bağlayın, ardından Mac'inizde iCam'i açın.",
    "Camera access is off": "Kamera erişimi kapalı",
    "Open Settings": "Ayarları Aç",
    "Ready": "Hazır",
    "Starting": "Başlatılıyor",
    "Advertised as “%@”": "Görünen ad: “%@”",
    "LIVE": "CANLI",
    "Turn iPhone sideways for the best picture": "En iyi görüntü için iPhone'u yatay çevirin",
    "Streaming to %@": "Yayın: %@",
    "Tap to show preview": "Önizlemeyi göstermek için dokunun",
    "Name shown on your Mac": "Mac'te görünen ad",
    "Tips": "İpuçları",
    "A USB cable gives the lowest latency and keeps your iPhone charged.":
        "USB kablo en düşük gecikmeyi sağlar ve iPhone'unuzu şarjda tutar.",
    "Use the rear camera in landscape for the best picture.":
        "En iyi görüntü için arka kamerayı yatay konumda kullanın.",
    "Keep iCam open. The screen dims automatically while streaming.":
        "iCam'i açık tutun. Yayın sırasında ekran otomatik olarak kararır.",
    "Over Wi-Fi, allow Local Network access when asked.":
        "Wi-Fi ile kullanmak için sorulduğunda Yerel Ağ erişimine izin verin.",
    "Done": "Bitti",
    "Ultra Wide": "Ultra Geniş",
    "Wide": "Geniş",
    "Telephoto": "Telefoto",
    "Front": "Ön",
    "No camera available": "Kullanılabilir kamera yok",
    "iCam is in the background": "iCam arka planda",
    "Camera is in use by another app": "Kamera başka bir uygulama tarafından kullanılıyor",
    "Camera unavailable in Split View": "Bölünmüş Görünüm'de kamera kullanılamıyor",
    "iPhone is too hot": "iPhone çok ısındı",
    "Camera interrupted": "Kamera kesintiye uğradı",
    "Incompatible iCam version. Please update both apps.":
        "Uyumsuz iCam sürümü. Lütfen her iki uygulamayı da güncelleyin.",
    "another Mac": "başka bir Mac",
    "iPhone is in use by %@.": "iPhone şu anda %@ tarafından kullanılıyor.",
    "Camera access is off. Allow it in iPhone Settings › iCam.":
        "Kamera erişimi kapalı. iPhone Ayarlar › iCam bölümünden izin verin.",
}

IOS_INFO = {
    "NSCameraUsageDescription":
        "iCam, iPhone kameranızı web kamerası olarak kullanabilmeniz için Mac'inize gönderir.",
    "NSLocalNetworkUsageDescription":
        "iCam, Mac'inizi bulmak ve Wi-Fi üzerinden görüntü aktarmak için yerel ağı kullanır.",
}

MAC = {
    "Starting camera…": "Kamera başlatılıyor…",
    "Connecting to %@…": "%@ cihazına bağlanılıyor…",
    "Open iCam on your iPhone. Connect it with a cable or join the same Wi-Fi.":
        "iPhone'unuzda iCam'i açın. Kabloyla bağlayın ya da aynı Wi-Fi ağına katılın.",
    "Advanced": "Gelişmiş",
    "Diagnostics": "Tanılama",
    "Copy Diagnostics": "Tanılamayı Kopyala",
    "Video codec": "Video kodeki",
    "Portrait iPhone": "Dikey iPhone",
    "Fill frame": "Kareyi doldur",
    "Show all": "Tümünü göster",
    "Setup Guide…": "Kurulum Rehberi…",
    "Launch at login": "Girişte başlat",
    "Quit iCam": "iCam'den Çık",
    "Live": "Canlı",
    "Starting": "Başlıyor",
    "Ready": "Hazır",
    "Connecting": "Bağlanıyor",
    "Searching": "Aranıyor",
    "Retry": "Yeniden Dene",
    "Reopen iCam": "iCam'i Yeniden Aç",
    "An older copy of the iCam camera is still in use. Quit apps that use the camera (OBS, Zoom, FaceTime…), then reopen iCam. If that doesn't help, restart your Mac.":
        "iCam kamerasının eski bir kopyası hâlâ kullanımda. Kamerayı kullanan uygulamaları (OBS, Zoom, FaceTime…) kapatın, ardından iCam'i yeniden açın. Sorun sürerse Mac'inizi yeniden başlatın.",
    "macOS didn't start the updated iCam camera. Quit apps that use the camera (OBS, Zoom, FaceTime…), then turn iCam off and on under Camera Extensions in System Settings, or log out and back in.":
        "macOS güncellenen iCam kamerasını başlatmadı. Kamerayı kullanan uygulamaları (OBS, Zoom, FaceTime…) kapatın, ardından Sistem Ayarları'ndaki Kamera Uzantıları bölümünde iCam'i kapatıp yeniden açın ya da oturumu kapatıp yeniden açın.",
    "macOS hasn't made the iCam camera available to this app yet. Quit apps that use the camera (OBS, Zoom, FaceTime…), then reopen iCam. If that doesn't help, restart your Mac.":
        "macOS, iCam kamerasını bu uygulamaya henüz açmadı. Kamerayı kullanan uygulamaları (OBS, Zoom, FaceTime…) kapatın, ardından iCam'i yeniden açın. Sorun sürerse Mac'inizi yeniden başlatın.",
    "Allow camera access for iCam so it can feed the virtual camera.":
        "Sanal kameraya görüntü aktarabilmesi için iCam'e kamera erişimi verin.",
    "Installing camera extension…": "Kamera uzantısı yükleniyor…",
    "Allow the iCam camera extension in System Settings.":
        "Sistem Ayarları'nda iCam kamera uzantısına izin verin.",
    "Open Settings": "Ayarları Aç",
    "Restart your Mac to finish installing the camera.":
        "Kamera kurulumunu tamamlamak için Mac'inizi yeniden başlatın.",
    "Move iCam to the Applications folder, then open it again.":
        "iCam'i Uygulamalar klasörüne taşıyın ve yeniden açın.",
    "Help": "Yardım",
    "No iPhone found. Open iCam on your iPhone.": "iPhone bulunamadı. iPhone'unuzda iCam'i açın.",
    "Wi-Fi discovery unavailable: %@. Check Local Network access in System Settings › Privacy & Security.":
        "Wi-Fi ile arama kullanılamıyor: %@. Sistem Ayarları › Gizlilik ve Güvenlik › Yerel Ağ iznini kontrol edin.",
    "Disconnect": "Bağlantıyı Kes",
    "Reconnect": "Yeniden Bağlan",
    "Connected via USB": "USB ile bağlı",
    "Connected via Wi-Fi": "Wi-Fi ile bağlı",
    "Warm": "Isındı",
    "Camera": "Kamera",
    "Front": "Ön",
    "Mirror": "Ayna",
    "Stabilization": "Sabitleme",
    "Turn your iPhone sideways for the best picture.": "En iyi görüntü için iPhone'unuzu yatay çevirin.",
    "Starting %@ camera…": "%@ kamerası başlatılıyor…",
    "Connected to %@": "Bağlı: %@",
    "Select your iPhone in the iCam menu": "iCam menüsünden iPhone'unuzu seçin",
    "Open iCam on your iPhone and connect it with a cable or Wi-Fi":
        "iPhone'unuzda iCam'i açın ve kabloyla ya da Wi-Fi ile bağlayın",
    "Open iCam on your iPhone": "iPhone'unuzda iCam'i açın",
    "Welcome to iCam": "iCam'e Hoş Geldiniz",
    "Use your iPhone as a webcam": "iPhone'unuzu web kamerası olarak kullanın",
    "iCam works with FaceTime, Zoom, Teams, Meet, Photo Booth, OBS and every other camera app.":
        "iCam; FaceTime, Zoom, Teams, Meet, Photo Booth, OBS ve diğer tüm kamera uygulamalarıyla çalışır.",
    "Allow the camera extension": "Kamera uzantısına izin verin",
    "Install the iCam app on your iPhone and keep it open. Allow camera access when asked.":
        "iCam uygulamasını iPhone'unuza yükleyin ve açık tutun. Sorulduğunda kamera erişimine izin verin.",
    "Connect": "Bağlayın",
    "Plug in a USB cable for the lowest latency (tap “Trust” on the iPhone the first time), or use the same Wi-Fi network. iCam connects automatically.":
        "En düşük gecikme için USB kablo takın (ilk seferde iPhone'da “Güven”e dokunun) ya da aynı Wi-Fi ağını kullanın. iCam otomatik olarak bağlanır.",
    "Pick “%@”": "“%@” kamerasını seçin",
    "Choose it as the camera in any app. The iPhone camera turns on automatically while it's in use and off when you're done.":
        "Herhangi bir uygulamada kamera olarak bunu seçin. iPhone kamerası kullanıldığı sürece otomatik açılır, işiniz bitince kapanır.",
    "iCam lives in the menu bar.": "iCam menü çubuğunda çalışır.",
    "Done": "Bitti",
    "The iCam camera is installed.": "iCam kamerası yüklendi.",
    "Installing…": "Yükleniyor…",
    "macOS needs your permission to add the iCam camera. Open System Settings › General › Login Items & Extensions › Camera Extensions (or Privacy & Security on older macOS) and turn on iCam.":
        "macOS'in iCam kamerasını eklemesi için izninize ihtiyacı var. Sistem Ayarları › Genel › Giriş Öğeleri ve Uzantılar › Kamera Uzantıları bölümünü (eski macOS sürümlerinde Gizlilik ve Güvenlik) açın ve iCam'i etkinleştirin.",
    "Open System Settings": "Sistem Ayarlarını Aç",
    "Restart your Mac to finish the installation.": "Kurulumu tamamlamak için Mac'inizi yeniden başlatın.",
    "Move iCam to the Applications folder and open it from there. macOS only installs camera extensions from apps in Applications.":
        "iCam'i Uygulamalar klasörüne taşıyın ve oradan açın. macOS, kamera uzantılarını yalnızca Uygulamalar klasöründeki uygulamalardan yükler.",
    "Try Again": "Tekrar Dene",
}

MAC_INFO = {
    "NSCameraUsageDescription":
        "iCam, iPhone'unuzun görüntüsünü iCam sanal kamerasına aktarmak için kamera erişimine ihtiyaç duyar.",
    "NSLocalNetworkUsageDescription":
        "iCam, iPhone'unuzu bulmak ve Wi-Fi üzerinden görüntü almak için yerel ağı kullanır.",
    "NSSystemExtensionUsageDescription":
        "iCam, iPhone'unuzu her uygulamada web kamerası olarak kullanabilmeniz için Mac'inize bir kamera ekler.",
}


def catalog(strings):
    return {
        "sourceLanguage": "en",
        "strings": {
            key: {"localizations": {"tr": {"stringUnit": {"state": "translated", "value": value}}}}
            for key, value in sorted(strings.items())
        },
        "version": "1.0",
    }


def write(path, strings):
    with open(os.path.join(ROOT, path), "w", encoding="utf-8") as f:
        json.dump(catalog(strings), f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write("\n")


if __name__ == "__main__":
    write("iOS/Resources/Localizable.xcstrings", IOS)
    write("iOS/Resources/InfoPlist.xcstrings", IOS_INFO)
    write("macOS/App/Resources/Localizable.xcstrings", MAC)
    write("macOS/App/Resources/InfoPlist.xcstrings", MAC_INFO)
    print("String catalogs written.")
