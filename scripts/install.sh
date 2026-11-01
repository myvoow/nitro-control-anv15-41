#!/bin/sh
# Installs (or with --uninstall removes) NitroWMI.kext, the nitrocontrold launch daemon,
# nitroctl and Nitro Control.app. Run through "make install" / "make uninstall".
set -e
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo "run as root: make install"; exit 1; }
L=com.myvo.nitrocontrold

rebuild_aux() {
  echo "=== rebuild aux collection ==="
  kmutil create -n aux --allow-missing-kdk \
    -B /System/Library/KernelCollections/BootKernelExtensions.kc \
    -S /System/Library/KernelCollections/SystemKernelExtensions.kc \
    -A /Library/KernelCollections/AuxiliaryKernelExtensions.kc \
    -r /Library/Extensions
  echo "NitroWMI in the collection: $(LC_ALL=C grep -a -c com.myvo.NitroWMI /Library/KernelCollections/AuxiliaryKernelExtensions.kc || true)"
}

# The daemon hands the fans back to the EC on SIGTERM.
launchctl bootout system/$L 2>/dev/null || true

if [ "$1" = "--uninstall" ]; then
  rm -f /Library/LaunchDaemons/$L.plist /Library/LaunchAgents/com.myvo.NitroControl.plist \
    /Library/PrivilegedHelperTools/nitrocontrold /usr/local/bin/nitroctl
  rm -rf /Applications/NitroControl.app /Library/Extensions/NitroWMI.kext "/Library/Application Support/NitroControl"
  rebuild_aux
  echo "=== removed. Reboot to unload NitroWMI.kext. ==="
  exit 0
fi

for f in build/NitroWMI.kext build/NitroControl.app .build/release/nitrocontrold .build/release/nitroctl; do
  [ -e "$f" ] || { echo "missing $f: run make first"; exit 1; }
done

echo "=== install NitroWMI.kext ==="
rm -rf /Library/Extensions/NitroWMI.kext
cp -R build/NitroWMI.kext /Library/Extensions/
chown -R root:wheel /Library/Extensions/NitroWMI.kext
chmod -R 755 /Library/Extensions/NitroWMI.kext
rebuild_aux

echo "=== install nitrocontrold + nitroctl ==="
install -d -o root -g wheel /Library/PrivilegedHelperTools /usr/local/bin
install -o root -g wheel -m 755 .build/release/nitrocontrold /Library/PrivilegedHelperTools/nitrocontrold
install -o root -g wheel -m 755 .build/release/nitroctl /usr/local/bin/nitroctl
install -o root -g wheel -m 644 Resources/$L.plist /Library/LaunchDaemons/$L.plist
launchctl bootstrap system /Library/LaunchDaemons/$L.plist

echo "=== install Nitro Control.app ==="
rm -rf /Applications/NitroControl.app
cp -R build/NitroControl.app /Applications/
install -o root -g wheel -m 644 Resources/com.myvo.NitroControl.plist /Library/LaunchAgents/com.myvo.NitroControl.plist

echo "=== done. Approve in Privacy & Security if asked, reboot, then run: nitroctl sensors ==="
