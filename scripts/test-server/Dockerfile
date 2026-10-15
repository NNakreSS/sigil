# Throw-away Ubuntu 24.04 "VPS" for manually testing Sigil.
# Runs systemd as PID 1. Started by start.sh; never use this anywhere real.
FROM ubuntu:24.04

ENV container=docker \
    DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# No `apt-get upgrade` on purpose: pending updates are wanted for testing.
# The apt lists are kept so `apt list --upgradable` works right away.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus dbus-user-session \
      openssh-server sudo nginx git curl ca-certificates \
      ufw iptables fail2ban python3-systemd \
      iproute2 iputils-ping dnsutils netcat-openbsd \
      htop sysstat less vim-tiny cron \
      docker.io containerd \
      update-notifier-common \
      tzdata locales bash-completion

# Remove units that only make sense on real hardware / a real console.
RUN systemctl mask \
      getty@.service serial-getty@.service console-getty.service \
      systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket \
      systemd-udev-trigger.service systemd-udev-settle.service \
      systemd-modules-load.service sys-kernel-debug.mount sys-kernel-tracing.mount \
      sys-kernel-config.mount systemd-remount-fs.service systemd-firstboot.service \
      systemd-hwdb-update.service ldconfig.service \
 && systemctl set-default multi-user.target \
 && systemctl enable ssh.service nginx.service cron.service docker.service \
      containerd.service fail2ban.service sysstat.service \
 && systemctl disable ssh.socket 2>/dev/null || true

# sshd: allow root password login for the first connection. Ubuntu's
# sshd_config already has `Include /etc/ssh/sshd_config.d/*.conf`, so Sigil's
# 00-sigil-hardening.conf drop-in will be picked up (and win, since sshd uses
# the first value it sees and 00- sorts before 50-).
RUN grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config \
 && printf '%s\n' \
      '# Test-server only: allow the first login with the root password.' \
      'PermitRootLogin yes' \
      'PasswordAuthentication yes' \
      'KbdInteractiveAuthentication no' \
      > /etc/ssh/sshd_config.d/50-test-server.conf \
 && mkdir -p /run/sshd \
 && rm -f /etc/ssh/ssh_host_*

# Fresh host keys on first boot of each container (not baked into the image).
RUN printf '%s\n' \
      '[Unit]' \
      'Description=Generate SSH host keys (test server)' \
      'Before=ssh.service' \
      'ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key' \
      '[Service]' \
      'Type=oneshot' \
      'ExecStart=/usr/bin/ssh-keygen -A' \
      '[Install]' \
      'WantedBy=multi-user.target' \
      > /etc/systemd/system/ssh-hostkeys.service \
 && systemctl enable ssh-hostkeys.service

# fail2ban: there is no rsyslog, so read sshd failures from the journal.
RUN printf '%s\n' '[DEFAULT]' 'backend = systemd' \
      > /etc/fail2ban/jail.d/00-container-backend.conf

# Root has no password until start.sh sets one with chpasswd.
RUN passwd -l root \
 && echo 'sigil-test' > /etc/hostname

# Nested Docker cannot put overlayfs on top of the container's own overlayfs,
# so its storage lives on (anonymous) volumes; stop.sh removes them.
VOLUME ["/var/lib/docker", "/var/lib/containerd"]
EXPOSE 22 80
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
