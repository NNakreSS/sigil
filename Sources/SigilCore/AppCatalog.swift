import Foundation

/// The recipes that ship with Sigil. Every app joins the shared `sigil` Docker network, so they reach each other
/// by container name (Adminer → sigil-postgres). Ports bind to 127.0.0.1 unless published on purpose.
public enum AppCatalog {
    static let dockerID = "docker"

    private static let network = """
    networks:
      default:
        name: sigil
        external: true
    """

    public static let docker = AppRecipe(
        id: dockerID, name: "Docker", category: .essentials,
        summary: "Docker Engine ve docker compose. Diğer uygulamaların hepsi bunun üzerinde çalışır.",
        symbol: "shippingbox.fill", website: "https://docs.docker.com/engine/install/",
        compose: "", port: nil, ownLogin: true,
        notes: "Resmî get.docker.com betiğiyle kurulur (Alpine’de apk). Root değilsen kullanıcın docker grubuna eklenir.")

    public static let builtIn: [AppRecipe] = [
        docker,

        // MARK: Monitoring
        AppRecipe(
            id: "grafana", name: "Grafana + Prometheus", category: .monitoring,
            summary: "Sunucunun CPU, bellek, disk ve ağ grafikleri. Prometheus ve node_exporter ile hazır panoyla gelir.",
            symbol: "chart.xyaxis.line", website: "https://grafana.com/docs/grafana/latest/",
            compose: """
            services:
              grafana:
                image: grafana/grafana:latest
                container_name: sigil-grafana
                restart: unless-stopped
                ports:
                  - "{{BIND}}{{PORT}}:3000"
                environment:
                  GF_SECURITY_ADMIN_USER: admin
                  GF_SECURITY_ADMIN_PASSWORD: ${ADMIN_PASSWORD}
                  GF_SERVER_ROOT_URL: "{{URL}}"
                  GF_USERS_ALLOW_SIGN_UP: "false"
                  GF_ANALYTICS_REPORTING_ENABLED: "false"
                volumes:
                  - grafana:/var/lib/grafana
                  - ./provisioning:/etc/grafana/provisioning:ro
                depends_on:
                  - prometheus
              prometheus:
                image: prom/prometheus:latest
                container_name: sigil-prometheus
                restart: unless-stopped
                command:
                  - --config.file=/etc/prometheus/prometheus.yml
                  - --storage.tsdb.retention.time=15d
                volumes:
                  - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
                  - prometheus:/prometheus
              node-exporter:
                image: prom/node-exporter:latest
                container_name: sigil-node-exporter
                restart: unless-stopped
                pid: host
                command:
                  - --path.rootfs=/host
                volumes:
                  - /:/host:ro
            volumes:
              grafana:
              prometheus:
            \(network)
            """,
            files: [
                "prometheus.yml": """
                global:
                  scrape_interval: 15s
                scrape_configs:
                  - job_name: node
                    static_configs:
                      - targets: ["sigil-node-exporter:9100"]
                        labels:
                          instance: "{{SERVER}}"
                  - job_name: prometheus
                    static_configs:
                      - targets: ["localhost:9090"]
                """,
                "provisioning/datasources/prometheus.yml": """
                apiVersion: 1
                datasources:
                  - name: Prometheus
                    uid: sigil-prometheus
                    type: prometheus
                    access: proxy
                    url: http://sigil-prometheus:9090
                    isDefault: true
                """,
                "provisioning/dashboards/sigil.yml": """
                apiVersion: 1
                providers:
                  - name: sigil
                    folder: Sigil
                    type: file
                    options:
                      path: /etc/grafana/provisioning/dashboards
                """,
                "provisioning/dashboards/server.json": serverDashboard,
            ],
            port: 3000, ownLogin: true, secrets: ["ADMIN_PASSWORD"],
            info: ["Kullanıcı: admin", "Şifre: {{ADMIN_PASSWORD}}"],
            notes: "Hazır pano: Dashboards → Sigil → Sunucu. Daha ayrıntılısı için Dashboards → New → Import → 1860 (Node Exporter Full).",
            minMemoryMB: 512),

        AppRecipe(
            id: "uptime-kuma", name: "Uptime Kuma", category: .monitoring,
            summary: "Siteleri, API’leri ve portları izler; düşünce Telegram, Slack, e-posta… ile haber verir.",
            symbol: "heart.text.square", website: "https://github.com/louislam/uptime-kuma",
            compose: """
            services:
              uptime-kuma:
                image: louislam/uptime-kuma:1
                container_name: sigil-uptime-kuma
                restart: unless-stopped
                ports:
                  - "{{BIND}}{{PORT}}:3001"
                volumes:
                  - uptime-kuma:/app/data
            volumes:
              uptime-kuma:
            \(network)
            """,
            port: 3001, ownLogin: true, firstVisitSetup: true,
            notes: "İlk açılışta yönetici hesabını sen oluşturursun."),

        AppRecipe(
            id: "dozzle", name: "Dozzle", category: .monitoring,
            summary: "Sunucudaki tüm container’ların loglarını tarayıcıda canlı izle, ara, filtrele.",
            symbol: "text.line.first.and.arrowtriangle.forward", website: "https://dozzle.dev",
            compose: """
            services:
              dozzle:
                image: amir20/dozzle:latest
                container_name: sigil-dozzle
                restart: unless-stopped
                ports:
                  - "{{BIND}}{{PORT}}:8080"
                volumes:
                  - /var/run/docker.sock:/var/run/docker.sock:ro
            \(network)
            """,
            port: 8090, ownLogin: false, minMemoryMB: 64),

        AppRecipe(
            id: "glances", name: "Glances", category: .monitoring,
            summary: "Tarayıcıda canlı htop: işlemciler, bellek, disk, ağ, işlemler ve container’lar tek ekranda.",
            symbol: "gauge.with.dots.needle.67percent", website: "https://nicolargo.github.io/glances/",
            compose: """
            services:
              glances:
                image: nicolargo/glances:latest-full
                container_name: sigil-glances
                restart: unless-stopped
                pid: host
                environment:
                  GLANCES_OPT: "-w"
                ports:
                  - "{{BIND}}{{PORT}}:61208"
                volumes:
                  - /var/run/docker.sock:/var/run/docker.sock:ro
            \(network)
            """,
            port: 61208, ownLogin: false, minMemoryMB: 128),

        // MARK: Containers
        AppRecipe(
            id: "portainer", name: "Portainer", category: .containers,
            summary: "Container, imaj, volume ve compose yığınlarını web arayüzünden yönet.",
            symbol: "square.stack.3d.up", website: "https://docs.portainer.io",
            compose: """
            services:
              portainer:
                image: portainer/portainer-ce:lts
                container_name: sigil-portainer
                restart: unless-stopped
                command: --admin-password-file /run/sigil/admin_password
                ports:
                  - "{{BIND}}{{PORT}}:9000"
                volumes:
                  - /var/run/docker.sock:/var/run/docker.sock
                  - portainer:/data
                  - ./admin_password:/run/sigil/admin_password:ro
            volumes:
              portainer:
            \(network)
            """,
            files: ["admin_password": "{{ADMIN_PASSWORD}}"],
            port: 9000, ownLogin: true, secrets: ["ADMIN_PASSWORD"],
            info: ["Kullanıcı: admin", "Şifre: {{ADMIN_PASSWORD}}"]),

        AppRecipe(
            id: "dockge", name: "Dockge", category: .containers,
            summary: "docker compose yığınlarını web’den yaz, başlat, güncelle. Sade ve hızlı.",
            symbol: "square.stack.3d.down.right", website: "https://github.com/louislam/dockge",
            compose: """
            services:
              dockge:
                image: louislam/dockge:1
                container_name: sigil-dockge
                restart: unless-stopped
                ports:
                  - "{{BIND}}{{PORT}}:5001"
                environment:
                  DOCKGE_STACKS_DIR: /opt/stacks
                volumes:
                  - /var/run/docker.sock:/var/run/docker.sock
                  - dockge:/app/data
                  - /opt/stacks:/opt/stacks
            volumes:
              dockge:
            \(network)
            """,
            port: 5001, ownLogin: true, firstVisitSetup: true,
            notes: "Yığınlar sunucuda /opt/stacks içinde durur. İlk açılışta yönetici hesabını sen oluşturursun."),

        // MARK: Databases
        AppRecipe(
            id: "postgres", name: "PostgreSQL", category: .databases,
            summary: "PostgreSQL 17, rastgele şifreyle. Tünelle TablePlus, DBeaver ya da psql’den bağlan.",
            symbol: "cylinder.split.1x2", website: "https://www.postgresql.org/docs/17/",
            compose: """
            services:
              postgres:
                image: postgres:17
                container_name: sigil-postgres
                restart: unless-stopped
                environment:
                  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
                  POSTGRES_DB: app
                ports:
                  - "{{BIND}}{{PORT}}:5432"
                volumes:
                  - postgres:/var/lib/postgresql/data
            volumes:
              postgres:
            \(network)
            """,
            port: 5432, http: false, ownLogin: true, secrets: ["POSTGRES_PASSWORD"],
            info: ["Kullanıcı: postgres", "Şifre: {{POSTGRES_PASSWORD}}", "Veritabanı: app",
                   "Bağlantı: postgresql://postgres:{{POSTGRES_PASSWORD}}@{{ADDRESS}}/app",
                   "Diğer Sigil uygulamalarından: sigil-postgres:5432"]),

        AppRecipe(
            id: "mariadb", name: "MariaDB", category: .databases,
            summary: "MySQL uyumlu MariaDB 11, rastgele root şifresiyle.",
            symbol: "cylinder", website: "https://mariadb.com/kb/en/documentation/",
            compose: """
            services:
              mariadb:
                image: mariadb:11
                container_name: sigil-mariadb
                restart: unless-stopped
                environment:
                  MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
                  MARIADB_DATABASE: app
                ports:
                  - "{{BIND}}{{PORT}}:3306"
                volumes:
                  - mariadb:/var/lib/mysql
            volumes:
              mariadb:
            \(network)
            """,
            port: 3306, http: false, ownLogin: true, secrets: ["MARIADB_ROOT_PASSWORD"],
            info: ["Kullanıcı: root", "Şifre: {{MARIADB_ROOT_PASSWORD}}", "Veritabanı: app",
                   "Bağlantı: mysql://root:{{MARIADB_ROOT_PASSWORD}}@{{ADDRESS}}/app",
                   "Diğer Sigil uygulamalarından: sigil-mariadb:3306"]),

        AppRecipe(
            id: "redis", name: "Redis", category: .databases,
            summary: "Şifreli, diske yazan (AOF) Redis 7.",
            symbol: "bolt.horizontal", website: "https://redis.io/docs/latest/",
            compose: """
            services:
              redis:
                image: redis:7-alpine
                container_name: sigil-redis
                restart: unless-stopped
                command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}", "--appendonly", "yes"]
                ports:
                  - "{{BIND}}{{PORT}}:6379"
                volumes:
                  - redis:/data
            volumes:
              redis:
            \(network)
            """,
            port: 6379, http: false, ownLogin: true, secrets: ["REDIS_PASSWORD"],
            info: ["Şifre: {{REDIS_PASSWORD}}", "Bağlantı: redis://:{{REDIS_PASSWORD}}@{{ADDRESS}}",
                   "Diğer Sigil uygulamalarından: sigil-redis:6379"],
            minMemoryMB: 64),

        AppRecipe(
            id: "adminer", name: "Adminer", category: .databases,
            summary: "Tek sayfalık veritabanı arayüzü: PostgreSQL, MariaDB/MySQL, SQLite.",
            symbol: "tablecells", website: "https://www.adminer.org",
            compose: """
            services:
              adminer:
                image: adminer:latest
                container_name: sigil-adminer
                restart: unless-stopped
                ports:
                  - "{{BIND}}{{PORT}}:8080"
            \(network)
            """,
            port: 8081, ownLogin: true, access: [.tunnel, .domain],
            info: ["Sunucu alanı: sigil-postgres ya da sigil-mariadb"],
            notes: "Sigil ile kurulan veritabanlarına adıyla bağlanır (aynı Docker ağında).", minMemoryMB: 64),

        // MARK: Apps
        AppRecipe(
            id: "n8n", name: "n8n", category: .apps,
            summary: "Sürükle-bırak iş akışı otomasyonu: webhook’lar, API’ler, zamanlanmış işler, yapay zekâ adımları.",
            symbol: "point.3.filled.connected.trianglepath.dotted", website: "https://docs.n8n.io",
            compose: """
            services:
              n8n:
                image: docker.n8n.io/n8nio/n8n:latest
                container_name: sigil-n8n
                restart: unless-stopped
                ports:
                  - "{{BIND}}{{PORT}}:5678"
                environment:
                  N8N_SECURE_COOKIE: "{{HTTPS}}"
                  N8N_EDITOR_BASE_URL: "{{URL}}"
                  WEBHOOK_URL: "{{URL}}/"
                  N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
                  N8N_DIAGNOSTICS_ENABLED: "false"
                  GENERIC_TIMEZONE: "{{TZ}}"
                  TZ: "{{TZ}}"
                volumes:
                  - n8n:/home/node/.n8n
            volumes:
              n8n:
            \(network)
            """,
            port: 5678, ownLogin: true, firstVisitSetup: true, secrets: ["N8N_ENCRYPTION_KEY"],
            notes: "İlk açılışta sahip hesabını sen oluşturursun. Dışarıdan webhook alacaksan alan adıyla yayınla.",
            minMemoryMB: 512),

        AppRecipe(
            id: "gitea", name: "Gitea", category: .apps,
            summary: "Kendi Git sunucun: depolar, pull request’ler, issue’lar, paketler ve Actions.",
            symbol: "arrow.triangle.branch", website: "https://docs.gitea.com",
            compose: """
            services:
              gitea:
                image: gitea/gitea:latest
                container_name: sigil-gitea
                restart: unless-stopped
                environment:
                  USER_UID: "1000"
                  USER_GID: "1000"
                  GITEA__database__DB_TYPE: sqlite3
                  GITEA__server__ROOT_URL: "{{URL}}/"
                  GITEA__server__HTTP_PORT: "3000"
                  GITEA__server__DISABLE_SSH: "true"
                  GITEA__security__INSTALL_LOCK: "true"
                  GITEA__security__SECRET_KEY: ${GITEA_SECRET_KEY}
                  GITEA__service__DISABLE_REGISTRATION: "true"
                ports:
                  - "{{BIND}}{{PORT}}:3000"
                volumes:
                  - gitea:/data
            volumes:
              gitea:
            \(network)
            """,
            port: 3300, ownLogin: true, secrets: ["ADMIN_PASSWORD", "GITEA_SECRET_KEY"],
            info: ["Kullanıcı: sigil", "Şifre: {{ADMIN_PASSWORD}}"],
            notes: "Git, HTTP(S) üzerinden kullanılır; Gitea’nın kendi SSH portu açılmaz. Yeni kayıtlar kapalıdır, kullanıcıları yönetici ekler.",
            postInstall: """
            i=0
            until $D exec -u git sigil-gitea gitea admin user list >/dev/null 2>&1 || [ $i -ge 40 ]; do i=$((i+1)); sleep 2; done
            $D exec -u git sigil-gitea gitea admin user create --admin --username sigil --password "$ADMIN_PASSWORD" --email admin@example.com --must-change-password=false
            """),

        AppRecipe(
            id: "vaultwarden", name: "Vaultwarden", category: .apps,
            summary: "Bitwarden uyumlu şifre kasası; Bitwarden uygulamaları ve tarayıcı eklentileriyle çalışır.",
            symbol: "lock.rectangle.on.rectangle", website: "https://github.com/dani-garcia/vaultwarden/wiki",
            compose: """
            services:
              vaultwarden:
                image: vaultwarden/server:latest
                container_name: sigil-vaultwarden
                restart: unless-stopped
                environment:
                  DOMAIN: "{{URL}}"
                  SIGNUPS_ALLOWED: "true"
                  ADMIN_TOKEN: ${ADMIN_TOKEN}
                ports:
                  - "{{BIND}}{{PORT}}:80"
                volumes:
                  - vaultwarden:/data
            volumes:
              vaultwarden:
            \(network)
            """,
            port: 8222, ownLogin: true, firstVisitSetup: true, access: [.tunnel, .domain], secrets: ["ADMIN_TOKEN"],
            info: ["Yönetim paneli: {{URL}}/admin", "Yönetim anahtarı: {{ADMIN_TOKEN}}"],
            notes: "Hesabını oluşturduktan sonra /admin → General settings’ten “Allow new signups”ı kapat. Telefondan kullanmak için alan adıyla yayınla.",
            minMemoryMB: 128),
    ]

    /// A small Grafana dashboard over node_exporter, provisioned with the Grafana recipe.
    static let serverDashboard = #"""
    {
      "uid": "sigil-server",
      "title": "Sunucu",
      "tags": ["sigil"],
      "timezone": "browser",
      "schemaVersion": 39,
      "refresh": "30s",
      "time": {"from": "now-6h", "to": "now"},
      "panels": [
        {"id": 1, "type": "stat", "title": "CPU", "gridPos": {"x": 0, "y": 0, "w": 6, "h": 4},
         "datasource": {"type": "prometheus", "uid": "sigil-prometheus"},
         "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100, "decimals": 0,
           "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "orange", "value": 70}, {"color": "red", "value": 90}]}}},
         "options": {"colorMode": "value", "graphMode": "area", "reduceOptions": {"calcs": ["lastNotNull"]}},
         "targets": [{"refId": "A", "expr": "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])))"}]},
        {"id": 2, "type": "stat", "title": "Bellek", "gridPos": {"x": 6, "y": 0, "w": 6, "h": 4},
         "datasource": {"type": "prometheus", "uid": "sigil-prometheus"},
         "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100, "decimals": 0,
           "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "orange", "value": 80}, {"color": "red", "value": 92}]}}},
         "options": {"colorMode": "value", "graphMode": "area", "reduceOptions": {"calcs": ["lastNotNull"]}},
         "targets": [{"refId": "A", "expr": "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)"}]},
        {"id": 3, "type": "stat", "title": "Disk (/)", "gridPos": {"x": 12, "y": 0, "w": 6, "h": 4},
         "datasource": {"type": "prometheus", "uid": "sigil-prometheus"},
         "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100, "decimals": 0,
           "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "orange", "value": 80}, {"color": "red", "value": 90}]}}},
         "options": {"colorMode": "value", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"]}},
         "targets": [{"refId": "A", "expr": "100 * (1 - node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"})"}]},
        {"id": 4, "type": "stat", "title": "Açık kalma süresi", "gridPos": {"x": 18, "y": 0, "w": 6, "h": 4},
         "datasource": {"type": "prometheus", "uid": "sigil-prometheus"},
         "fieldConfig": {"defaults": {"unit": "s", "decimals": 0}},
         "options": {"colorMode": "none", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"]}},
         "targets": [{"refId": "A", "expr": "time() - node_boot_time_seconds"}]},
        {"id": 5, "type": "timeseries", "title": "CPU kullanımı", "gridPos": {"x": 0, "y": 4, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "sigil-prometheus"},
         "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100, "custom": {"fillOpacity": 15}}},
         "targets": [{"refId": "A", "expr": "100 * (1 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])))", "legendFormat": "CPU"}]},
        {"id": 6, "type": "timeseries", "title": "Bellek", "gridPos": {"x": 12, "y": 4, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "sigil-prometheus"},
         "fieldConfig": {"defaults": {"unit": "bytes", "min": 0, "custom": {"fillOpacity": 15}}},
         "targets": [
           {"refId": "A", "expr": "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "legendFormat": "Kullanılan"},
           {"refId": "B", "expr": "node_memory_MemTotal_bytes", "legendFormat": "Toplam"}]},
        {"id": 7, "type": "timeseries", "title": "Ağ", "gridPos": {"x": 0, "y": 12, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "sigil-prometheus"},
         "fieldConfig": {"defaults": {"unit": "Bps", "custom": {"fillOpacity": 10}}},
         "targets": [
           {"refId": "A", "expr": "sum(rate(node_network_receive_bytes_total{device!~\"lo|veth.*|docker.*|br-.*\"}[5m]))", "legendFormat": "Gelen"},
           {"refId": "B", "expr": "sum(rate(node_network_transmit_bytes_total{device!~\"lo|veth.*|docker.*|br-.*\"}[5m]))", "legendFormat": "Giden"}]},
        {"id": 8, "type": "timeseries", "title": "Yük", "gridPos": {"x": 12, "y": 12, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "sigil-prometheus"},
         "fieldConfig": {"defaults": {"unit": "short", "min": 0}},
         "targets": [
           {"refId": "A", "expr": "node_load1", "legendFormat": "1 dk"},
           {"refId": "B", "expr": "node_load5", "legendFormat": "5 dk"},
           {"refId": "C", "expr": "node_load15", "legendFormat": "15 dk"}]},
        {"id": 9, "type": "timeseries", "title": "Disk okuma / yazma", "gridPos": {"x": 0, "y": 20, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "sigil-prometheus"},
         "fieldConfig": {"defaults": {"unit": "Bps", "custom": {"fillOpacity": 10}}},
         "targets": [
           {"refId": "A", "expr": "sum(rate(node_disk_read_bytes_total[5m]))", "legendFormat": "Okuma"},
           {"refId": "B", "expr": "sum(rate(node_disk_written_bytes_total[5m]))", "legendFormat": "Yazma"}]},
        {"id": 10, "type": "timeseries", "title": "Disk doluluğu", "gridPos": {"x": 12, "y": 20, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "sigil-prometheus"},
         "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100}},
         "targets": [{"refId": "A", "legendFormat": "{{mountpoint}}",
           "expr": "100 * (1 - node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay|squashfs|nsfs\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay|squashfs|nsfs\"})"}]}
      ]
    }
    """#
}
