#!/usr/bin/env bash

function vm_delete() {
  if [ -f "${disk_img}" ]; then
    rm "${disk_img}"
    echo "SUCCESS! Deleted ${disk_img}"
  fi
  exit 0
}

function vm_restore() {
  if [ -f "${disk_img_snapshot}" ]; then
    mv "${disk_img_snapshot}" "${disk_img}"
  fi
  echo "SUCCESS! Restored ${disk_img_snapshot}"
  exit 0
}

function vm_snapshot() {
  if [ -f "${disk_img_snapshot}" ]; then
    mv "${disk_img_snapshot}" "${disk_img_snapshot}.old"
  fi
  qemu-img create -b "${disk_img}" -f qcow2 "${disk_img_snapshot}" -q
  if [ $? -eq 0 ]; then
    echo "SUCCESS! Created ${disk_img_snapshot}"
  else
    echo "ERROR! Failed to create ${disk_img_snapshot}"
  fi
  exit 0
}

function get_port() {
    local PORT_START=22220
    local PORT_RANGE=9
    while true; do
        local CANDIDATE=$[${PORT_START} + (${RANDOM} % ${PORT_RANGE})]
        (echo "" >/dev/tcp/127.0.0.1/${CANDIDATE}) >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "${CANDIDATE}"
            break
        fi
    done
}

function vm_boot() {
  local VMNAME=$(basename ${VM} .conf)
  local BIOS=""
  local GL="on"
  local VIRGL="on"
  local UI="sdl"
  local QEMU_VER=$(${QEMU} -version | head -n1 | cut -d' ' -f4 | cut -d'(' -f1)
  echo "Starting ${VM}"
  echo " - QEMU:     ${QEMU} v${QEMU_VER}"

  if [ ${ENABLE_EFI} -eq 1 ]; then
    if [ -e /snap/qemu-virgil/current/usr/share/qemu/edk2-x86_64-code.fd ] ; then
      BIOS="-drive if=pflash,format=raw,readonly,file=/snap/qemu-virgil/current/usr/share/qemu/edk2-x86_64-code.fd"
      VIRGL="off"
    else
      echo " - EFI:      Booting requested but no EFI firmware found."
      echo "             Booting from Legacy BIOS."
    fi
    echo " - BIOS:     EFI"
  else
    echo " - BIOS:     Legacy"
  fi

  if [ -n "${disk_img}" ]; then
    disk_img_snapshot="${disk_img}.snapshot"
  else
    echo "ERROR! No disk_img defined."
    exit 1
  fi  

  if [ -z "${disk}" ]; then
    disk="64G"
  fi

  echo " - Disk:     ${disk_img} (${disk})"
  # If the disk is present but doesn't appear to have an install, then
  # remove it.
  if [ -e ${disk_img} ]; then
    local disk_curr_size=$(stat -c%s "${disk_img}")
    if [ ${disk_curr_size} -le 395264 ]; then
      echo "             Looks unused, recreating."
      rm "${disk_img}"
    fi
  fi

  if [ ! -f "${disk_img}" ]; then
    # If there is no disk image, create a new image.
    ${QEMU_IMG} create -q -f qcow2 "${disk_img}" "${disk}"
    if [ $? -ne 0 ]; then
      echo "ERROR! Failed to create ${disk_img} of ${disk}. Stopping here."
      exit 1
    fi
    echo " - ISO:      ${iso}"
  else
    # If there is a disk image, do not boot from the iso
    iso=""
  fi
  if [ -e ${disk_img_snapshot} ]; then
    echo " - Snapshot: ${disk_img_snapshot}"
  fi

  local cores="1"
  local allcores=$(nproc --all)
  if [ ${allcores} -ge 8 ]; then
    cores="4"
  elif [ ${allcores} -ge 4 ]; then
    cores="2"
  fi
  echo " - CPU:      ${cores} Core(s)"

  local ram="2G"
  local allram=$(free --mega -h | grep Mem | cut -d':' -f2 | cut -d'G' -f1 | sed 's/ //g')
  if [ ${allram} -ge 64 ]; then
    ram="4G"
  elif [ ${allram} -ge 16 ]; then
    ram="3G"
  fi
  echo " - RAM:      ${ram}"

  # Determine what display to use
  local display="-display ${UI},gl=${GL}"
  echo " - UI:       ${UI}"
  echo " - GL:       ${GL}"
  echo " - VIRGL:    ${VIRGL}"

  local xres=1152
  local yres=648
  if [ "${XDG_SESSION_TYPE}" == "x11" ]; then
    local LOWEST_WIDTH=$(xrandr --listmonitors | grep -v Monitors | cut -d' ' -f4 | cut -d'/' -f1 | sort | head -n1)
    if [ ${LOWEST_WIDTH} -ge 3840 ]; then
      xres=3200
      yres=1800
    elif [ ${LOWEST_WIDTH} -ge 2560 ]; then
      xres=2048
      yres=1152
    elif [ ${LOWEST_WIDTH} -ge 1920 ]; then
      xres=1664
      yres=936
    elif [ ${LOWEST_WIDTH} -ge 1280 ]; then
      xres=1152
      yres=648
    fi
  fi
  echo " - Display:  ${xres}x${yres}"


  local NET=""
  # If smbd is available, export $HOME to the guest via samba
  if [ -e /snap/qemu-virgil/current/usr/sbin/smbd ]; then
      NET=",smb=${HOME}"
  fi

  if [ -n "${NET}" ]; then
    echo " - smbd:     ${HOME} will be exported to the guest via smb://10.0.2.4/qemu"
  else
    echo " - smbd:     ${HOME} will not be exported to the guest. 'smbd' not found."
  fi

  # Find a free port to expose ssh to the guest
  local PORT=$(get_port)
  if [ -n "${PORT}" ]; then
    NET="${NET},hostfwd=tcp::${PORT}-:22"
    echo " - ssh:      ${PORT}/tcp is connected. Login via 'ssh user@localhost -p ${PORT}'"
  else
    echo " - ssh:      All ports for exposing ssh have been exhausted."
  fi

  # Boot the iso image
  ${QEMU} -name ${VMNAME},process=${VMNAME} \
    ${BIOS} \
    -cdrom "${iso}" \
    -drive "file=${disk_img},format=qcow2,if=virtio,aio=native,cache.direct=on" \
    -enable-kvm \
    -machine q35,accel=kvm \
    -cpu host,kvm=on \
    -m ${ram} \
    -smp ${cores} \
    -net nic,model=virtio \
    -net user"${NET}" \
    -rtc base=localtime,clock=host \
    -serial mon:stdio \
    -audiodev pa,id=pa,server=unix:$XDG_RUNTIME_DIR/pulse/native,out.stream-name=${LAUNCHER}-${VMNAME},in.stream-name=${LAUNCHER}-${VMNAME} \
    -device intel-hda -device hda-duplex,audiodev=pa \
    -usb -device usb-kbd -device usb-tablet \
    -object rng-random,id=rng0,filename=/dev/urandom \
    -device virtio-rng-pci,rng=rng0 \
    -device virtio-vga,virgl=${VIRGL},xres=${xres},yres=${yres} \
    ${display} \
    "$@"
}

function usage() {
  echo
  echo "Usage"
  echo "  ${LAUNCHER} --vm ubuntu.conf"
  echo
  echo "You can also pass optional parameters"
  echo "  --delete   : Delete the disk image."
  echo "  --efi      : Enable EFI BIOS (experimental)."
  echo "  --restore  : Restore the snapshot."
  echo "  --snapshot : Create a disk snapshot."
  exit 1
}

DELETE=0
ENABLE_EFI=0
readonly QEMU="/snap/bin/qemu-virgil"
readonly QEMU_IMG="/snap/bin/qemu-virgil.qemu-img"
readonly LAUNCHER=$(basename $0)
RESTORE=0
SNAPSHOT=0
VM=""

while [ $# -gt 0 ]; do
  case "${1}" in
    -efi|--efi)
      ENABLE_EFI=1
      shift;;
    -delete|--delete)
      DELETE=1
      shift;;
    -restore|--restore)
      RESTORE=1
      shift;;
    -snapshot|--snapshot)
      SNAPSHOT=1
      shift;;
    -vm|--vm)
      VM="$2"
      shift
      shift;;
    -h|--h|-help|--help)
      usage;;
    *)
      echo "ERROR! \"${1}\" is not a supported parameter."
      usage;;
  esac
done

# Check we have qemu-virgil available
if [ ! -e "${QEMU}" ] && [ ! -e "${QEMU_IMG}" ]; then
  echo "ERROR! qemu-virgil not found. Please install the qemu-virgil snap."
  echo "       https://snapcraft.io/qemu-virgil"
  exit 1
fi

if [ -n "${VM}" ] || [ -e "${VM}" ]; then
  source "${VM}"
else
  echo "ERROR! Virtual machine configuration not found."
  usage
fi

if [ ${DELETE} -eq 1 ]; then
  vm_delete
fi

if [ ${RESTORE} -eq 1 ]; then
  vm_restore
fi

if [ ${SNAPSHOT} -eq 1 ]; then
  vm_snapshot
fi

vm_boot