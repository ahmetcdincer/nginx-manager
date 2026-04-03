# nginx-manager

Tek dosyalık, interaktif Nginx yonetim araci. TUI (Terminal User Interface) tabanli calisir, tum islemleri menuler uzerinden yapar.

Turkce ve Ingilizce dil destegi vardir.

## Desteklenen Sistemler

- Ubuntu / Debian / Linux Mint / Pop!_OS
- RHEL / CentOS / AlmaLinux / Rocky / Fedora
- Arch Linux / Manjaro / EndeavourOS
- Alpine Linux
- macOS (Homebrew)

Isletim sistemi otomatik algilanir. Algilanamadigi durumda manuel secim menusune duser.

## Moduller

### 1. Config Yonetimi

Site listeleme, etkinlestirme, devre disi birakma, yeni sanal sunucu olusturma. Framework bazli profil/sablon sistemi icerur:

- **Statik SPA:** React, Angular, Vue.js, Svelte, klasik HTML
- **PHP:** WordPress, Laravel, Symfony, Drupal, genel PHP-FPM
- **Node.js:** Next.js, Nuxt, Remix, Express/Fastify, SvelteKit, Astro
- **Python:** Django, Flask, FastAPI, genel WSGI
- **Diger:** Go, Rust, Ruby on Rails, Java/Spring Boot, .NET/ASP.NET Core

Ayrica config duzenleme (EDITOR ile) ve iki config arasinda diff karsilastirmasi yapilabilir.

### 2. SSL Sertifika

Let's Encrypt (Certbot) ile sertifika alma, yenileme, son tarih kontrolu ve otomatik yenileme cron kurulumu. Ek olarak:

- Self-signed sertifika olusturma (gelistirme ortamlari icin)
- Cloudflare Origin CA sertifikasi kurulumu

### 3. Log Analizi

- Anlik log izleme (tail -f)
- Hata listeleme (4xx/5xx)
- En cok istek yapan IP'ler (bar chart ile)
- HTTP durum kodu dagilimi (renkli bar chart)
- En cok istenen URL'ler
- Bant genisligi raporu
- Tarih araligina gore filtreleme
- CSV ve JSON formatinda disa aktarma

### 4. Health Check ve Servis

Nginx durum kontrolu, servis baslatma/durdurma/restart/reload, port dinleme kontrolu, surec bilgisi. Tek veya toplu URL erisilebilirlik testi yapilabilir. Otomatik health check cron kurulumu desteklenir.

### 5. Backup / Restore

Config dosyalarinin tarih damgali arsivlenmesi, yedekten geri yukleme (geri yukleme oncesi otomatik yedek alinir), yedek listesi ve eski yedeklerin temizlenmesi.

### 6. Guvenlik Taramasi

10 maddelik tam guvenlik taramasi yapar ve skor verir:

- server_tokens, security header'lari (X-Frame-Options, X-Content-Type-Options, CSP, vb.)
- SSL/TLS protokol kontrolu
- Dizin listeleme (autoindex) kontrolu
- Hassas dosya erisim kontrolu (.git, .env, wp-config.php, vb.)

Canli URL uzerinden header kontrolu ve SSL/TLS yapilandirma analizi de yapilabilir.

### 7. Reverse Proxy

- Standart reverse proxy olusturma
- WebSocket proxy (upgrade header destegi)
- Load balancer (round-robin, least_conn, ip_hash)
- Mevcut proxy config'lerini listeleme

### 8. Rate Limit / IP Engelleme

- Rate limit kurali olusturma (zone, rate, burst)
- IP engelleme ve engel kaldirma
- Engelli IP listesi
- GeoIP ulke engelleme sablonu

### 9. Nginx Kurulum / Kaldirma

Nginx kurulu degilse dogrudan kurar. Kuruluysa yeniden kurma veya kaldirma secenegi sunar. Otomatik baslama (systemctl enable) yapilandirilir.

## Kurulum

```bash
git clone <repo-url>
cd nginx-manager
chmod +x manager.sh
```

## Kullanim

### Interaktif Mod

```bash
sudo ./manager.sh
```

Turkce arayuz ile baslar. Ingilizce icin:

```bash
sudo ./manager.sh --lang en
```

Veya ortam degiskeni ile:

```bash
export NGINX_MGR_LANG=en
sudo ./manager.sh
```

### Komut Satiri Modu

Interaktif menuye girmeden tek islem yapmak icin:

```
./manager.sh --health            Nginx durum kontrolu
./manager.sh --test              Config testi (nginx -t)
./manager.sh --reload            Config yeniden yukle
./manager.sh --restart           Nginx yeniden baslat
./manager.sh --status            Servis durumu
./manager.sh --backup            Config yedegi al
./manager.sh --ssl-check         SSL son tarih kontrolu
./manager.sh --security-scan     Guvenlik taramasi
./manager.sh --list-sites        Site listesi
./manager.sh --block-ip IP       IP engelle
./manager.sh --unblock-ip IP     IP engelini kaldir
./manager.sh --export csv|json   Log disa aktar
./manager.sh --install           Nginx kur
./manager.sh --lang CODE         Dil secimi (en/tr)
./manager.sh --help              Yardim
```

CLI komutlari da `--lang` ile birlestirilebilir:

```bash
./manager.sh --lang en --ssl-check
```

## Gereksinimler

- Bash 4.0+ (associative array destegi icin)
- Root/sudo yetkisi (cogu islem icin)
- Standart Unix araclari: awk, sed, grep, curl, openssl, tar

Certbot ve nginx kurulu degilse, script icerisinden kurulabilir.

## Dil Destegi

Script Turkce (varsayilan) ve Ingilizce olmak uzere iki dili destekler. Tum kullaniciya gorunen metinler dahili ceviri sistemi uzerinden yonetilir. Dil secimi uc yolla yapilabilir:

1. CLI argumani: `--lang en`
2. Ortam degiskeni: `NGINX_MGR_LANG=en`
3. Varsayilan: Turkce

## Lisans

MIT
