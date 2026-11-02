Complete installation list — game-ready.sh
I reviewed the uploaded game-ready.sh installer. It provisions an extensive Arch Linux/Manjaro gaming environment, including Steam, Wine, Proton, Vulkan, GPU drivers, controller support, legacy game compatibility, performance monitoring, development tools, and system optimizations.

Important: This is the complete list of software the script is programmed to install or configure. It is not confirmation that every installation succeeded on your computer. Some components depend on your hardware, command-line options, downloads, or successful compilation.
1. Game launchers and compatibility
Software	Purpose
Steam	PC game launcher
Steam Native Runtime	Native Linux runtime for Steam
Lutris	Multi-platform game launcher
Heroic Games Launcher	Epic Games, GOG and Amazon game support
Bottles	Wine environment manager
Wine Staging	Run Windows applications and games
Winetricks	Wine configuration and dependencies
Wine Gecko	Wine browser/HTML support
Wine Mono	.NET compatibility
GE-Proton	Custom Proton build compiled from source
Protontricks	Manage Proton game prefixes
ProtonUp-Qt	Proton compatibility-tool manager
SteamTinkerLaunch	Advanced Steam launch customization

2. Graphics, Vulkan and DirectX compatibility
Software	Purpose
DXVK (dxvk-bin)	DirectX 8–11 translation to Vulkan
VKD3D	Direct3D 12-related compatibility libraries
VKD3D-Proton (vkd3d-proton-bin)	Direct3D 12 gaming translation
lib32-vkd3d	32-bit VKD3D libraries
Vulkan ICD Loader	Vulkan runtime
lib32-vulkan-icd-loader	32-bit Vulkan runtime
Vulkan Tools	Vulkan diagnostics
Mesa Utils	OpenGL utilities
Mesa	Open-source graphics libraries
lib32-mesa	32-bit Mesa libraries
Gamescope	Game-focused compositor
gxvk	3Dfx Glide-to-Vulkan compatibility
d7vk	Legacy DirectDraw/Direct3D-to-Vulkan
cnc-ddraw	Older 2D DirectDraw compatibility
dgVoodoo2	Legacy DirectX and Glide wrapper
dxvk-nvapi	NVIDIA NVAPI compatibility, conditional

GE-Proton, gxvk and d7vk involve source builds. dgVoodoo2 is downloaded separately, and these components may fail or be skipped independently.
3. GPU drivers and hardware support
Installed according to detected hardware, not all simultaneously.
Hardware	Driver packages
AMD	vulkan-radeon, lib32-vulkan-radeon, libva-mesa-driver, lib32-libva-mesa-driver
Intel	vulkan-intel, lib32-vulkan-intel, intel-media-driver
Intel Arc	intel-compute-runtime, vpl-gpu-rt
NVIDIA newer GPUs	nvidia-open-dkms, nvidia-utils, lib32-nvidia-utils, nvidia-settings
NVIDIA older GPUs	nvidia-dkms or legacy 470xx/390xx driver packages
NVIDIA OpenCL	opencl-nvidia, lib32-opencl-nvidia
Hybrid NVIDIA systems	nvidia-prime
Software fallback	vulkan-swrast
Optional development drivers	mesa-git, lib32-mesa-git

Additional graphics support includes vulkan-mesa-layers, lib32-vulkan-mesa-layers, linux-firmware, libva-utils and matching kernel headers when needed.

CPU microcode: amd-ucode or intel-ucode.
4. Performance, monitoring and recording
Software	Purpose
GameMode	Game performance optimization
lib32-gamemode	32-bit GameMode support
MangoHud	FPS and GPU/CPU overlay
lib32-mangohud	32-bit MangoHud support
GOverlay	Graphical overlay configuration
vkBasalt	Vulkan post-processing effects
lib32-vkbasalt	32-bit vkBasalt
OBS Studio	Screen and game recording
obs-vkcapture	Vulkan/OpenGL game capture
lib32-obs-vkcapture	32-bit game capture
nvtop	GPU usage monitoring
lm_sensors	Temperature and hardware monitoring
cpupower	CPU governor configuration
earlyoom	Memory exhaustion protection

The script also creates mangohud-toggle and vkbasalt-toggle commands.
5. Xbox, PlayStation and Bluetooth support
Package	Purpose
bluez	Bluetooth subsystem
bluez-utils	Bluetooth command tools
xpadneo-dkms	Xbox Bluetooth controller support
xone-dkms	Xbox wireless adapter support
game-devices-udev	Game controller device permissions
dualsensectl	DualSense controller controls
hid-sony	PlayStation support provided by kernel
hid-playstation	DualSense support provided by kernel

The PlayStation HID drivers are existing kernel components, not separately installed packages.
6. Storage, drives and filesystem utilities
The installer targets all of these packages:
Area	Packages
NTFS	ntfs-3g
exFAT	exfatprogs
FAT32	dosfstools
EXT filesystems	e2fsprogs
Btrfs	btrfs-progs
XFS	xfsprogs
F2FS	f2fs-tools
UDF	udftools
Mounting	udisks2, gvfs, gvfs-mtp
NVMe	nvme-cli
Drive health	smartmontools
Drive configuration	hdparm
Partitioning	gptfdisk, parted

It also includes an interactive drive-mounting wizard that can modify /etc/fstab and change ownership of selected drives.
7. Desktop applications
Application	Purpose
Thunar	File manager
thunar-volman	Removable drive management
thunar-archive-plugin	Archive integration
tumbler	Thumbnail generation
Xarchiver	Archive manager
GParted	Partition editor
GIMP	Image editing
Geany	Code/text editor
geany-plugins	Geany extensions
Zed	Code editor
nano	Terminal text editor
Mousepad	Lightweight graphical editor

8. Hex editing and legacy game patching
Software	Purpose
GHex	Graphical hex editor
ImHex	Advanced hex editor
hexedit	Terminal hex editor
radare2	Binary analysis and reverse engineering
inotify-tools	Filesystem monitoring

There is also a custom file-protection subsystem that backs up selected game executables and automatically restores them when changes are detected.
9. Development and source-compilation dependencies
The installer provisions these tools as needed:
- git
- base-devel
- yay or yay-bin
- podman
- fuse-overlayfs
- slirp4netns
- meson
- ninja
- mingw-w64-gcc
- glslang
- curl
- unzip
- pciutils
- util-linux
It also installs xorg-server, xorg-xinit, xorg-xrandr and xf86-input-libinput for display support.
10. 32-bit audio compatibility
Package	Installation
lib32-libpulse	Default
lib32-alsa-plugins	Default
lib32-alsa-lib	Default
lib32-openal	Default
lib32-pipewire	When PipeWire is installed
lib32-pipewire-jack	When pipewire-jack is installed

These are compatibility libraries; the script does not replace your existing audio server.

11. System changes and services
Beyond installing packages, game-ready.sh makes these system changes.
Change	Description
Multilib	Enables 32-bit Arch package repository
System upgrades	Runs pacman -Syu by default
GPU drivers	Detects hardware and installs selected drivers
Microcode	Configures Intel/AMD CPU microcode
Bluetooth service	Enables and starts Bluetooth
cpupower service	Requests performance CPU governor
earlyoom service	Enables out-of-memory protection
Game protection service	Creates game-ready-protect.service
System limits	Increases open-file limits
Memory mapping	Sets vm.max_map_count=2147483642
Wine compatibility	Installs and configures selected legacy DLL wrappers
GE-Proton	Builds and installs into Steam compatibility directories
fstab	Optional interactive persistent drive-mount configuration

12. Custom files and installation locations
Path	Contents
~/.local/share/Steam/compatibilitytools.d/	GE-Proton installations
~/ge-proton-build/	GE-Proton source/build files
~/.local/share/gxvk/x32/	gxvk DLLs
~/.local/share/d7vk/x32/	d7vk DLL
~/.local/share/cnc-ddraw/	cnc-ddraw files
~/.local/share/dgvoodoo2/	dgVoodoo2 files
~/.config/MangoHud/	MangoHud configuration
~/.config/vkBasalt/	vkBasalt configuration
~/.local/bin/mangohud-toggle	MangoHud toggle script
~/.local/bin/vkbasalt-toggle	vkBasalt toggle script
~/.local/share/game-ready/	Game-file protection system
/etc/systemd/system/game-ready-protect.service	Protection watcher service
~/game-ready-YYYYMMDD-HHMMSS.log	Installer execution log