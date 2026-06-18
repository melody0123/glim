#!/bin/bash
#
# BASH. It's what I know best, sorry.
# Modified for multi-partition GLIM layout:
#   sdb1 - FAT32 (GLIM)  : GRUB bootloader + config
#   sdb2 - ext4  (ISO)   : ISO image storage
#   sdb3 - exFAT (USB)   : General USB data (untouched)
#

# Check that we are *NOT* running as root
if [[ `id -u` -eq 0 ]]; then
  echo "ERROR: Don't run as root, use a user with full sudo access."
  exit 1
fi

# Sanity check : GRUB2
if which grub2-install &>/dev/null; then
  GRUB2_INSTALL="grub2-install"
  GRUB2_DIR="grub2"
elif which grub-install &>/dev/null; then
  GRUB2_INSTALL="grub-install"
  GRUB2_DIR="grub"
fi
if [[ -z "$GRUB2_INSTALL" ]]; then
  echo "ERROR: grub2-install or grub-install commands not found."
  exit 1
fi

# Sanity check : Our GRUB2 configuration
GRUB2_CONF="`dirname $0`/grub2"
if [[ ! -f ${GRUB2_CONF}/grub.cfg ]]; then
  echo "ERROR: grub2/grub.cfg to use not found."
  exit 1
fi

# Sanity check : blkid command
if ! which blkid &>/dev/null; then
  echo "ERROR: blkid command not found."
  exit 1
fi

#
# Find GLIM partition (sdb1 - FAT32 boot partition)
#
USBDEV1=`blkid -L GLIM | head -n 1`
if [[ -z "$USBDEV1" ]]; then
  echo "ERROR: no partition found with label 'GLIM', please create one."
  exit 1
fi
echo "Found GRUB partition with label 'GLIM' : ${USBDEV1}"

# Derive the base block device from the GLIM partition
# Handles both /dev/sdXN and /dev/nvme0n1pN style names
USBDEV=$(echo "$USBDEV1" | sed 's/p\?[0-9]*$//')
if [[ ! -b "$USBDEV" ]]; then
  echo "ERROR: ${USBDEV} block device not found."
  exit 1
fi
echo "Found block device : ${USBDEV}"

# *** REMOVED the single-partition-only check ***
# We now expect exactly 3 partitions: GLIM (FAT32), ISO (ext4), USB (exFAT)

#
# Find ISO partition (sdb2 - ext4 ISO storage partition)
#
ISODEV=`blkid -L ISO | head -n 1`
if [[ -z "$ISODEV" ]]; then
  echo "ERROR: no partition found with label 'ISO', please create one (ext4)."
  exit 1
fi
echo "Found ISO partition with label 'ISO'  : ${ISODEV}"

# Sanity check: both partitions are on the same device
ISODEV_BASE=$(echo "$ISODEV" | sed 's/p\?[0-9]*$//')
if [[ "$ISODEV_BASE" != "$USBDEV" ]]; then
  echo "ERROR: GLIM (${USBDEV1}) and ISO (${ISODEV}) are not on the same device."
  exit 1
fi

#
# Check mount points
#
if ! grep -q -w ${USBDEV1} /proc/mounts; then
  echo "ERROR: ${USBDEV1} isn't mounted"
  exit 1
fi
USBMNT=`grep -w ${USBDEV1} /proc/mounts | cut -d ' ' -f 2`
echo "Found mount point for GLIM partition  : ${USBMNT}"

if ! grep -q -w ${ISODEV} /proc/mounts; then
  echo "ERROR: ${ISODEV} isn't mounted. Please mount your ISO partition first."
  exit 1
fi
ISOMNT=`grep -w ${ISODEV} /proc/mounts | cut -d ' ' -f 2`
echo "Found mount point for ISO partition   : ${ISOMNT}"

#
# BIOS / EFI mode support
#
echo "Boot mode support:"
echo "  1) BIOS only"
echo "  2) EFI only"
echo "  3) Both BIOS and EFI (default)"
read -n 1 -s -p "Choose [1/2/3]: " BOOTMODE
echo ""

case "$BOOTMODE" in
  1) BIOS=true;  EFI=false ;;
  2) BIOS=false; EFI=true  ;;
  *)  BIOS=true;  EFI=true  ;;  # default: both
esac

if [[ ! -d /usr/lib/grub/i386-pc ]]; then
  echo "WARNING: no /usr/lib/grub/i386-pc dir. Skipping Grub BIOS support"
  BIOS=false
fi

if [[ $EFI == true && ! -d /usr/lib/grub/x86_64-efi ]]; then
  if [[ $BIOS == false ]]; then
    echo "ERROR: neither support for BIOS or EFI was found"
    exit 1
  else
    echo "WARNING: no /usr/lib/grub/x86_64-efi dir (grub2-efi-x64-modules rpm or grub-efi-amd64-bin deb missing?)"
  fi
fi

#
# Confirm before proceeding
#
echo ""
echo "  GRUB bootloader  -> ${USBDEV}  (boot dir on ${USBMNT}/boot)"
echo "  ISO images dir   -> ${ISOMNT}/iso"
echo ""
read -n 1 -s -p "Ready to install GLIM. Continue? (Y/n) " PROCEED
if [[ "$PROCEED" == "n" ]]; then
  echo "n"
  exit 2
else
  echo "y"
fi

#
# Install GRUB2 onto the block device, boot files go on sdb1 (FAT32)
#
if [[ $BIOS == true ]]; then
  GRUB_TARGET="--target=i386-pc"
  echo "Running ${GRUB2_INSTALL} ${GRUB_TARGET} --boot-directory=${USBMNT}/boot ${USBDEV} ..."
  sudo ${GRUB2_INSTALL} ${GRUB_TARGET} --boot-directory=${USBMNT}/boot ${USBDEV}
  if [[ $? -ne 0 ]]; then
    echo "ERROR: ${GRUB2_INSTALL} returned with an error exit status."
    exit 1
  fi
fi
if [[ $EFI == true ]]; then
  GRUB_TARGET="--target=x86_64-efi --efi-directory=${USBMNT} --removable"
  echo "Running ${GRUB2_INSTALL} ${GRUB_TARGET} --boot-directory=${USBMNT}/boot ${USBDEV} ..."
  sudo ${GRUB2_INSTALL} ${GRUB_TARGET} --boot-directory=${USBMNT}/boot ${USBDEV}
  if [[ $? -ne 0 ]]; then
    echo "ERROR: ${GRUB2_INSTALL} returned with an error exit status."
    exit 1
  fi
fi

# Check GLIM partition write permission
if [[ -w "${USBMNT}" ]]; then
  CMD_PREFIX=""
else
  CMD_PREFIX="sudo"
fi

# Check ISO partition write permission (may differ from GLIM partition)
if [[ -w "${ISOMNT}" ]]; then
  ISO_CMD_PREFIX=""
else
  ISO_CMD_PREFIX="sudo"
fi

# Copy GRUB2 configuration onto the FAT32 partition
echo "Copying GRUB2 config to ${USBMNT}/boot/${GRUB2_DIR} ..."
${CMD_PREFIX} rsync -rt --delete \
  --exclude=i386-pc --exclude=x86_64-efi --exclude=fonts \
  ${GRUB2_CONF}/ ${USBMNT}/boot/${GRUB2_DIR}
if [[ $? -ne 0 ]]; then
  echo "ERROR: the rsync copy returned with an error exit status."
  exit 1
fi

#
# Create ISO sub-directories on the ISO partition (sdb2), not on sdb1
#
[[ -d ${ISOMNT}/iso ]] || ${ISO_CMD_PREFIX} mkdir ${ISOMNT}/iso
echo "GLIM installed! Time to populate ${ISOMNT}/iso/ sub-directories."

args=(
  -E -n
  '/\(distro-list-start\)/,/\(distro-list-end\)/{s,^\* \[`([a-z0-9]+)`\].*$,\1,p}'
)
for DIR in $(sed "${args[@]}" "$(dirname "$0")"/README.md); do
  [[ -d ${ISOMNT}/iso/${DIR} ]] || ${ISO_CMD_PREFIX} mkdir ${ISOMNT}/iso/${DIR}
done
