#!/bin/bash
set -euo pipefail

# ==============================================
# CachyOS Server ISO 构建脚本
# 深度优化：自动使用 linux-cachyos-server 相关仓库元数据，支持 v3/v4/znver4
# ==============================================

CACHYOS_ISO_REPO="https://github.com/CachyOS/CachyOS-Live-ISO.git"
CACHYOS_LINUX_REPO="https://github.com/CachyOS/linux-cachyos.git"
CACHYOS_ISO_COMMIT="${CACHYOS_ISO_COMMIT:-09b04b14c93736571045c09100d6e2bc9757214c}"
MIN_ISO_SIZE=2000000000  # 2GB

ARCH=${1:-v3}
MITIGATIONS=${2:-auto}
OUTPUT_DIR="${GITHUB_WORKSPACE:-$PWD}/output"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }

log "=============================================="
log "CachyOS Server ISO 构建开始"
log "架构: $ARCH"
log "安全缓解: $MITIGATIONS"
log "输出目录: $OUTPUT_DIR"
log "=============================================="

mkdir -p "$OUTPUT_DIR"

if [[ "$ARCH" != "v3" && "$ARCH" != "v4" && "$ARCH" != "znver4" ]]; then
    error "不支持的架构: $ARCH"
fi

log "准备 linux-cachyos server 内核元数据仓库..."
if [ -d "$PWD/linux-cachyos" ]; then
    LINUX_CACHYOS_REPO="$PWD/linux-cachyos"
else
    git clone --depth 1 "$CACHYOS_LINUX_REPO" "$WORK_DIR/linux-cachyos" >/dev/null 2>&1
    LINUX_CACHYOS_REPO="$WORK_DIR/linux-cachyos"
fi

declare -A PACKAGE_DIRS=( [v3]=linux-cachyos-server [v4]=linux-cachyos-server-v4 [znver4]=linux-cachyos-server-znver4 )
KERNEL_PACKAGE_DIR=${PACKAGE_DIRS[$ARCH]}
KERNEL_PACKAGE="linux-cachyos-server"
case "$ARCH" in
    v3) KERNEL_PACKAGE="linux-cachyos-server" ;; 
    v4) KERNEL_PACKAGE="linux-cachyos-server-v4" ;; 
    znver4) KERNEL_PACKAGE="linux-cachyos-server-znver4" ;; 
esac

PKGBUILD_FILE="$LINUX_CACHYOS_REPO/$KERNEL_PACKAGE_DIR/PKGBUILD"
if [ -f "$PKGBUILD_FILE" ]; then
    log "解析 $KERNEL_PACKAGE_DIR/PKGBUILD 以获取精准 pkgname..."
    PKGNAME_LINE=$(grep -E '^pkgname=' "$PKGBUILD_FILE" | head -n 1 || true)
    if [ -n "$PKGNAME_LINE" ]; then
        PKGNAME=${PKGNAME_LINE#pkgname=}
        PKGNAME=${PKGNAME//[\"\'\(\)]/}
        PKGNAME=${PKGNAME%% *}
        if [[ "$PKGNAME" == "\$pkgbase" || "$PKGNAME" == "\$pkgname" ]]; then
            PKGBASE_LINE=$(grep -E '^pkgbase=' "$PKGBUILD_FILE" | head -n 1 || true)
            if [ -n "$PKGBASE_LINE" ]; then
                PKGBASE=${PKGBASE_LINE#pkgbase=}
                PKGBASE=${PKGBASE//[\"\'\(\)]/}
                PKGBASE=${PKGBASE%% *}
                if [[ "$PKGBASE" =~ ^[a-zA-Z0-9._+-]+$ ]]; then
                    KERNEL_PACKAGE="$PKGBASE"
                fi
            fi
        elif [[ "$PKGNAME" =~ ^[a-zA-Z0-9._+-]+$ ]]; then
            KERNEL_PACKAGE="$PKGNAME"
        else
            log "警告：pkgname 解析为非标准值 '$PKGNAME'，继续使用内置包名 $KERNEL_PACKAGE"
        fi
    fi
fi

log "最终内核包名: $KERNEL_PACKAGE"

log "克隆官方 ISO 仓库..."
git init "$WORK_DIR/iso"
cd "$WORK_DIR/iso"
git remote add origin "$CACHYOS_ISO_REPO"
export GIT_TERMINAL_PROMPT=0
if git fetch --depth 1 origin "$CACHYOS_ISO_COMMIT" >/dev/null 2>&1; then
    git checkout --detach FETCH_HEAD
else
    log "警告: 指定提交不可用，改为使用 origin/master 最新 commit"
    git fetch --depth 1 origin master >/dev/null 2>&1 || error "无法获取 upstream master"
    git checkout --detach FETCH_HEAD
fi

log "导入 CachyOS 公钥并初始化 pacman 密钥环..."
pacman-key --init || true
pacman-key --populate archlinux || true
if ! pacman-key --list-keys | grep -q '882DCFE48E2051D48E2562ABF3B607488DB35A47'; then
    curl -fsSL 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF3B607488DB35A47' -o /tmp/cachyos-key.asc
    pacman-key --add /tmp/cachyos-key.asc || true
    pacman-key --lsign-key 882DCFE48E2051D48E2562ABF3B607488DB35A47 || true
fi

log "替换 ISO 包列表中的默认内核，并移除不需要内核..."
PACKAGE_FILES=$(find archiso -type f -print0 | xargs -0 grep -IlE 'linux-cachyos(|-lts)' || true)
if [ -z "$PACKAGE_FILES" ]; then
    error "未找到 archiso 包列表中的 linux-cachyos 相关条目"
fi
for f in $PACKAGE_FILES; do
    sed -i "s/linux-cachyos/$KERNEL_PACKAGE/g" "$f" || true
    sed -i '/linux-cachyos-server-lts/d' "$f" || true
    sed -i '/linux-cachyos-server-lts-.*$/d' "$f" || true
done

log "注入服务器专用 sysctl、GRUB 和系统优化配置..."
mkdir -p archiso/airootfs/etc/sysctl.d
cat > archiso/airootfs/etc/sysctl.d/90-server-scheduler.conf <<'EOF'
# linux-cachyos-server 专用调度器优化
kernel.sched_min_granularity_ns = 4000000
kernel.sched_latency_ns = 40000000
kernel.sched_wakeup_granularity_ns = 8000000
kernel.sched_migration_cost_ns = 6000000
kernel.sched_autogroup_enabled = 0
kernel.sched_cfs_bandwidth_slice_us = 10000
EOF
cat > archiso/airootfs/etc/sysctl.d/99-server-tuning.conf <<'EOF'
# CachyOS Server 内核参数优化 v2026
fs.file-max = 4194304
fs.nr_open = 2097152
kernel.pid_max = 4194304
kernel.shmmax = 137438953472
kernel.shmall = 33554432
vm.swappiness = 1
vm.vfs_cache_pressure = 50
vm.max_map_count = 524288
net.core.somaxconn = 65535
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
EOF

mkdir -p archiso/airootfs/etc/default
cat > archiso/airootfs/etc/default/grub <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="CachyOS Server"
GRUB_CMDLINE_LINUX_DEFAULT="quiet mitigations=$MITIGATIONS transparent_hugepage=never nowatchdog nmi_watchdog=0 debugfs=off intel_idle.max_cstate=1 processor.max_cstate=1 idle=poll rcutree.enable_rcu_lazy=1 rcu_nocbs=all"
GRUB_TERMINAL_INPUT=console
GRUB_TERMINAL_OUTPUT=console
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_OS_PROBER=true
EOF

mkdir -p archiso/airootfs/etc/systemd/system/multi-user.target.wants
for svc in bluetooth cups avahi-daemon ModemManager; do
    if [ -e "archiso/airootfs/etc/systemd/system/${svc}.service" ] || [ -e "/usr/lib/systemd/system/${svc}.service" ]; then
        ln -sf /dev/null "archiso/airootfs/etc/systemd/system/${svc}.service"
    fi
done
for svc in sshd systemd-networkd systemd-resolved; do
    if [ -e "/usr/lib/systemd/system/${svc}.service" ]; then
        ln -sf "/usr/lib/systemd/system/${svc}.service" "archiso/airootfs/etc/systemd/system/multi-user.target.wants/${svc}.service"
    fi
done

mkdir -p archiso/airootfs/etc/security/limits.d
cat > archiso/airootfs/etc/security/limits.d/99-server-limits.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* soft nproc 4194304
* hard nproc 4194304
root soft nproc 4194304
root hard nproc 4194304
EOF

log "开始构建 ISO..."
if [ -z "${USER:-}" ]; then
    export USER=root
fi
if [ ! -x ./buildiso.sh ]; then
    chmod +x ./buildiso.sh || true
fi
if ! ./buildiso.sh -p desktop -v -w; then
    error "ISO 构建失败"
fi

ISO_FILE=$(find out -type f -name '*.iso' | sort | head -n 1)
if [ -z "$ISO_FILE" ]; then
    error "未找到构建输出 ISO 文件"
fi
ISO_FILENAME="cachyos-server-linux-$(date +%Y%m%d)-$ARCH.iso"
log "发现 ISO 文件: $ISO_FILE"
mv "$ISO_FILE" "$OUTPUT_DIR/$ISO_FILENAME"

ISO_SIZE=$(stat -c %s "$OUTPUT_DIR/$ISO_FILENAME")
if [ "$ISO_SIZE" -lt "$MIN_ISO_SIZE" ]; then
    error "ISO 文件过小 ($ISO_SIZE 字节)，可能损坏"
fi

cd "$OUTPUT_DIR"
sha256sum "$ISO_FILENAME" > "$ISO_FILENAME.sha256"

log "=============================================="
log "✅ ISO 构建成功!"
log "文件: $OUTPUT_DIR/$ISO_FILENAME"
log "大小: $(numfmt --to=iec "$ISO_SIZE")"
log "SHA256: $(awk '{print $1}' "$ISO_FILENAME.sha256")"
log "=============================================="
