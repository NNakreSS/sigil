# Sigil test sunucusu

Sigil'i elle test etmek için Docker içinde çalışan, atılabilir bir Ubuntu 24.04
"VPS". İçinde gerçek systemd (PID 1) var; `systemctl`, `journalctl`, timer'lar
ve `systemctl reboot` çalışır. Kurulu olanlar: openssh-server, sudo, nginx, ufw,
fail2ban, cron, sysstat, Docker (iç içe) ve `apt-check`. İmajda `apt-get upgrade`
bilerek çalıştırılmadı, yani "güncelleme" özelliği için bekleyen paketler var.

Sadece test içindir: root şifreyle girişe izin verir ve `--privileged` çalışır.

## Başlatma / durdurma

```sh
scripts/test-server/start.sh   # imajı derler, konteyneri yeniden oluşturur
scripts/test-server/stop.sh    # konteyneri (ve volume'larını) siler
```

`start.sh` her çalıştığında rastgele yeni bir root şifresi üretir ve
`scripts/test-server/.env` dosyasına (`ROOT_PASSWORD=...`, izin 600) yazar.
Bu dosya git'e girmez.

- SSH: `127.0.0.1:2222`
- nginx: <http://127.0.0.1:8080>

## Sigil'e ekleme

- Host: `127.0.0.1`
- Port: `2222`
- Kullanıcı: `root`
- Kimlik doğrulama: şifre (`scripts/test-server/.env` içindeki `ROOT_PASSWORD`)

Konteyner her yeniden oluşturulduğunda yeni host key üretilir. Sigil veya `ssh`
host key değişti diye uyarırsa eski kaydı silin:

```sh
ssh-keygen -R "[127.0.0.1]:2222"
```

(`systemctl reboot` aynı konteyneri yeniden başlatır; host key ve şifre değişmez.)
