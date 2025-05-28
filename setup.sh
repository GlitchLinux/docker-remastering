#!/bin/bash

# Exit on error and print commands
set -ex

# Update the system and install essential packages
apt-get update
apt-get upgrade -y
apt-get install -y --no-install-recommends \
    sudo \
    curl \
    wget \
    gnupg \
    ca-certificates \
    systemd \
    dbus \
    locales \
    keyboard-configuration \
    console-setup \
    network-manager \
    openssh-server \
    cloud-init \
    ifupdown \
    net-tools \
    iputils-ping \
    dnsutils \
    vim-tiny \
    less \
    git \
    rsync \
    cron \
    logrotate \
    htop \
    iotop \
    iftop \
    ntp \
    ntpdate \
    unattended-upgrades \
    apt-transport-https \
    software-properties-common \
    debconf-utils \
    tasksel \
    debootstrap \
    squashfs-tools \
    xorriso \
    isolinux \
    syslinux-efi \
    grub-pc \
    shim-signed \
    dosfstools \
    mtools \
    memtest86+ \
    ufw \
    fail2ban \
    lm-sensors \
    smartmontools \
    ethtool \
    lshw \
    pciutils \
    usbutils \
    dmidecode \
    hdparm \
    parted \
    gdisk \
    efibootmgr \
    lvm2 \
    mdadm \
    btrfs-progs \
    xfsprogs \

#Kernel modules
sudo apt update
sudo apt install --reinstall linux-image-amd64 linux-headers-amd64

# Configure locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# Configure timezone
ln -fs /usr/share/zoneinfo/UTC /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

# Configure keyboard (US layout)
echo "XKBMODEL=\"pc105\"" > /etc/default/keyboard
echo "XKBLAYOUT=\"us\"" >> /etc/default/keyboard
echo "XKBVARIANT=\"\"" >> /etc/default/keyboard
echo "XKBOPTIONS=\"\"" >> /etc/default/keyboard
dpkg-reconfigure -f noninteractive keyboard-configuration

# Configure network (use NetworkManager)
systemctl enable NetworkManager
systemctl disable networking

# Configure SSH
mkdir -p /etc/ssh/sshd_config.d
echo "PermitRootLogin no" > /etc/ssh/sshd_config.d/disable-root.conf
echo "PasswordAuthentication no" >> /etc/ssh/sshd_config.d/disable-root.conf
systemctl enable ssh

# Configure firewall
ufw allow ssh
ufw enable

# Configure automatic updates
echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades
echo 'Unattended-Upgrade::Automatic-Reboot "true";' >> /etc/apt/apt.conf.d/50unattended-upgrades
echo 'Unattended-Upgrade::Automatic-Reboot-Time "02:00";' >> /etc/apt/apt.conf.d/50unattended-upgrades

# Create a non-root user with sudo privileges
useradd -m -s /bin/bash admin
echo 'admin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/admin
chmod 440 /etc/sudoers.d/admin

# Install cloud-init for cloud compatibility (even if not using cloud)
cat > /etc/cloud/cloud.cfg.d/99_defaults.cfg <<EOF
datasource_list: [ NoCloud, ConfigDrive ]
manage_etc_hosts: true
preserve_hostname: false
ssh_pwauth: false
users:
  - default
  - name: admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINSERTYOURPUBLICKEYHERE admin@debian-iso
EOF

# Install additional useful tools
apt-get install -y \
    jq \
    yq \
    tmux \
    screen \
    ncdu \
    tree \
    zip \
    unzip \
    bzip2 \
    lzop \
    p7zip-full \
   
