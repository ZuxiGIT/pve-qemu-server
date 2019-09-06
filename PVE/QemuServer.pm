package PVE::QemuServer;

use strict;
use warnings;

use POSIX;
use IO::Handle;
use IO::Select;
use IO::File;
use IO::Dir;
use IO::Socket::UNIX;
use File::Basename;
use File::Path;
use File::stat;
use Getopt::Long;
use Digest::SHA;
use Fcntl ':flock';
use Cwd 'abs_path';
use IPC::Open3;
use JSON;
use Fcntl;
use PVE::SafeSyslog;
use Storable qw(dclone);
use MIME::Base64;
use PVE::Exception qw(raise raise_param_exc);
use PVE::Storage;
use PVE::Tools qw(run_command lock_file lock_file_full file_read_firstline dir_glob_foreach $IPV6RE);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_write_file cfs_lock_file);
use PVE::INotify;
use PVE::ProcFSTools;
use PVE::QemuConfig;
use PVE::QMPClient;
use PVE::RPCEnvironment;
use PVE::GuestHelpers;
use PVE::QemuServer::PCI qw(print_pci_addr print_pcie_addr print_pcie_root_port);
use PVE::QemuServer::Memory;
use PVE::QemuServer::USB qw(parse_usb_device);
use PVE::QemuServer::Cloudinit;
use PVE::SysFSTools;
use PVE::Systemd;
use Time::HiRes qw(gettimeofday);
use File::Copy qw(copy);
use URI::Escape;

my $EDK2_FW_BASE = '/usr/share/pve-edk2-firmware/';
my $OVMF = {
    x86_64 => [
	"$EDK2_FW_BASE/OVMF_CODE.fd",
	"$EDK2_FW_BASE/OVMF_VARS.fd"
    ],
    aarch64 => [
	"$EDK2_FW_BASE/AAVMF_CODE.fd",
	"$EDK2_FW_BASE/AAVMF_VARS.fd"
    ],
};

my $qemu_snap_storage = { rbd => 1 };

my $cpuinfo = PVE::ProcFSTools::read_cpuinfo();

my $QEMU_FORMAT_RE = qr/raw|cow|qcow|qcow2|qed|vmdk|cloop/;

# Note about locking: we use flock on the config file protect
# against concurent actions.
# Aditionaly, we have a 'lock' setting in the config file. This
# can be set to 'migrate', 'backup', 'snapshot' or 'rollback'. Most actions are not
# allowed when such lock is set. But you can ignore this kind of
# lock with the --skiplock flag.

cfs_register_file('/qemu-server/',
		  \&parse_vm_config,
		  \&write_vm_config);

PVE::JSONSchema::register_standard_option('pve-qm-stateuri', {
    description => "Some command save/restore state from this location.",
    type => 'string',
    maxLength => 128,
    optional => 1,
});

PVE::JSONSchema::register_standard_option('pve-qm-image-format', {
    type => 'string',
    enum => [qw(raw cow qcow qed qcow2 vmdk cloop)],
    description => "The drive's backing file's data format.",
    optional => 1,
});

PVE::JSONSchema::register_standard_option('pve-qemu-machine', {
	description => "Specifies the Qemu machine type.",
	type => 'string',
	pattern => '(pc|pc(-i440fx)?-\d+\.\d+(\.pxe)?|q35|pc-q35-\d+\.\d+(\.pxe)?|virt(?:-\d+\.\d+)?)',
	maxLength => 40,
	optional => 1,
});

#no warnings 'redefine';

sub cgroups_write {
   my ($controller, $vmid, $option, $value) = @_;

   my $path = "/sys/fs/cgroup/$controller/qemu.slice/$vmid.scope/$option";
   PVE::ProcFSTools::write_proc_entry($path, $value);

}

my $nodename = PVE::INotify::nodename();

mkdir "/etc/pve/nodes/$nodename";
my $confdir = "/etc/pve/nodes/$nodename/qemu-server";
mkdir $confdir;

my $var_run_tmpdir = "/var/run/qemu-server";
mkdir $var_run_tmpdir;

my $lock_dir = "/var/lock/qemu-server";
mkdir $lock_dir;

my $cpu_vendor_list = {
    # Intel CPUs
    486 => 'GenuineIntel',
    pentium => 'GenuineIntel',
    pentium2  => 'GenuineIntel',
    pentium3  => 'GenuineIntel',
    coreduo => 'GenuineIntel',
    core2duo => 'GenuineIntel',
    Conroe  => 'GenuineIntel',
    Penryn  => 'GenuineIntel',
    Nehalem  => 'GenuineIntel',
    'Nehalem-IBRS'  => 'GenuineIntel',
    Westmere => 'GenuineIntel',
    'Westmere-IBRS' => 'GenuineIntel',
    SandyBridge => 'GenuineIntel',
    'SandyBridge-IBRS' => 'GenuineIntel',
    IvyBridge => 'GenuineIntel',
    'IvyBridge-IBRS' => 'GenuineIntel',
    Haswell => 'GenuineIntel',
    'Haswell-IBRS' => 'GenuineIntel',
    'Haswell-noTSX' => 'GenuineIntel',
    'Haswell-noTSX-IBRS' => 'GenuineIntel',
    Broadwell => 'GenuineIntel',
    'Broadwell-IBRS' => 'GenuineIntel',
    'Broadwell-noTSX' => 'GenuineIntel',
    'Broadwell-noTSX-IBRS' => 'GenuineIntel',
    'Skylake-Client' => 'GenuineIntel',
    'Skylake-Client-IBRS' => 'GenuineIntel',
    'Skylake-Server' => 'GenuineIntel',
    'Skylake-Server-IBRS' => 'GenuineIntel',

    # AMD CPUs
    athlon => 'AuthenticAMD',
    phenom  => 'AuthenticAMD',
    Opteron_G1  => 'AuthenticAMD',
    Opteron_G2  => 'AuthenticAMD',
    Opteron_G3  => 'AuthenticAMD',
    Opteron_G4  => 'AuthenticAMD',
    Opteron_G5  => 'AuthenticAMD',
    EPYC => 'AuthenticAMD',
    'EPYC-IBPB' => 'AuthenticAMD',

    # generic types, use vendor from host node
    host => 'default',
    kvm32 => 'default',
    kvm64 => 'default',
    qemu32 => 'default',
    qemu64 => 'default',
    max => 'default',
};

my @supported_cpu_flags = (
    'pcid',
    'spec-ctrl',
    'ibpb',
    'ssbd',
    'virt-ssbd',
    'amd-ssbd',
    'amd-no-ssb',
    'pdpe1gb',
    'md-clear',
    'hv-tlbflush',
    'hv-evmcs',
    'aes'
);
my $cpu_flag = qr/[+-](@{[join('|', @supported_cpu_flags)]})/;

my $cpu_fmt = {
    cputype => {
	description => "Emulated CPU type.",
	type => 'string',
	enum => [ sort { "\L$a" cmp "\L$b" } keys %$cpu_vendor_list ],
	default => 'kvm64',
	default_key => 1,
    },
    hidden => {
	description => "Do not identify as a KVM virtual machine.",
	type => 'boolean',
	optional => 1,
	default => 0
    },
    'hv-vendor-id' => {
	type => 'string',
	pattern => qr/[a-zA-Z0-9]{1,12}/,
	format_description => 'vendor-id',
	description => 'The Hyper-V vendor ID. Some drivers or programs inside Windows guests need a specific ID.',
	optional => 1,
    },
    flags => {
	description => "List of additional CPU flags separated by ';'."
		     . " Use '+FLAG' to enable, '-FLAG' to disable a flag."
		     . " Currently supported flags: @{[join(', ', @supported_cpu_flags)]}.",
	format_description => '+FLAG[;-FLAG...]',
	type => 'string',
	pattern => qr/$cpu_flag(;$cpu_flag)*/,
	optional => 1,
    },
};

my $watchdog_fmt = {
    model => {
	default_key => 1,
	type => 'string',
	enum => [qw(i6300esb ib700)],
	description => "Watchdog type to emulate.",
	default => 'i6300esb',
	optional => 1,
    },
    action => {
	type => 'string',
	enum => [qw(reset shutdown poweroff pause debug none)],
	description => "The action to perform if after activation the guest fails to poll the watchdog in time.",
	optional => 1,
    },
};
PVE::JSONSchema::register_format('pve-qm-watchdog', $watchdog_fmt);

my $agent_fmt = {
    enabled => {
	description => "Enable/disable Qemu GuestAgent.",
	type => 'boolean',
	default => 0,
	default_key => 1,
    },
    fstrim_cloned_disks => {
	description => "Run fstrim after cloning/moving a disk.",
	type => 'boolean',
	optional => 1,
	default => 0
    },
};

my $vga_fmt = {
    type => {
	description => "Select the VGA type.",
	type => 'string',
	default => 'std',
	optional => 1,
	default_key => 1,
	enum => [qw(cirrus qxl qxl2 qxl3 qxl4 none serial0 serial1 serial2 serial3 std virtio vmware)],
    },
    memory => {
	description => "Sets the VGA memory (in MiB). Has no effect with serial display.",
	type => 'integer',
	optional => 1,
	minimum => 4,
	maximum => 512,
    },
};

my $ivshmem_fmt = {
    size => {
	type => 'integer',
	minimum => 1,
	description => "The size of the file in MB.",
    },
    name => {
	type => 'string',
	pattern => '[a-zA-Z0-9\-]+',
	optional => 1,
	format_description => 'string',
	description => "The name of the file. Will be prefixed with 'pve-shm-'. Default is the VMID. Will be deleted when the VM is stopped.",
    },
};

my $audio_fmt = {
    device => {
	type => 'string',
	enum => [qw(ich9-intel-hda intel-hda AC97)],
	description =>  "Configure an audio device."
    },
    driver =>  {
	type => 'string',
	enum => ['spice'],
	default => 'spice',
	optional => 1,
	description => "Driver backend for the audio device."
    },
};

my $spice_enhancements_fmt = {
    foldersharing => {
	type => 'boolean',
	optional => 1,
	default => '0',
	description =>  "Enable folder sharing via SPICE. Needs Spice-WebDAV daemon installed in the VM."
    },
    videostreaming =>  {
	type => 'string',
	enum => ['off', 'all', 'filter'],
	default => 'off',
	optional => 1,
	description => "Enable video streaming. Uses compression for detected video streams."
    },
};

my $confdesc = {
    onboot => {
	optional => 1,
	type => 'boolean',
	description => "Specifies whether a VM will be started during system bootup.",
	default => 0,
    },
    autostart => {
	optional => 1,
	type => 'boolean',
	description => "Automatic restart after crash (currently ignored).",
	default => 0,
    },
    hotplug => {
        optional => 1,
        type => 'string', format => 'pve-hotplug-features',
        description => "Selectively enable hotplug features. This is a comma separated list of hotplug features: 'network', 'disk', 'cpu', 'memory' and 'usb'. Use '0' to disable hotplug completely. Value '1' is an alias for the default 'network,disk,usb'.",
        default => 'network,disk,usb',
    },
    reboot => {
	optional => 1,
	type => 'boolean',
	description => "Allow reboot. If set to '0' the VM exit on reboot.",
	default => 1,
    },
    lock => {
	optional => 1,
	type => 'string',
	description => "Lock/unlock the VM.",
	enum => [qw(backup clone create migrate rollback snapshot snapshot-delete suspending suspended)],
    },
    cpulimit => {
	optional => 1,
	type => 'number',
	description => "Limit of CPU usage.",
        verbose_description => "Limit of CPU usage.\n\nNOTE: If the computer has 2 CPUs, it has total of '2' CPU time. Value '0' indicates no CPU limit.",
	minimum => 0,
	maximum => 128,
        default => 0,
    },
    cpuunits => {
	optional => 1,
	type => 'integer',
        description => "CPU weight for a VM.",
	verbose_description => "CPU weight for a VM. Argument is used in the kernel fair scheduler. The larger the number is, the more CPU time this VM gets. Number is relative to weights of all the other running VMs.",
	minimum => 2,
	maximum => 262144,
	default => 1024,
    },
    memory => {
	optional => 1,
	type => 'integer',
	description => "Amount of RAM for the VM in MB. This is the maximum available memory when you use the balloon device.",
	minimum => 16,
	default => 512,
    },
    balloon => {
        optional => 1,
        type => 'integer',
        description => "Amount of target RAM for the VM in MB. Using zero disables the ballon driver.",
	minimum => 0,
    },
    shares => {
        optional => 1,
        type => 'integer',
        description => "Amount of memory shares for auto-ballooning. The larger the number is, the more memory this VM gets. Number is relative to weights of all other running VMs. Using zero disables auto-ballooning. Auto-ballooning is done by pvestatd.",
	minimum => 0,
	maximum => 50000,
	default => 1000,
    },
    keyboard => {
	optional => 1,
	type => 'string',
	description => "Keybord layout for vnc server. Default is read from the '/etc/pve/datacenter.cfg' configuration file.".
		       "It should not be necessary to set it.",
	enum => PVE::Tools::kvmkeymaplist(),
	default => undef,
    },
    name => {
	optional => 1,
	type => 'string', format => 'dns-name',
	description => "Set a name for the VM. Only used on the configuration web interface.",
    },
    scsihw => {
	optional => 1,
	type => 'string',
	description => "SCSI controller model",
	enum => [qw(lsi lsi53c810 virtio-scsi-pci virtio-scsi-single megasas pvscsi)],
	default => 'lsi',
    },
    description => {
	optional => 1,
	type => 'string',
	description => "Description for the VM. Only used on the configuration web interface. This is saved as comment inside the configuration file.",
    },
    ostype => {
	optional => 1,
	type => 'string',
        enum => [qw(other wxp w2k w2k3 w2k8 wvista win7 win8 win10 l24 l26 solaris)],
	description => "Specify guest operating system.",
	verbose_description => <<EODESC,
Specify guest operating system. This is used to enable special
optimization/features for specific operating systems:

[horizontal]
other;; unspecified OS
wxp;; Microsoft Windows XP
w2k;; Microsoft Windows 2000
w2k3;; Microsoft Windows 2003
w2k8;; Microsoft Windows 2008
wvista;; Microsoft Windows Vista
win7;; Microsoft Windows 7
win8;; Microsoft Windows 8/2012/2012r2
win10;; Microsoft Windows 10/2016
l24;; Linux 2.4 Kernel
l26;; Linux 2.6/3.X Kernel
solaris;; Solaris/OpenSolaris/OpenIndiania kernel
EODESC
    },
    boot => {
	optional => 1,
	type => 'string',
	description => "Boot on floppy (a), hard disk (c), CD-ROM (d), or network (n).",
	pattern => '[acdn]{1,4}',
	default => 'cdn',
    },
    bootdisk => {
	optional => 1,
	type => 'string', format => 'pve-qm-bootdisk',
	description => "Enable booting from specified disk.",
	pattern => '(ide|sata|scsi|virtio)\d+',
    },
    smp => {
	optional => 1,
	type => 'integer',
	description => "The number of CPUs. Please use option -sockets instead.",
	minimum => 1,
	default => 1,
    },
    sockets => {
	optional => 1,
	type => 'integer',
	description => "The number of CPU sockets.",
	minimum => 1,
	default => 1,
    },
    cores => {
	optional => 1,
	type => 'integer',
	description => "The number of cores per socket.",
	minimum => 1,
	default => 1,
    },
    numa => {
	optional => 1,
	type => 'boolean',
	description => "Enable/disable NUMA.",
	default => 0,
    },
    hugepages => {
	optional => 1,
	type => 'string',
	description => "Enable/disable hugepages memory.",
	enum => [qw(any 2 1024)],
    },
    vcpus => {
	optional => 1,
	type => 'integer',
	description => "Number of hotplugged vcpus.",
	minimum => 1,
	default => 0,
    },
    acpi => {
	optional => 1,
	type => 'boolean',
	description => "Enable/disable ACPI.",
	default => 1,
    },
    agent => {
	optional => 1,
	description => "Enable/disable Qemu GuestAgent and its properties.",
	type => 'string',
	format => $agent_fmt,
    },
    kvm => {
	optional => 1,
	type => 'boolean',
	description => "Enable/disable KVM hardware virtualization.",
	default => 1,
    },
    tdf => {
	optional => 1,
	type => 'boolean',
	description => "Enable/disable time drift fix.",
	default => 0,
    },
    localtime => {
	optional => 1,
	type => 'boolean',
	description => "Set the real time clock to local time. This is enabled by default if ostype indicates a Microsoft OS.",
    },
    freeze => {
	optional => 1,
	type => 'boolean',
	description => "Freeze CPU at startup (use 'c' monitor command to start execution).",
    },
    vga => {
	optional => 1,
	type => 'string', format => $vga_fmt,
	description => "Configure the VGA hardware.",
	verbose_description => "Configure the VGA Hardware. If you want to use ".
	    "high resolution modes (>= 1280x1024x16) you may need to increase " .
	    "the vga memory option. Since QEMU 2.9 the default VGA display type " .
	    "is 'std' for all OS types besides some Windows versions (XP and " .
	    "older) which use 'cirrus'. The 'qxl' option enables the SPICE " .
	    "display server. For win* OS you can select how many independent " .
	    "displays you want, Linux guests can add displays them self.\n".
	    "You can also run without any graphic card, using a serial device as terminal.",
    },
    watchdog => {
	optional => 1,
	type => 'string', format => 'pve-qm-watchdog',
	description => "Create a virtual hardware watchdog device.",
	verbose_description => "Create a virtual hardware watchdog device. Once enabled" .
	    " (by a guest action), the watchdog must be periodically polled " .
	    "by an agent inside the guest or else the watchdog will reset " .
	    "the guest (or execute the respective action specified)",
    },
    startdate => {
	optional => 1,
	type => 'string',
	typetext => "(now | YYYY-MM-DD | YYYY-MM-DDTHH:MM:SS)",
	description => "Set the initial date of the real time clock. Valid format for date are: 'now' or '2006-06-17T16:01:21' or '2006-06-17'.",
	pattern => '(now|\d{4}-\d{1,2}-\d{1,2}(T\d{1,2}:\d{1,2}:\d{1,2})?)',
	default => 'now',
    },
    startup =>  get_standard_option('pve-startup-order'),
    template => {
	optional => 1,
	type => 'boolean',
	description => "Enable/disable Template.",
	default => 0,
    },
    args => {
	optional => 1,
	type => 'string',
	description => "Arbitrary arguments passed to kvm.",
	verbose_description => <<EODESCR,
Arbitrary arguments passed to kvm, for example:

args: -no-reboot -no-hpet

NOTE: this option is for experts only.
EODESCR
    },
    tablet => {
	optional => 1,
	type => 'boolean',
	default => 1,
	description => "Enable/disable the USB tablet device.",
	verbose_description => "Enable/disable the USB tablet device. This device is " .
	    "usually needed to allow absolute mouse positioning with VNC. " .
	    "Else the mouse runs out of sync with normal VNC clients. " .
	    "If you're running lots of console-only guests on one host, " .
	    "you may consider disabling this to save some context switches. " .
	    "This is turned off by default if you use spice (-vga=qxl).",
    },
    migrate_speed => {
	optional => 1,
	type => 'integer',
	description => "Set maximum speed (in MB/s) for migrations. Value 0 is no limit.",
	minimum => 0,
	default => 0,
    },
    migrate_downtime => {
	optional => 1,
	type => 'number',
	description => "Set maximum tolerated downtime (in seconds) for migrations.",
	minimum => 0,
	default => 0.1,
    },
    cdrom => {
	optional => 1,
	type => 'string', format => 'pve-qm-ide',
	typetext => '<volume>',
	description => "This is an alias for option -ide2",
    },
    cpu => {
	optional => 1,
	description => "Emulated CPU type.",
	type => 'string',
	format => $cpu_fmt,
    },
    parent => get_standard_option('pve-snapshot-name', {
	optional => 1,
	description => "Parent snapshot name. This is used internally, and should not be modified.",
    }),
    snaptime => {
	optional => 1,
	description => "Timestamp for snapshots.",
	type => 'integer',
	minimum => 0,
    },
    vmstate => {
	optional => 1,
	type => 'string', format => 'pve-volume-id',
	description => "Reference to a volume which stores the VM state. This is used internally for snapshots.",
    },
    vmstatestorage => get_standard_option('pve-storage-id', {
	description => "Default storage for VM state volumes/files.",
	optional => 1,
    }),
    runningmachine => get_standard_option('pve-qemu-machine', {
	description => "Specifies the Qemu machine type of the running vm. This is used internally for snapshots.",
    }),
    machine => get_standard_option('pve-qemu-machine'),
    arch => {
	description => "Virtual processor architecture. Defaults to the host.",
	optional => 1,
	type => 'string',
	enum => [qw(x86_64 aarch64)],
    },
    smbios1 => {
	description => "Specify SMBIOS type 1 fields.",
	type => 'string', format => 'pve-qm-smbios1',
	maxLength => 512,
	optional => 1,
    },
    protection => {
	optional => 1,
	type => 'boolean',
	description => "Sets the protection flag of the VM. This will disable the remove VM and remove disk operations.",
	default => 0,
    },
    bios => {
	optional => 1,
	type => 'string',
	enum => [ qw(seabios ovmf) ],
	description => "Select BIOS implementation.",
	default => 'seabios',
    },
    vmgenid => {
	type => 'string',
	pattern => '(?:[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}|[01])',
	format_description => 'UUID',
	description => "Set VM Generation ID. Use '1' to autogenerate on create or update, pass '0' to disable explicitly.",
	verbose_description => "The VM generation ID (vmgenid) device exposes a".
	    " 128-bit integer value identifier to the guest OS. This allows to".
	    " notify the guest operating system when the virtual machine is".
	    " executed with a different configuration (e.g. snapshot execution".
	    " or creation from a template). The guest operating system notices".
	    " the change, and is then able to react as appropriate by marking".
	    " its copies of distributed databases as dirty, re-initializing its".
	    " random number generator, etc.\n".
	    "Note that auto-creation only works when done throug API/CLI create".
	    " or update methods, but not when manually editing the config file.",
	default => "1 (autogenerated)",
	optional => 1,
    },
    hookscript => {
	type => 'string',
	format => 'pve-volume-id',
	optional => 1,
	description => "Script that will be executed during various steps in the vms lifetime.",
    },
    ivshmem => {
	type => 'string',
	format => $ivshmem_fmt,
	description => "Inter-VM shared memory. Useful for direct communication between VMs, or to the host.",
	optional => 1,
    },
    audio0 => {
	type => 'string',
	format => $audio_fmt,
	description => "Configure a audio device, useful in combination with QXL/Spice.",
	optional => 1
    },
    spice_enhancements => {
	type => 'string',
	format => $spice_enhancements_fmt,
	description => "Configure additional enhancements for SPICE.",
	optional => 1
    },
};

my $cicustom_fmt = {
    meta => {
	type => 'string',
	optional => 1,
	description => 'Specify a custom file containing all meta data passed to the VM via cloud-init. This is provider specific meaning configdrive2 and nocloud differ.',
	format => 'pve-volume-id',
	format_description => 'volume',
    },
    network => {
	type => 'string',
	optional => 1,
	description => 'Specify a custom file containing all network data passed to the VM via cloud-init.',
	format => 'pve-volume-id',
	format_description => 'volume',
    },
    user => {
	type => 'string',
	optional => 1,
	description => 'Specify a custom file containing all user data passed to the VM via cloud-init.',
	format => 'pve-volume-id',
	format_description => 'volume',
    },
};
PVE::JSONSchema::register_format('pve-qm-cicustom', $cicustom_fmt);

my $confdesc_cloudinit = {
    citype => {
	optional => 1,
	type => 'string',
	description => 'Specifies the cloud-init configuration format. The default depends on the configured operating system type (`ostype`. We use the `nocloud` format for Linux, and `configdrive2` for windows.',
	enum => ['configdrive2', 'nocloud'],
    },
    ciuser => {
	optional => 1,
	type => 'string',
	description => "cloud-init: User name to change ssh keys and password for instead of the image's configured default user.",
    },
    cipassword => {
	optional => 1,
	type => 'string',
	description => 'cloud-init: Password to assign the user. Using this is generally not recommended. Use ssh keys instead. Also note that older cloud-init versions do not support hashed passwords.',
    },
    cicustom => {
	optional => 1,
	type => 'string',
	description => 'cloud-init: Specify custom files to replace the automatically generated ones at start.',
	format => 'pve-qm-cicustom',
    },
    searchdomain => {
	optional => 1,
	type => 'string',
	description => "cloud-init: Sets DNS search domains for a container. Create will automatically use the setting from the host if neither searchdomain nor nameserver are set.",
    },
    nameserver => {
	optional => 1,
	type => 'string', format => 'address-list',
	description => "cloud-init: Sets DNS server IP address for a container. Create will automatically use the setting from the host if neither searchdomain nor nameserver are set.",
    },
    sshkeys => {
	optional => 1,
	type => 'string',
	format => 'urlencoded',
	description => "cloud-init: Setup public SSH keys (one key per line, OpenSSH format).",
    },
};

# what about other qemu settings ?
#cpu => 'string',
#machine => 'string',
#fda => 'file',
#fdb => 'file',
#mtdblock => 'file',
#sd => 'file',
#pflash => 'file',
#snapshot => 'bool',
#bootp => 'file',
##tftp => 'dir',
##smb => 'dir',
#kernel => 'file',
#append => 'string',
#initrd => 'file',
##soundhw => 'string',

while (my ($k, $v) = each %$confdesc) {
    PVE::JSONSchema::register_standard_option("pve-qm-$k", $v);
}

my $MAX_IDE_DISKS = 4;
my $MAX_SCSI_DISKS = 14;
my $MAX_VIRTIO_DISKS = 16;
my $MAX_SATA_DISKS = 6;
my $MAX_USB_DEVICES = 5;
my $MAX_NETS = 32;
my $MAX_UNUSED_DISKS = 256;
my $MAX_HOSTPCI_DEVICES = 16;
my $MAX_SERIAL_PORTS = 4;
my $MAX_PARALLEL_PORTS = 3;
my $MAX_NUMA = 8;

my $numa_fmt = {
    cpus => {
	type => "string",
	pattern => qr/\d+(?:-\d+)?(?:;\d+(?:-\d+)?)*/,
	description => "CPUs accessing this NUMA node.",
	format_description => "id[-id];...",
    },
    memory => {
	type => "number",
	description => "Amount of memory this NUMA node provides.",
	optional => 1,
    },
    hostnodes => {
	type => "string",
	pattern => qr/\d+(?:-\d+)?(?:;\d+(?:-\d+)?)*/,
	description => "Host NUMA nodes to use.",
	format_description => "id[-id];...",
	optional => 1,
    },
    policy => {
	type => 'string',
	enum => [qw(preferred bind interleave)],
	description => "NUMA allocation policy.",
	optional => 1,
    },
};
PVE::JSONSchema::register_format('pve-qm-numanode', $numa_fmt);
my $numadesc = {
    optional => 1,
    type => 'string', format => $numa_fmt,
    description => "NUMA topology.",
};
PVE::JSONSchema::register_standard_option("pve-qm-numanode", $numadesc);

for (my $i = 0; $i < $MAX_NUMA; $i++)  {
    $confdesc->{"numa$i"} = $numadesc;
}

my $nic_model_list = ['rtl8139', 'ne2k_pci', 'e1000',  'pcnet',  'virtio',
		      'ne2k_isa', 'i82551', 'i82557b', 'i82559er', 'vmxnet3',
		      'e1000-82540em', 'e1000-82544gc', 'e1000-82545em'];
my $nic_model_list_txt = join(' ', sort @$nic_model_list);

my $net_fmt_bridge_descr = <<__EOD__;
Bridge to attach the network device to. The Proxmox VE standard bridge
is called 'vmbr0'.

If you do not specify a bridge, we create a kvm user (NATed) network
device, which provides DHCP and DNS services. The following addresses
are used:

 10.0.2.2   Gateway
 10.0.2.3   DNS Server
 10.0.2.4   SMB Server

The DHCP server assign addresses to the guest starting from 10.0.2.15.
__EOD__

my $net_fmt = {
    macaddr  => get_standard_option('mac-addr', {
	description => "MAC address. That address must be unique withing your network. This is automatically generated if not specified.",
    }),
    model => {
	type => 'string',
	description => "Network Card Model. The 'virtio' model provides the best performance with very low CPU overhead. If your guest does not support this driver, it is usually best to use 'e1000'.",
        enum => $nic_model_list,
        default_key => 1,
    },
    (map { $_ => { keyAlias => 'model', alias => 'macaddr' }} @$nic_model_list),
    bridge => {
	type => 'string',
	description => $net_fmt_bridge_descr,
	format_description => 'bridge',
	optional => 1,
    },
    queues => {
	type => 'integer',
	minimum => 0, maximum => 16,
	description => 'Number of packet queues to be used on the device.',
	optional => 1,
    },
    rate => {
	type => 'number',
	minimum => 0,
	description => "Rate limit in mbps (megabytes per second) as floating point number.",
	optional => 1,
    },
    tag => {
	type => 'integer',
	minimum => 1, maximum => 4094,
	description => 'VLAN tag to apply to packets on this interface.',
	optional => 1,
    },
    trunks => {
	type => 'string',
	pattern => qr/\d+(?:-\d+)?(?:;\d+(?:-\d+)?)*/,
	description => 'VLAN trunks to pass through this interface.',
	format_description => 'vlanid[;vlanid...]',
	optional => 1,
    },
    firewall => {
	type => 'boolean',
	description => 'Whether this interface should be protected by the firewall.',
	optional => 1,
    },
    link_down => {
	type => 'boolean',
	description => 'Whether this interface should be disconnected (like pulling the plug).',
	optional => 1,
    },
};

my $netdesc = {
    optional => 1,
    type => 'string', format => $net_fmt,
    description => "Specify network devices.",
};

PVE::JSONSchema::register_standard_option("pve-qm-net", $netdesc);

my $ipconfig_fmt = {
    ip => {
	type => 'string',
	format => 'pve-ipv4-config',
	format_description => 'IPv4Format/CIDR',
	description => 'IPv4 address in CIDR format.',
	optional => 1,
	default => 'dhcp',
    },
    gw => {
	type => 'string',
	format => 'ipv4',
	format_description => 'GatewayIPv4',
	description => 'Default gateway for IPv4 traffic.',
	optional => 1,
	requires => 'ip',
    },
    ip6 => {
	type => 'string',
	format => 'pve-ipv6-config',
	format_description => 'IPv6Format/CIDR',
	description => 'IPv6 address in CIDR format.',
	optional => 1,
	default => 'dhcp',
    },
    gw6 => {
	type => 'string',
	format => 'ipv6',
	format_description => 'GatewayIPv6',
	description => 'Default gateway for IPv6 traffic.',
	optional => 1,
	requires => 'ip6',
    },
};
PVE::JSONSchema::register_format('pve-qm-ipconfig', $ipconfig_fmt);
my $ipconfigdesc = {
    optional => 1,
    type => 'string', format => 'pve-qm-ipconfig',
    description => <<'EODESCR',
cloud-init: Specify IP addresses and gateways for the corresponding interface.

IP addresses use CIDR notation, gateways are optional but need an IP of the same type specified.

The special string 'dhcp' can be used for IP addresses to use DHCP, in which case no explicit gateway should be provided.
For IPv6 the special string 'auto' can be used to use stateless autoconfiguration.

If cloud-init is enabled and neither an IPv4 nor an IPv6 address is specified, it defaults to using dhcp on IPv4.
EODESCR
};
PVE::JSONSchema::register_standard_option("pve-qm-ipconfig", $netdesc);

for (my $i = 0; $i < $MAX_NETS; $i++)  {
    $confdesc->{"net$i"} = $netdesc;
    $confdesc_cloudinit->{"ipconfig$i"} = $ipconfigdesc;
}

foreach my $key (keys %$confdesc_cloudinit) {
    $confdesc->{$key} = $confdesc_cloudinit->{$key};
}

PVE::JSONSchema::register_format('pve-volume-id-or-qm-path', \&verify_volume_id_or_qm_path);
sub verify_volume_id_or_qm_path {
    my ($volid, $noerr) = @_;

    if ($volid eq 'none' || $volid eq 'cdrom' || $volid =~ m|^/|) {
	return $volid;
    }

    # if its neither 'none' nor 'cdrom' nor a path, check if its a volume-id
    $volid = eval { PVE::JSONSchema::check_format('pve-volume-id', $volid, '') };
    if ($@) {
	return undef if $noerr;
	die $@;
    }
    return $volid;
}

my $drivename_hash;

my %drivedesc_base = (
    volume => { alias => 'file' },
    file => {
	type => 'string',
	format => 'pve-volume-id-or-qm-path',
	default_key => 1,
	format_description => 'volume',
	description => "The drive's backing volume.",
    },
    media => {
	type => 'string',
	enum => [qw(cdrom disk)],
	description => "The drive's media type.",
	default => 'disk',
	optional => 1
    },
    cyls => {
	type => 'integer',
	description => "Force the drive's physical geometry to have a specific cylinder count.",
	optional => 1
    },
    heads => {
	type => 'integer',
	description => "Force the drive's physical geometry to have a specific head count.",
	optional => 1
    },
    secs => {
	type => 'integer',
	description => "Force the drive's physical geometry to have a specific sector count.",
	optional => 1
    },
    trans => {
	type => 'string',
	enum => [qw(none lba auto)],
	description => "Force disk geometry bios translation mode.",
	optional => 1,
    },
    snapshot => {
	type => 'boolean',
	description => "Controls qemu's snapshot mode feature."
	    . " If activated, changes made to the disk are temporary and will"
	    . " be discarded when the VM is shutdown.",
	optional => 1,
    },
    cache => {
	type => 'string',
	enum => [qw(none writethrough writeback unsafe directsync)],
	description => "The drive's cache mode",
	optional => 1,
    },
    format => get_standard_option('pve-qm-image-format'),
    size => {
	type => 'string',
	format => 'disk-size',
	format_description => 'DiskSize',
	description => "Disk size. This is purely informational and has no effect.",
	optional => 1,
    },
    backup => {
	type => 'boolean',
	description => "Whether the drive should be included when making backups.",
	optional => 1,
    },
    replicate => {
	type => 'boolean',
	description => 'Whether the drive should considered for replication jobs.',
	optional => 1,
	default => 1,
    },
    rerror => {
	type => 'string',
	enum => [qw(ignore report stop)],
	description => 'Read error action.',
	optional => 1,
    },
    werror => {
	type => 'string',
	enum => [qw(enospc ignore report stop)],
	description => 'Write error action.',
	optional => 1,
    },
    aio => {
	type => 'string',
	enum => [qw(native threads)],
	description => 'AIO type to use.',
	optional => 1,
    },
    discard => {
	type => 'string',
	enum => [qw(ignore on)],
	description => 'Controls whether to pass discard/trim requests to the underlying storage.',
	optional => 1,
    },
    detect_zeroes => {
	type => 'boolean',
	description => 'Controls whether to detect and try to optimize writes of zeroes.',
	optional => 1,
    },
    serial => {
	type => 'string',
	format => 'urlencoded',
	format_description => 'serial',
	maxLength => 20*3, # *3 since it's %xx url enoded
	description => "The drive's reported serial number, url-encoded, up to 20 bytes long.",
	optional => 1,
    },
    shared => {
	type => 'boolean',
	description => 'Mark this locally-managed volume as available on all nodes',
	verbose_description => "Mark this locally-managed volume as available on all nodes.\n\nWARNING: This option does not share the volume automatically, it assumes it is shared already!",
	optional => 1,
	default => 0,
    }
);

my %iothread_fmt = ( iothread => {
	type => 'boolean',
	description => "Whether to use iothreads for this drive",
	optional => 1,
});

my %model_fmt = (
    model => {
	type => 'string',
	format => 'urlencoded',
	format_description => 'model',
	maxLength => 40*3, # *3 since it's %xx url enoded
	description => "The drive's reported model name, url-encoded, up to 40 bytes long.",
	optional => 1,
    },
);

my %queues_fmt = (
    queues => {
	type => 'integer',
	description => "Number of queues.",
	minimum => 2,
	optional => 1
    }
);

my %scsiblock_fmt = (
    scsiblock => {
	type => 'boolean',
	description => "whether to use scsi-block for full passthrough of host block device\n\nWARNING: can lead to I/O errors in combination with low memory or high memory fragmentation on host",
	optional => 1,
	default => 0,
    },
);

my %ssd_fmt = (
    ssd => {
	type => 'boolean',
	description => "Whether to expose this drive as an SSD, rather than a rotational hard disk.",
	optional => 1,
    },
);

my %wwn_fmt = (
    wwn => {
	type => 'string',
	pattern => qr/^(0x)[0-9a-fA-F]{16}/,
	format_description => 'wwn',
	description => "The drive's worldwide name, encoded as 16 bytes hex string, prefixed by '0x'.",
	optional => 1,
    },
);

my $add_throttle_desc = sub {
    my ($key, $type, $what, $unit, $longunit, $minimum) = @_;
    my $d = {
	type => $type,
	format_description => $unit,
	description => "Maximum $what in $longunit.",
	optional => 1,
    };
    $d->{minimum} = $minimum if defined($minimum);
    $drivedesc_base{$key} = $d;
};
# throughput: (leaky bucket)
$add_throttle_desc->('bps',     'integer', 'r/w speed',   'bps',  'bytes per second');
$add_throttle_desc->('bps_rd',  'integer', 'read speed',  'bps',  'bytes per second');
$add_throttle_desc->('bps_wr',  'integer', 'write speed', 'bps',  'bytes per second');
$add_throttle_desc->('mbps',    'number',  'r/w speed',   'mbps', 'megabytes per second');
$add_throttle_desc->('mbps_rd', 'number',  'read speed',  'mbps', 'megabytes per second');
$add_throttle_desc->('mbps_wr', 'number',  'write speed', 'mbps', 'megabytes per second');
$add_throttle_desc->('iops',    'integer', 'r/w I/O',     'iops', 'operations per second');
$add_throttle_desc->('iops_rd', 'integer', 'read I/O',    'iops', 'operations per second');
$add_throttle_desc->('iops_wr', 'integer', 'write I/O',   'iops', 'operations per second');

# pools: (pool of IO before throttling starts taking effect)
$add_throttle_desc->('mbps_max',    'number',  'unthrottled r/w pool',       'mbps', 'megabytes per second');
$add_throttle_desc->('mbps_rd_max', 'number',  'unthrottled read pool',      'mbps', 'megabytes per second');
$add_throttle_desc->('mbps_wr_max', 'number',  'unthrottled write pool',     'mbps', 'megabytes per second');
$add_throttle_desc->('iops_max',    'integer', 'unthrottled r/w I/O pool',   'iops', 'operations per second');
$add_throttle_desc->('iops_rd_max', 'integer', 'unthrottled read I/O pool',  'iops', 'operations per second');
$add_throttle_desc->('iops_wr_max', 'integer', 'unthrottled write I/O pool', 'iops', 'operations per second');

# burst lengths
$add_throttle_desc->('bps_max_length',     'integer', 'length of I/O bursts',       'seconds', 'seconds', 1);
$add_throttle_desc->('bps_rd_max_length',  'integer', 'length of read I/O bursts',  'seconds', 'seconds', 1);
$add_throttle_desc->('bps_wr_max_length',  'integer', 'length of write I/O bursts', 'seconds', 'seconds', 1);
$add_throttle_desc->('iops_max_length',    'integer', 'length of I/O bursts',       'seconds', 'seconds', 1);
$add_throttle_desc->('iops_rd_max_length', 'integer', 'length of read I/O bursts',  'seconds', 'seconds', 1);
$add_throttle_desc->('iops_wr_max_length', 'integer', 'length of write I/O bursts', 'seconds', 'seconds', 1);

# legacy support
$drivedesc_base{'bps_rd_length'} = { alias => 'bps_rd_max_length' };
$drivedesc_base{'bps_wr_length'} = { alias => 'bps_wr_max_length' };
$drivedesc_base{'iops_rd_length'} = { alias => 'iops_rd_max_length' };
$drivedesc_base{'iops_wr_length'} = { alias => 'iops_wr_max_length' };

my $ide_fmt = {
    %drivedesc_base,
    %model_fmt,
    %ssd_fmt,
    %wwn_fmt,
};
PVE::JSONSchema::register_format("pve-qm-ide", $ide_fmt);

my $idedesc = {
    optional => 1,
    type => 'string', format => $ide_fmt,
    description => "Use volume as IDE hard disk or CD-ROM (n is 0 to " .($MAX_IDE_DISKS -1) . ").",
};
PVE::JSONSchema::register_standard_option("pve-qm-ide", $idedesc);

my $scsi_fmt = {
    %drivedesc_base,
    %iothread_fmt,
    %queues_fmt,
    %scsiblock_fmt,
    %ssd_fmt,
    %wwn_fmt,
};
my $scsidesc = {
    optional => 1,
    type => 'string', format => $scsi_fmt,
    description => "Use volume as SCSI hard disk or CD-ROM (n is 0 to " . ($MAX_SCSI_DISKS - 1) . ").",
};
PVE::JSONSchema::register_standard_option("pve-qm-scsi", $scsidesc);

my $sata_fmt = {
    %drivedesc_base,
    %ssd_fmt,
    %wwn_fmt,
};
my $satadesc = {
    optional => 1,
    type => 'string', format => $sata_fmt,
    description => "Use volume as SATA hard disk or CD-ROM (n is 0 to " . ($MAX_SATA_DISKS - 1). ").",
};
PVE::JSONSchema::register_standard_option("pve-qm-sata", $satadesc);

my $virtio_fmt = {
    %drivedesc_base,
    %iothread_fmt,
};
my $virtiodesc = {
    optional => 1,
    type => 'string', format => $virtio_fmt,
    description => "Use volume as VIRTIO hard disk (n is 0 to " . ($MAX_VIRTIO_DISKS - 1) . ").",
};
PVE::JSONSchema::register_standard_option("pve-qm-virtio", $virtiodesc);

my $alldrive_fmt = {
    %drivedesc_base,
    %iothread_fmt,
    %model_fmt,
    %queues_fmt,
    %scsiblock_fmt,
    %ssd_fmt,
    %wwn_fmt,
};

my $efidisk_fmt = {
    volume => { alias => 'file' },
    file => {
	type => 'string',
	format => 'pve-volume-id-or-qm-path',
	default_key => 1,
	format_description => 'volume',
	description => "The drive's backing volume.",
    },
    format => get_standard_option('pve-qm-image-format'),
    size => {
	type => 'string',
	format => 'disk-size',
	format_description => 'DiskSize',
	description => "Disk size. This is purely informational and has no effect.",
	optional => 1,
    },
};

my $efidisk_desc = {
    optional => 1,
    type => 'string', format => $efidisk_fmt,
    description => "Configure a Disk for storing EFI vars",
};

PVE::JSONSchema::register_standard_option("pve-qm-efidisk", $efidisk_desc);

my $usb_fmt = {
    host => {
	default_key => 1,
	type => 'string', format => 'pve-qm-usb-device',
	format_description => 'HOSTUSBDEVICE|spice',
        description => <<EODESCR,
The Host USB device or port or the value 'spice'. HOSTUSBDEVICE syntax is:

 'bus-port(.port)*' (decimal numbers) or
 'vendor_id:product_id' (hexadeciaml numbers) or
 'spice'

You can use the 'lsusb -t' command to list existing usb devices.

NOTE: This option allows direct access to host hardware. So it is no longer possible to migrate such machines - use with special care.

The value 'spice' can be used to add a usb redirection devices for spice.
EODESCR
    },
    usb3 => {
	optional => 1,
	type => 'boolean',
	description => "Specifies whether if given host option is a USB3 device or port (this does currently not work reliably with spice redirection and is then ignored).",
        default => 0,
    },
};

my $usbdesc = {
    optional => 1,
    type => 'string', format => $usb_fmt,
    description => "Configure an USB device (n is 0 to 4).",
};
PVE::JSONSchema::register_standard_option("pve-qm-usb", $usbdesc);

my $PCIRE = qr/[a-f0-9]{2}:[a-f0-9]{2}(?:\.[a-f0-9])?/;
my $hostpci_fmt = {
    host => {
	default_key => 1,
	type => 'string',
	pattern => qr/$PCIRE(;$PCIRE)*/,
	format_description => 'HOSTPCIID[;HOSTPCIID2...]',
	description => <<EODESCR,
Host PCI device pass through. The PCI ID of a host's PCI device or a list
of PCI virtual functions of the host. HOSTPCIID syntax is:

'bus:dev.func' (hexadecimal numbers)

You can us the 'lspci' command to list existing PCI devices.
EODESCR
    },
    rombar => {
	type => 'boolean',
        description =>  "Specify whether or not the device's ROM will be visible in the guest's memory map.",
	optional => 1,
	default => 1,
    },
    romfile => {
        type => 'string',
        pattern => '[^,;]+',
        format_description => 'string',
        description => "Custom pci device rom filename (must be located in /usr/share/kvm/).",
        optional => 1,
    },
    pcie => {
	type => 'boolean',
        description =>  "Choose the PCI-express bus (needs the 'q35' machine model).",
	optional => 1,
	default => 0,
    },
    'x-vga' => {
	type => 'boolean',
        description =>  "Enable vfio-vga device support.",
	optional => 1,
	default => 0,
    },
    'mdev' => {
	type => 'string',
        format_description => 'string',
	pattern => '[^/\.:]+',
	optional => 1,
	description => <<EODESCR
The type of mediated device to use.
An instance of this type will be created on startup of the VM and
will be cleaned up when the VM stops.
EODESCR
    }
};
PVE::JSONSchema::register_format('pve-qm-hostpci', $hostpci_fmt);

my $hostpcidesc = {
        optional => 1,
        type => 'string', format => 'pve-qm-hostpci',
        description => "Map host PCI devices into guest.",
	verbose_description =>  <<EODESCR,
Map host PCI devices into guest.

NOTE: This option allows direct access to host hardware. So it is no longer
possible to migrate such machines - use with special care.

CAUTION: Experimental! User reported problems with this option.
EODESCR
};
PVE::JSONSchema::register_standard_option("pve-qm-hostpci", $hostpcidesc);

my $serialdesc = {
	optional => 1,
	type => 'string',
	pattern => '(/dev/.+|socket)',
	description =>  "Create a serial device inside the VM (n is 0 to 3)",
	verbose_description =>  <<EODESCR,
Create a serial device inside the VM (n is 0 to 3), and pass through a
host serial device (i.e. /dev/ttyS0), or create a unix socket on the
host side (use 'qm terminal' to open a terminal connection).

NOTE: If you pass through a host serial device, it is no longer possible to migrate such machines - use with special care.

CAUTION: Experimental! User reported problems with this option.
EODESCR
};

my $paralleldesc= {
	optional => 1,
	type => 'string',
        pattern => '/dev/parport\d+|/dev/usb/lp\d+',
	description =>  "Map host parallel devices (n is 0 to 2).",
	verbose_description =>  <<EODESCR,
Map host parallel devices (n is 0 to 2).

NOTE: This option allows direct access to host hardware. So it is no longer possible to migrate such machines - use with special care.

CAUTION: Experimental! User reported problems with this option.
EODESCR
};

for (my $i = 0; $i < $MAX_PARALLEL_PORTS; $i++)  {
    $confdesc->{"parallel$i"} = $paralleldesc;
}

for (my $i = 0; $i < $MAX_SERIAL_PORTS; $i++)  {
    $confdesc->{"serial$i"} = $serialdesc;
}

for (my $i = 0; $i < $MAX_HOSTPCI_DEVICES; $i++)  {
    $confdesc->{"hostpci$i"} = $hostpcidesc;
}

for (my $i = 0; $i < $MAX_IDE_DISKS; $i++)  {
    $drivename_hash->{"ide$i"} = 1;
    $confdesc->{"ide$i"} = $idedesc;
}

for (my $i = 0; $i < $MAX_SATA_DISKS; $i++)  {
    $drivename_hash->{"sata$i"} = 1;
    $confdesc->{"sata$i"} = $satadesc;
}

for (my $i = 0; $i < $MAX_SCSI_DISKS; $i++)  {
    $drivename_hash->{"scsi$i"} = 1;
    $confdesc->{"scsi$i"} = $scsidesc ;
}

for (my $i = 0; $i < $MAX_VIRTIO_DISKS; $i++)  {
    $drivename_hash->{"virtio$i"} = 1;
    $confdesc->{"virtio$i"} = $virtiodesc;
}

$drivename_hash->{efidisk0} = 1;
$confdesc->{efidisk0} = $efidisk_desc;

for (my $i = 0; $i < $MAX_USB_DEVICES; $i++)  {
    $confdesc->{"usb$i"} = $usbdesc;
}

my $unuseddesc = {
    optional => 1,
    type => 'string', format => 'pve-volume-id',
    description => "Reference to unused volumes. This is used internally, and should not be modified manually.",
};

for (my $i = 0; $i < $MAX_UNUSED_DISKS; $i++)  {
    $confdesc->{"unused$i"} = $unuseddesc;
}

my $kvm_api_version = 0;

sub kvm_version {
    return $kvm_api_version if $kvm_api_version;

    open my $fh, '<', '/dev/kvm'
	or return undef;

    # 0xae00 => KVM_GET_API_VERSION
    $kvm_api_version = ioctl($fh, 0xae00, 0);

    return $kvm_api_version;
}

my $kvm_user_version = {};
my $kvm_mtime = {};

sub kvm_user_version {
    my ($binary) = @_;

    $binary //= get_command_for_arch(get_host_arch()); # get the native arch by default
    my $st = stat($binary);

    my $cachedmtime = $kvm_mtime->{$binary} // -1;
    return $kvm_user_version->{$binary} if $kvm_user_version->{$binary} &&
	$cachedmtime == $st->mtime;

    $kvm_user_version->{$binary} = 'unknown';
    $kvm_mtime->{$binary} = $st->mtime;

    my $code = sub {
	my $line = shift;
	if ($line =~ m/^QEMU( PC)? emulator version (\d+\.\d+(\.\d+)?)(\.\d+)?[,\s]/) {
	    $kvm_user_version->{$binary} = $2;
	}
    };

    eval { run_command([$binary, '--version'], outfunc => $code); };
    warn $@ if $@;

    return $kvm_user_version->{$binary};

}

sub kernel_has_vhost_net {
    return -c '/dev/vhost-net';
}

sub valid_drive_names {
    # order is important - used to autoselect boot disk
    return ((map { "ide$_" } (0 .. ($MAX_IDE_DISKS - 1))),
            (map { "scsi$_" } (0 .. ($MAX_SCSI_DISKS - 1))),
            (map { "virtio$_" } (0 .. ($MAX_VIRTIO_DISKS - 1))),
            (map { "sata$_" } (0 .. ($MAX_SATA_DISKS - 1))),
            'efidisk0');
}

sub is_valid_drivename {
    my $dev = shift;

    return defined($drivename_hash->{$dev});
}

sub option_exists {
    my $key = shift;
    return defined($confdesc->{$key});
}

sub nic_models {
    return $nic_model_list;
}

sub os_list_description {

    return {
	other => 'Other',
	wxp => 'Windows XP',
	w2k => 'Windows 2000',
	w2k3 =>, 'Windows 2003',
	w2k8 => 'Windows 2008',
	wvista => 'Windows Vista',
	win7 => 'Windows 7',
	win8 => 'Windows 8/2012',
	win10 => 'Windows 10/2016',
	l24 => 'Linux 2.4',
	l26 => 'Linux 2.6',
    };
}

my $cdrom_path;

sub get_cdrom_path {

    return  $cdrom_path if $cdrom_path;

    return $cdrom_path = "/dev/cdrom" if -l "/dev/cdrom";
    return $cdrom_path = "/dev/cdrom1" if -l "/dev/cdrom1";
    return $cdrom_path = "/dev/cdrom2" if -l "/dev/cdrom2";
}

sub get_iso_path {
    my ($storecfg, $vmid, $cdrom) = @_;

    if ($cdrom eq 'cdrom') {
	return get_cdrom_path();
    } elsif ($cdrom eq 'none') {
	return '';
    } elsif ($cdrom =~ m|^/|) {
	return $cdrom;
    } else {
	return PVE::Storage::path($storecfg, $cdrom);
    }
}

# try to convert old style file names to volume IDs
sub filename_to_volume_id {
    my ($vmid, $file, $media) = @_;

     if (!($file eq 'none' || $file eq 'cdrom' ||
	  $file =~ m|^/dev/.+| || $file =~ m/^([^:]+):(.+)$/)) {

	return undef if $file =~ m|/|;

	if ($media && $media eq 'cdrom') {
	    $file = "local:iso/$file";
	} else {
	    $file = "local:$vmid/$file";
	}
    }

    return $file;
}

sub verify_media_type {
    my ($opt, $vtype, $media) = @_;

    return if !$media;

    my $etype;
    if ($media eq 'disk') {
	$etype = 'images';
    } elsif ($media eq 'cdrom') {
	$etype = 'iso';
    } else {
	die "internal error";
    }

    return if ($vtype eq $etype);

    raise_param_exc({ $opt => "unexpected media type ($vtype != $etype)" });
}

sub cleanup_drive_path {
    my ($opt, $storecfg, $drive) = @_;

    # try to convert filesystem paths to volume IDs

    if (($drive->{file} !~ m/^(cdrom|none)$/) &&
	($drive->{file} !~ m|^/dev/.+|) &&
	($drive->{file} !~ m/^([^:]+):(.+)$/) &&
	($drive->{file} !~ m/^\d+$/)) {
	my ($vtype, $volid) = PVE::Storage::path_to_volume_id($storecfg, $drive->{file});
	raise_param_exc({ $opt => "unable to associate path '$drive->{file}' to any storage"}) if !$vtype;
	$drive->{media} = 'cdrom' if !$drive->{media} && $vtype eq 'iso';
	verify_media_type($opt, $vtype, $drive->{media});
	$drive->{file} = $volid;
    }

    $drive->{media} = 'cdrom' if !$drive->{media} && $drive->{file} =~ m/^(cdrom|none)$/;
}

sub parse_hotplug_features {
    my ($data) = @_;

    my $res = {};

    return $res if $data eq '0';

    $data = $confdesc->{hotplug}->{default} if $data eq '1';

    foreach my $feature (PVE::Tools::split_list($data)) {
	if ($feature =~ m/^(network|disk|cpu|memory|usb)$/) {
	    $res->{$1} = 1;
	} else {
	    die "invalid hotplug feature '$feature'\n";
	}
    }
    return $res;
}

PVE::JSONSchema::register_format('pve-hotplug-features', \&pve_verify_hotplug_features);
sub pve_verify_hotplug_features {
    my ($value, $noerr) = @_;

    return $value if parse_hotplug_features($value);

    return undef if $noerr;

    die "unable to parse hotplug option\n";
}

# ideX = [volume=]volume-id[,media=d][,cyls=c,heads=h,secs=s[,trans=t]]
#        [,snapshot=on|off][,cache=on|off][,format=f][,backup=yes|no]
#        [,rerror=ignore|report|stop][,werror=enospc|ignore|report|stop]
#        [,aio=native|threads][,discard=ignore|on][,detect_zeroes=on|off]
#        [,iothread=on][,serial=serial][,model=model]

sub parse_drive {
    my ($key, $data) = @_;

    my ($interface, $index);

    if ($key =~ m/^([^\d]+)(\d+)$/) {
	$interface = $1;
	$index = $2;
    } else {
	return undef;
    }

    my $desc = $key =~ /^unused\d+$/ ? $alldrive_fmt
                                     : $confdesc->{$key}->{format};
    if (!$desc) {
	warn "invalid drive key: $key\n";
	return undef;
    }
    my $res = eval { PVE::JSONSchema::parse_property_string($desc, $data) };
    return undef if !$res;
    $res->{interface} = $interface;
    $res->{index} = $index;

    my $error = 0;
    foreach my $opt (qw(bps bps_rd bps_wr)) {
	if (my $bps = defined(delete $res->{$opt})) {
	    if (defined($res->{"m$opt"})) {
		warn "both $opt and m$opt specified\n";
		++$error;
		next;
	    }
	    $res->{"m$opt"} = sprintf("%.3f", $bps / (1024*1024.0));
	}
    }

    # can't use the schema's 'requires' because of the mbps* => bps* "transforming aliases"
    for my $requirement (
	[mbps_max => 'mbps'],
	[mbps_rd_max => 'mbps_rd'],
	[mbps_wr_max => 'mbps_wr'],
	[miops_max => 'miops'],
	[miops_rd_max => 'miops_rd'],
	[miops_wr_max => 'miops_wr'],
	[bps_max_length => 'mbps_max'],
	[bps_rd_max_length => 'mbps_rd_max'],
	[bps_wr_max_length => 'mbps_wr_max'],
	[iops_max_length => 'iops_max'],
	[iops_rd_max_length => 'iops_rd_max'],
	[iops_wr_max_length => 'iops_wr_max']) {
	my ($option, $requires) = @$requirement;
	if ($res->{$option} && !$res->{$requires}) {
	    warn "$option requires $requires\n";
	    ++$error;
	}
    }

    return undef if $error;

    return undef if $res->{mbps_rd} && $res->{mbps};
    return undef if $res->{mbps_wr} && $res->{mbps};
    return undef if $res->{iops_rd} && $res->{iops};
    return undef if $res->{iops_wr} && $res->{iops};

    if ($res->{media} && ($res->{media} eq 'cdrom')) {
	return undef if $res->{snapshot} || $res->{trans} || $res->{format};
	return undef if $res->{heads} || $res->{secs} || $res->{cyls};
	return undef if $res->{interface} eq 'virtio';
    }

    if (my $size = $res->{size}) {
	return undef if !defined($res->{size} = PVE::JSONSchema::parse_size($size));
    }

    return $res;
}

sub print_drive {
    my ($vmid, $drive) = @_;
    my $data = { %$drive };
    delete $data->{$_} for qw(index interface);
    return PVE::JSONSchema::print_property_string($data, $alldrive_fmt);
}

sub scsi_inquiry {
    my($fh, $noerr) = @_;

    my $SG_IO = 0x2285;
    my $SG_GET_VERSION_NUM = 0x2282;

    my $versionbuf = "\x00" x 8;
    my $ret = ioctl($fh, $SG_GET_VERSION_NUM, $versionbuf);
    if (!$ret) {
	die "scsi ioctl SG_GET_VERSION_NUM failoed - $!\n" if !$noerr;
	return undef;
    }
    my $version = unpack("I", $versionbuf);
    if ($version < 30000) {
	die "scsi generic interface too old\n"  if !$noerr;
	return undef;
    }

    my $buf = "\x00" x 36;
    my $sensebuf = "\x00" x 8;
    my $cmd = pack("C x3 C x1", 0x12, 36);

    # see /usr/include/scsi/sg.h
    my $sg_io_hdr_t = "i i C C s I P P P I I i P C C C C S S i I I";

    my $packet = pack($sg_io_hdr_t, ord('S'), -3, length($cmd),
		      length($sensebuf), 0, length($buf), $buf,
		      $cmd, $sensebuf, 6000);

    $ret = ioctl($fh, $SG_IO, $packet);
    if (!$ret) {
	die "scsi ioctl SG_IO failed - $!\n" if !$noerr;
	return undef;
    }

    my @res = unpack($sg_io_hdr_t, $packet);
    if ($res[17] || $res[18]) {
	die "scsi ioctl SG_IO status error - $!\n" if !$noerr;
	return undef;
    }

    my $res = {};
    (my $byte0, my $byte1, $res->{vendor},
     $res->{product}, $res->{revision}) = unpack("C C x6 A8 A16 A4", $buf);

    $res->{removable} = $byte1 & 128 ? 1 : 0;
    $res->{type} = $byte0 & 31;

    return $res;
}

sub path_is_scsi {
    my ($path) = @_;

    my $fh = IO::File->new("+<$path") || return undef;
    my $res = scsi_inquiry($fh, 1);
    close($fh);

    return $res;
}

sub machine_type_is_q35 {
    my ($conf) = @_;

    return $conf->{machine} && ($conf->{machine} =~ m/q35/) ? 1 : 0;
}

sub print_tabletdevice_full {
    my ($conf, $arch) = @_;

    my $q35 = machine_type_is_q35($conf);

    # we use uhci for old VMs because tablet driver was buggy in older qemu
    my $usbbus;
    if (machine_type_is_q35($conf) || $arch eq 'aarch64') {
	$usbbus = 'ehci';
    } else {
	$usbbus = 'uhci';
    }

    return "usb-tablet,id=tablet,bus=$usbbus.0,port=1";
}

sub print_keyboarddevice_full {
    my ($conf, $arch, $machine) = @_;

    return undef if $arch ne 'aarch64';

    return "usb-kbd,id=keyboard,bus=ehci.0,port=2";
}

sub print_drivedevice_full {
    my ($storecfg, $conf, $vmid, $drive, $bridges, $arch, $machine_type) = @_;

    my $device = '';
    my $maxdev = 0;

    if ($drive->{interface} eq 'virtio') {
	my $pciaddr = print_pci_addr("$drive->{interface}$drive->{index}", $bridges, $arch, $machine_type);
	$device = "virtio-blk-pci,drive=drive-$drive->{interface}$drive->{index},id=$drive->{interface}$drive->{index}$pciaddr";
	$device .= ",iothread=iothread-$drive->{interface}$drive->{index}" if $drive->{iothread};
    } elsif ($drive->{interface} eq 'scsi') {

	my ($maxdev, $controller, $controller_prefix) = scsihw_infos($conf, $drive);
	my $unit = $drive->{index} % $maxdev;
	my $devicetype = 'hd';
	my $path = '';
	if (drive_is_cdrom($drive)) {
	    $devicetype = 'cd';
	} else {
	    if ($drive->{file} =~ m|^/|) {
		$path = $drive->{file};
		if (my $info = path_is_scsi($path)) {
		    if ($info->{type} == 0 && $drive->{scsiblock}) {
			$devicetype = 'block';
		    } elsif ($info->{type} == 1) { # tape
			$devicetype = 'generic';
		    }
		}
	    } else {
		 $path = PVE::Storage::path($storecfg, $drive->{file});
	    }

	    if($path =~ m/^iscsi\:\/\//){
		$devicetype = 'generic';
	    }
	}

	if (!$conf->{scsihw} || ($conf->{scsihw} =~ m/^lsi/)){
	    $device = "scsi-$devicetype,bus=$controller_prefix$controller.0,scsi-id=$unit,drive=drive-$drive->{interface}$drive->{index},id=$drive->{interface}$drive->{index}";
	} else {
	    $device = "scsi-$devicetype,bus=$controller_prefix$controller.0,channel=0,scsi-id=0,lun=$drive->{index},drive=drive-$drive->{interface}$drive->{index},id=$drive->{interface}$drive->{index}";
	}

	if ($drive->{ssd} && ($devicetype eq 'block' || $devicetype eq 'hd')) {
	    $device .= ",rotation_rate=1";
	}
	$device .= ",wwn=$drive->{wwn}" if $drive->{wwn};

    } elsif ($drive->{interface} eq 'ide' || $drive->{interface} eq 'sata') {
	my $maxdev = ($drive->{interface} eq 'sata') ? $MAX_SATA_DISKS : 2;
	my $controller = int($drive->{index} / $maxdev);
	my $unit = $drive->{index} % $maxdev;
	my $devicetype = ($drive->{media} && $drive->{media} eq 'cdrom') ? "cd" : "hd";

	$device = "ide-$devicetype";
	if ($drive->{interface} eq 'ide') {
	    $device .= ",bus=ide.$controller,unit=$unit";
	} else {
	    $device .= ",bus=ahci$controller.$unit";
	}
	$device .= ",drive=drive-$drive->{interface}$drive->{index},id=$drive->{interface}$drive->{index}";

	if ($devicetype eq 'hd') {
	    if (my $model = $drive->{model}) {
		$model = URI::Escape::uri_unescape($model);
		$device .= ",model=$model";
	    }
	    if ($drive->{ssd}) {
		$device .= ",rotation_rate=1";
	    }
	}
	$device .= ",wwn=$drive->{wwn}" if $drive->{wwn};
    } elsif ($drive->{interface} eq 'usb') {
	die "implement me";
	#  -device ide-drive,bus=ide.1,unit=0,drive=drive-ide0-1-0,id=ide0-1-0
    } else {
	die "unsupported interface type";
    }

    $device .= ",bootindex=$drive->{bootindex}" if $drive->{bootindex};

    if (my $serial = $drive->{serial}) {
	$serial = URI::Escape::uri_unescape($serial);
	$device .= ",serial=$serial";
    }


    return $device;
}

sub get_initiator_name {
    my $initiator;

    my $fh = IO::File->new('/etc/iscsi/initiatorname.iscsi') || return undef;
    while (defined(my $line = <$fh>)) {
	next if $line !~ m/^\s*InitiatorName\s*=\s*([\.\-:\w]+)/;
	$initiator = $1;
	last;
    }
    $fh->close();

    return $initiator;
}

sub print_drive_full {
    my ($storecfg, $vmid, $drive) = @_;

    my $path;
    my $volid = $drive->{file};
    my $format;

    if (drive_is_cdrom($drive)) {
	$path = get_iso_path($storecfg, $vmid, $volid);
    } else {
	my ($storeid, $volname) = PVE::Storage::parse_volume_id($volid, 1);
	if ($storeid) {
	    $path = PVE::Storage::path($storecfg, $volid);
	    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
	    $format = qemu_img_format($scfg, $volname);
	} else {
	    $path = $volid;
	    $format = "raw";
	}
   }

    my $opts = '';
    my @qemu_drive_options = qw(heads secs cyls trans media format cache rerror werror aio discard);
    foreach my $o (@qemu_drive_options) {
	$opts .= ",$o=$drive->{$o}" if defined($drive->{$o});
    }

    # snapshot only accepts on|off
    if (defined($drive->{snapshot})) {
	my $v = $drive->{snapshot} ? 'on' : 'off';
	$opts .= ",snapshot=$v";
    }

    foreach my $type (['', '-total'], [_rd => '-read'], [_wr => '-write']) {
	my ($dir, $qmpname) = @$type;
	if (my $v = $drive->{"mbps$dir"}) {
	    $opts .= ",throttling.bps$qmpname=".int($v*1024*1024);
	}
	if (my $v = $drive->{"mbps${dir}_max"}) {
	    $opts .= ",throttling.bps$qmpname-max=".int($v*1024*1024);
	}
	if (my $v = $drive->{"bps${dir}_max_length"}) {
	    $opts .= ",throttling.bps$qmpname-max-length=$v";
	}
	if (my $v = $drive->{"iops${dir}"}) {
	    $opts .= ",throttling.iops$qmpname=$v";
	}
	if (my $v = $drive->{"iops${dir}_max"}) {
	    $opts .= ",throttling.iops$qmpname-max=$v";
	}
	if (my $v = $drive->{"iops${dir}_max_length"}) {
	    $opts .= ",throttling.iops$qmpname-max-length=$v";
	}
    }

    $opts .= ",format=$format" if $format && !$drive->{format};

    my $cache_direct = 0;

    if (my $cache = $drive->{cache}) {
	$cache_direct = $cache =~ /^(?:off|none|directsync)$/;
    } elsif (!drive_is_cdrom($drive)) {
	$opts .= ",cache=none";
	$cache_direct = 1;
    }

    # aio native works only with O_DIRECT
    if (!$drive->{aio}) {
	if($cache_direct) {
	    $opts .= ",aio=native";
	} else {
	    $opts .= ",aio=threads";
	}
    }

    if (!drive_is_cdrom($drive)) {
	my $detectzeroes;
	if (defined($drive->{detect_zeroes}) && !$drive->{detect_zeroes}) {
	    $detectzeroes = 'off';
	} elsif ($drive->{discard}) {
	    $detectzeroes = $drive->{discard} eq 'on' ? 'unmap' : 'on';
	} else {
	    # This used to be our default with discard not being specified:
	    $detectzeroes = 'on';
	}
	$opts .= ",detect-zeroes=$detectzeroes" if $detectzeroes;
    }

    my $pathinfo = $path ? "file=$path," : '';

    return "${pathinfo}if=none,id=drive-$drive->{interface}$drive->{index}$opts";
}

sub print_netdevice_full {
    my ($vmid, $conf, $net, $netid, $bridges, $use_old_bios_files, $arch, $machine_type) = @_;

    my $bootorder = $conf->{boot} || $confdesc->{boot}->{default};

    my $device = $net->{model};
    if ($net->{model} eq 'virtio') {
         $device = 'virtio-net-pci';
     };

    my $pciaddr = print_pci_addr("$netid", $bridges, $arch, $machine_type);
    my $tmpstr = "$device,mac=$net->{macaddr},netdev=$netid$pciaddr,id=$netid";
    if ($net->{queues} && $net->{queues} > 1 && $net->{model} eq 'virtio'){
	#Consider we have N queues, the number of vectors needed is 2*N + 2 (plus one config interrupt and control vq)
	my $vectors = $net->{queues} * 2 + 2;
	$tmpstr .= ",vectors=$vectors,mq=on";
    }
    $tmpstr .= ",bootindex=$net->{bootindex}" if $net->{bootindex} ;

    if ($use_old_bios_files) {
	my $romfile;
	if ($device eq 'virtio-net-pci') {
	    $romfile = 'pxe-virtio.rom';
	} elsif ($device eq 'e1000') {
	    $romfile = 'pxe-e1000.rom';
	} elsif ($device eq 'ne2k') {
	    $romfile = 'pxe-ne2k_pci.rom';
	} elsif ($device eq 'pcnet') {
	    $romfile = 'pxe-pcnet.rom';
	} elsif ($device eq 'rtl8139') {
	    $romfile = 'pxe-rtl8139.rom';
	}
	$tmpstr .= ",romfile=$romfile" if $romfile;
    }

    return $tmpstr;
}

sub print_netdev_full {
    my ($vmid, $conf, $arch, $net, $netid, $hotplug) = @_;

    my $i = '';
    if ($netid =~ m/^net(\d+)$/) {
        $i = int($1);
    }

    die "got strange net id '$i'\n" if $i >= ${MAX_NETS};

    my $ifname = "tap${vmid}i$i";

    # kvm uses TUNSETIFF ioctl, and that limits ifname length
    die "interface name '$ifname' is too long (max 15 character)\n"
        if length($ifname) >= 16;

    my $vhostparam = '';
    if (is_native($arch)) {
	$vhostparam = ',vhost=on' if kernel_has_vhost_net() && $net->{model} eq 'virtio';
    }

    my $vmname = $conf->{name} || "vm$vmid";

    my $netdev = "";
    my $script = $hotplug ? "pve-bridge-hotplug" : "pve-bridge";

    if ($net->{bridge}) {
        $netdev = "type=tap,id=$netid,ifname=${ifname},script=/var/lib/qemu-server/$script,downscript=/var/lib/qemu-server/pve-bridgedown$vhostparam";
    } else {
        $netdev = "type=user,id=$netid,hostname=$vmname";
    }

    $netdev .= ",queues=$net->{queues}" if ($net->{queues} && $net->{model} eq 'virtio');

    return $netdev;
}


sub print_cpu_device {
    my ($conf, $id) = @_;

    my $kvm = $conf->{kvm} // 1;
    my $cpu = $kvm ? "kvm64" : "qemu64";
    if (my $cputype = $conf->{cpu}) {
	my $cpuconf = PVE::JSONSchema::parse_property_string($cpu_fmt, $cputype)
	    or die "Cannot parse cpu description: $cputype\n";
	$cpu = $cpuconf->{cputype};
    }

    my $cores = $conf->{cores} || 1;

    my $current_core = ($id - 1) % $cores;
    my $current_socket = int(($id - 1 - $current_core)/$cores);

    return "$cpu-x86_64-cpu,id=cpu$id,socket-id=$current_socket,core-id=$current_core,thread-id=0";
}

my $vga_map = {
    'cirrus' => 'cirrus-vga',
    'std' => 'VGA',
    'vmware' => 'vmware-svga',
    'virtio' => 'virtio-vga',
};

sub print_vga_device {
    my ($conf, $vga, $arch, $machine, $id, $qxlnum, $bridges) = @_;

    my $type = $vga_map->{$vga->{type}};
    if ($arch eq 'aarch64' && defined($type) && $type eq 'virtio-vga') {
	$type = 'virtio-gpu';
    }
    my $vgamem_mb = $vga->{memory};
    if ($qxlnum) {
	$type = $id ? 'qxl' : 'qxl-vga';
    }
    die "no devicetype for $vga->{type}\n" if !$type;

    my $memory = "";
    if ($vgamem_mb) {
	if ($vga->{type} eq 'virtio') {
	    my $bytes = PVE::Tools::convert_size($vgamem_mb, "mb" => "b");
	    $memory = ",max_hostmem=$bytes";
	} elsif ($qxlnum) {
	    # from https://www.spice-space.org/multiple-monitors.html
	    $memory = ",vgamem_mb=$vga->{memory}";
	    my $ram = $vgamem_mb * 4;
	    my $vram = $vgamem_mb * 2;
	    $memory .= ",ram_size_mb=$ram,vram_size_mb=$vram";
	} else {
	    $memory = ",vgamem_mb=$vga->{memory}";
	}
    } elsif ($qxlnum && $id) {
	$memory = ",ram_size=67108864,vram_size=33554432";
    }

    my $q35 = machine_type_is_q35($conf);
    my $vgaid = "vga" . ($id // '');
    my $pciaddr;

    if ($q35 && $vgaid eq 'vga') {
	# the first display uses pcie.0 bus on q35 machines
	$pciaddr = print_pcie_addr($vgaid, $bridges, $arch, $machine);
    } else {
	$pciaddr = print_pci_addr($vgaid, $bridges, $arch, $machine);
    }

    return "$type,id=${vgaid}${memory}${pciaddr}";
}

sub drive_is_cloudinit {
    my ($drive) = @_;
    return $drive->{file} =~ m@[:/]vm-\d+-cloudinit(?:\.$QEMU_FORMAT_RE)?$@;
}

sub drive_is_cdrom {
    my ($drive, $exclude_cloudinit) = @_;

    return 0 if $exclude_cloudinit && drive_is_cloudinit($drive);

    return $drive && $drive->{media} && ($drive->{media} eq 'cdrom');

}

sub parse_number_sets {
    my ($set) = @_;
    my $res = [];
    foreach my $part (split(/;/, $set)) {
	if ($part =~ /^\s*(\d+)(?:-(\d+))?\s*$/) {
	    die "invalid range: $part ($2 < $1)\n" if defined($2) && $2 < $1;
	    push @$res, [ $1, $2 ];
	} else {
	    die "invalid range: $part\n";
	}
    }
    return $res;
}

sub parse_numa {
    my ($data) = @_;

    my $res = PVE::JSONSchema::parse_property_string($numa_fmt, $data);
    $res->{cpus} = parse_number_sets($res->{cpus}) if defined($res->{cpus});
    $res->{hostnodes} = parse_number_sets($res->{hostnodes}) if defined($res->{hostnodes});
    return $res;
}

sub parse_hostpci {
    my ($value) = @_;

    return undef if !$value;

    my $res = PVE::JSONSchema::parse_property_string($hostpci_fmt, $value);

    my @idlist = split(/;/, $res->{host});
    delete $res->{host};
    foreach my $id (@idlist) {
	if ($id =~ m/\./) { # full id 00:00.1
	    push @{$res->{pciid}}, {
		id => $id,
	    };
	} else { # partial id 00:00
	    $res->{pciid} = PVE::SysFSTools::lspci($id);
	}
    }
    return $res;
}

# netX: e1000=XX:XX:XX:XX:XX:XX,bridge=vmbr0,rate=<mbps>
sub parse_net {
    my ($data) = @_;

    my $res = eval { PVE::JSONSchema::parse_property_string($net_fmt, $data) };
    if ($@) {
	warn $@;
	return undef;
    }
    if (!defined($res->{macaddr})) {
	my $dc = PVE::Cluster::cfs_read_file('datacenter.cfg');
	$res->{macaddr} = PVE::Tools::random_ether_addr($dc->{mac_prefix});
    }
    return $res;
}

# ipconfigX ip=cidr,gw=ip,ip6=cidr,gw6=ip
sub parse_ipconfig {
    my ($data) = @_;

    my $res = eval { PVE::JSONSchema::parse_property_string($ipconfig_fmt, $data) };
    if ($@) {
	warn $@;
	return undef;
    }

    if ($res->{gw} && !$res->{ip}) {
	warn 'gateway specified without specifying an IP address';
	return undef;
    }
    if ($res->{gw6} && !$res->{ip6}) {
	warn 'IPv6 gateway specified without specifying an IPv6 address';
	return undef;
    }
    if ($res->{gw} && $res->{ip} eq 'dhcp') {
	warn 'gateway specified together with DHCP';
	return undef;
    }
    if ($res->{gw6} && $res->{ip6} !~ /^$IPV6RE/) {
	# gw6 + auto/dhcp
	warn "IPv6 gateway specified together with $res->{ip6} address";
	return undef;
    }

    if (!$res->{ip} && !$res->{ip6}) {
	return { ip => 'dhcp', ip6 => 'dhcp' };
    }

    return $res;
}

sub print_net {
    my $net = shift;

    return PVE::JSONSchema::print_property_string($net, $net_fmt);
}

sub add_random_macs {
    my ($settings) = @_;

    foreach my $opt (keys %$settings) {
	next if $opt !~ m/^net(\d+)$/;
	my $net = parse_net($settings->{$opt});
	next if !$net;
	$settings->{$opt} = print_net($net);
    }
}

sub vm_is_volid_owner {
    my ($storecfg, $vmid, $volid) = @_;

    if ($volid !~  m|^/|) {
	my ($path, $owner);
	eval { ($path, $owner) = PVE::Storage::path($storecfg, $volid); };
	if ($owner && ($owner == $vmid)) {
	    return 1;
	}
    }

    return undef;
}

sub split_flagged_list {
    my $text = shift || '';
    $text =~ s/[,;]/ /g;
    $text =~ s/^\s+//;
    return { map { /^(!?)(.*)$/ && ($2, $1) } ($text =~ /\S+/g) };
}

sub join_flagged_list {
    my ($how, $lst) = @_;
    join $how, map { $lst->{$_} . $_ } keys %$lst;
}

sub vmconfig_delete_pending_option {
    my ($conf, $key, $force) = @_;

    delete $conf->{pending}->{$key};
    my $pending_delete_hash = split_flagged_list($conf->{pending}->{delete});
    $pending_delete_hash->{$key} = $force ? '!' : '';
    $conf->{pending}->{delete} = join_flagged_list(',', $pending_delete_hash);
}

sub vmconfig_undelete_pending_option {
    my ($conf, $key) = @_;

    my $pending_delete_hash = split_flagged_list($conf->{pending}->{delete});
    delete $pending_delete_hash->{$key};

    if (%$pending_delete_hash) {
	$conf->{pending}->{delete} = join_flagged_list(',', $pending_delete_hash);
    } else {
	delete $conf->{pending}->{delete};
    }
}

sub vmconfig_register_unused_drive {
    my ($storecfg, $vmid, $conf, $drive) = @_;

    if (drive_is_cloudinit($drive)) {
	eval { PVE::Storage::vdisk_free($storecfg, $drive->{file}) };
	warn $@ if $@;
    } elsif (!drive_is_cdrom($drive)) {
	my $volid = $drive->{file};
	if (vm_is_volid_owner($storecfg, $vmid, $volid)) {
	    PVE::QemuConfig->add_unused_volume($conf, $volid, $vmid);
	}
    }
}

sub vmconfig_cleanup_pending {
    my ($conf) = @_;

    # remove pending changes when nothing changed
    my $changes;
    foreach my $opt (keys %{$conf->{pending}}) {
	if (defined($conf->{$opt}) && ($conf->{pending}->{$opt} eq  $conf->{$opt})) {
	    $changes = 1;
	    delete $conf->{pending}->{$opt};
	}
    }

    my $current_delete_hash = split_flagged_list($conf->{pending}->{delete});
    my $pending_delete_hash = {};
    while (my ($opt, $force) = each %$current_delete_hash) {
	if (defined($conf->{$opt})) {
	    $pending_delete_hash->{$opt} = $force;
	} else {
	    $changes = 1;
	}
    }

    if (%$pending_delete_hash) {
	$conf->{pending}->{delete} = join_flagged_list(',', $pending_delete_hash);
    } else {
	delete $conf->{pending}->{delete};
    }

    return $changes;
}

# smbios: [manufacturer=str][,product=str][,version=str][,serial=str][,uuid=uuid][,sku=str][,family=str][,base64=bool]
my $smbios1_fmt = {
    uuid => {
	type => 'string',
	pattern => '[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}',
	format_description => 'UUID',
        description => "Set SMBIOS1 UUID.",
	optional => 1,
    },
    version => {
	type => 'string',
	pattern => '[A-Za-z0-9+\/]+={0,2}',
	format_description => 'Base64 encoded string',
        description => "Set SMBIOS1 version.",
	optional => 1,
    },
    serial => {
	type => 'string',
	pattern => '[A-Za-z0-9+\/]+={0,2}',
	format_description => 'Base64 encoded string',
        description => "Set SMBIOS1 serial number.",
	optional => 1,
    },
    manufacturer => {
	type => 'string',
	pattern => '[A-Za-z0-9+\/]+={0,2}',
	format_description => 'Base64 encoded string',
        description => "Set SMBIOS1 manufacturer.",
	optional => 1,
    },
    product => {
	type => 'string',
	pattern => '[A-Za-z0-9+\/]+={0,2}',
	format_description => 'Base64 encoded string',
        description => "Set SMBIOS1 product ID.",
	optional => 1,
    },
    sku => {
	type => 'string',
	pattern => '[A-Za-z0-9+\/]+={0,2}',
	format_description => 'Base64 encoded string',
        description => "Set SMBIOS1 SKU string.",
	optional => 1,
    },
    family => {
	type => 'string',
	pattern => '[A-Za-z0-9+\/]+={0,2}',
	format_description => 'Base64 encoded string',
        description => "Set SMBIOS1 family string.",
	optional => 1,
    },
    base64 => {
	type => 'boolean',
	description => 'Flag to indicate that the SMBIOS values are base64 encoded',
	optional => 1,
    },
};

sub parse_smbios1 {
    my ($data) = @_;

    my $res = eval { PVE::JSONSchema::parse_property_string($smbios1_fmt, $data) };
    warn $@ if $@;
    return $res;
}

sub print_smbios1 {
    my ($smbios1) = @_;
    return PVE::JSONSchema::print_property_string($smbios1, $smbios1_fmt);
}

PVE::JSONSchema::register_format('pve-qm-smbios1', $smbios1_fmt);

PVE::JSONSchema::register_format('pve-qm-bootdisk', \&verify_bootdisk);
sub verify_bootdisk {
    my ($value, $noerr) = @_;

    return $value if is_valid_drivename($value);

    return undef if $noerr;

    die "invalid boot disk '$value'\n";
}

sub parse_watchdog {
    my ($value) = @_;

    return undef if !$value;

    my $res = eval { PVE::JSONSchema::parse_property_string($watchdog_fmt, $value) };
    warn $@ if $@;
    return $res;
}

sub parse_guest_agent {
    my ($value) = @_;

    return {} if !defined($value->{agent});

    my $res = eval { PVE::JSONSchema::parse_property_string($agent_fmt, $value->{agent}) };
    warn $@ if $@;

    # if the agent is disabled ignore the other potentially set properties
    return {} if !$res->{enabled};
    return $res;
}

sub parse_vga {
    my ($value) = @_;

    return {} if !$value;
    my $res = eval { PVE::JSONSchema::parse_property_string($vga_fmt, $value) };
    warn $@ if $@;
    return $res;
}

PVE::JSONSchema::register_format('pve-qm-usb-device', \&verify_usb_device);
sub verify_usb_device {
    my ($value, $noerr) = @_;

    return $value if parse_usb_device($value);

    return undef if $noerr;

    die "unable to parse usb device\n";
}

# add JSON properties for create and set function
sub json_config_properties {
    my $prop = shift;

    foreach my $opt (keys %$confdesc) {
	next if $opt eq 'parent' || $opt eq 'snaptime' || $opt eq 'vmstate' || $opt eq 'runningmachine';
	$prop->{$opt} = $confdesc->{$opt};
    }

    return $prop;
}

# return copy of $confdesc_cloudinit to generate documentation
sub cloudinit_config_properties {

    return dclone($confdesc_cloudinit);
}

sub check_type {
    my ($key, $value) = @_;

    die "unknown setting '$key'\n" if !$confdesc->{$key};

    my $type = $confdesc->{$key}->{type};

    if (!defined($value)) {
	die "got undefined value\n";
    }

    if ($value =~ m/[\n\r]/) {
	die "property contains a line feed\n";
    }

    if ($type eq 'boolean') {
	return 1 if ($value eq '1') || ($value =~ m/^(on|yes|true)$/i);
	return 0 if ($value eq '0') || ($value =~ m/^(off|no|false)$/i);
	die "type check ('boolean') failed - got '$value'\n";
    } elsif ($type eq 'integer') {
	return int($1) if $value =~ m/^(\d+)$/;
	die "type check ('integer') failed - got '$value'\n";
    } elsif ($type eq 'number') {
        return $value if $value =~ m/^(\d+)(\.\d+)?$/;
        die "type check ('number') failed - got '$value'\n";
    } elsif ($type eq 'string') {
	if (my $fmt = $confdesc->{$key}->{format}) {
	    PVE::JSONSchema::check_format($fmt, $value);
	    return $value;
	}
	$value =~ s/^\"(.*)\"$/$1/;
	return $value;
    } else {
	die "internal error"
    }
}

sub touch_config {
    my ($vmid) = @_;

    my $conf = PVE::QemuConfig->config_file($vmid);
    utime undef, undef, $conf;
}

sub destroy_vm {
    my ($storecfg, $vmid, $keep_empty_config, $skiplock) = @_;

    my $conffile = PVE::QemuConfig->config_file($vmid);

    my $conf = PVE::QemuConfig->load_config($vmid);

    PVE::QemuConfig->check_lock($conf) if !$skiplock;

    if ($conf->{template}) {
	# check if any base image is still used by a linked clone
	foreach_drive($conf, sub {
		my ($ds, $drive) = @_;

		return if drive_is_cdrom($drive);

		my $volid = $drive->{file};

		return if !$volid || $volid =~ m|^/|;

		die "base volume '$volid' is still in use by linked cloned\n"
		    if PVE::Storage::volume_is_base_and_used($storecfg, $volid);

	});
    }

    # only remove disks owned by this VM
    foreach_drive($conf, sub {
	my ($ds, $drive) = @_;

 	return if drive_is_cdrom($drive, 1);

	my $volid = $drive->{file};

	return if !$volid || $volid =~ m|^/|;

	my ($path, $owner) = PVE::Storage::path($storecfg, $volid);
	return if !$path || !$owner || ($owner != $vmid);

	eval {
	    PVE::Storage::vdisk_free($storecfg, $volid);
	};
	warn "Could not remove disk '$volid', check manually: $@" if $@;

    });

    if ($keep_empty_config) {
	PVE::Tools::file_set_contents($conffile, "memory: 128\n");
    } else {
	unlink $conffile;
    }

    # also remove unused disk
    eval {
	my $dl = PVE::Storage::vdisk_list($storecfg, undef, $vmid);

	eval {
	    PVE::Storage::foreach_volid($dl, sub {
		my ($volid, $sid, $volname, $d) = @_;
		PVE::Storage::vdisk_free($storecfg, $volid);
	    });
	};
	warn $@ if $@;

    };
    warn $@ if $@;
}

sub parse_vm_config {
    my ($filename, $raw) = @_;

    return undef if !defined($raw);

    my $res = {
	digest => Digest::SHA::sha1_hex($raw),
	snapshots => {},
	pending => {},
    };

    $filename =~ m|/qemu-server/(\d+)\.conf$|
	|| die "got strange filename '$filename'";

    my $vmid = $1;

    my $conf = $res;
    my $descr;
    my $section = '';

    my @lines = split(/\n/, $raw);
    foreach my $line (@lines) {
	next if $line =~ m/^\s*$/;

	if ($line =~ m/^\[PENDING\]\s*$/i) {
	    $section = 'pending';
	    if (defined($descr)) {
		$descr =~ s/\s+$//;
		$conf->{description} = $descr;
	    }
	    $descr = undef;
	    $conf = $res->{$section} = {};
	    next;

	} elsif ($line =~ m/^\[([a-z][a-z0-9_\-]+)\]\s*$/i) {
	    $section = $1;
	    if (defined($descr)) {
		$descr =~ s/\s+$//;
		$conf->{description} = $descr;
	    }
	    $descr = undef;
	    $conf = $res->{snapshots}->{$section} = {};
	    next;
	}

	if ($line =~ m/^\#(.*)\s*$/) {
	    $descr = '' if !defined($descr);
	    $descr .= PVE::Tools::decode_text($1) . "\n";
	    next;
	}

	if ($line =~ m/^(description):\s*(.*\S)\s*$/) {
	    $descr = '' if !defined($descr);
	    $descr .= PVE::Tools::decode_text($2);
	} elsif ($line =~ m/snapstate:\s*(prepare|delete)\s*$/) {
	    $conf->{snapstate} = $1;
	} elsif ($line =~ m/^(args):\s*(.*\S)\s*$/) {
	    my $key = $1;
	    my $value = $2;
	    $conf->{$key} = $value;
	} elsif ($line =~ m/^delete:\s*(.*\S)\s*$/) {
	    my $value = $1;
	    if ($section eq 'pending') {
		$conf->{delete} = $value; # we parse this later
	    } else {
		warn "vm $vmid - propertry 'delete' is only allowed in [PENDING]\n";
	    }
	} elsif ($line =~ m/^([a-z][a-z_]*\d*):\s*(.+?)\s*$/) {
	    my $key = $1;
	    my $value = $2;
	    eval { $value = check_type($key, $value); };
	    if ($@) {
		warn "vm $vmid - unable to parse value of '$key' - $@";
	    } else {
		$key = 'ide2' if $key eq 'cdrom';
		my $fmt = $confdesc->{$key}->{format};
		if ($fmt && $fmt =~ /^pve-qm-(?:ide|scsi|virtio|sata)$/) {
		    my $v = parse_drive($key, $value);
		    if (my $volid = filename_to_volume_id($vmid, $v->{file}, $v->{media})) {
			$v->{file} = $volid;
			$value = print_drive($vmid, $v);
		    } else {
			warn "vm $vmid - unable to parse value of '$key'\n";
			next;
		    }
		}

		$conf->{$key} = $value;
	    }
	}
    }

    if (defined($descr)) {
	$descr =~ s/\s+$//;
	$conf->{description} = $descr;
    }
    delete $res->{snapstate}; # just to be sure

    return $res;
}

sub write_vm_config {
    my ($filename, $conf) = @_;

    delete $conf->{snapstate}; # just to be sure

    if ($conf->{cdrom}) {
	die "option ide2 conflicts with cdrom\n" if $conf->{ide2};
	$conf->{ide2} = $conf->{cdrom};
	delete $conf->{cdrom};
    }

    # we do not use 'smp' any longer
    if ($conf->{sockets}) {
	delete $conf->{smp};
    } elsif ($conf->{smp}) {
	$conf->{sockets} = $conf->{smp};
	delete $conf->{cores};
	delete $conf->{smp};
    }

    my $used_volids = {};

    my $cleanup_config = sub {
	my ($cref, $pending, $snapname) = @_;

	foreach my $key (keys %$cref) {
	    next if $key eq 'digest' || $key eq 'description' || $key eq 'snapshots' ||
		$key eq 'snapstate' || $key eq 'pending';
	    my $value = $cref->{$key};
	    if ($key eq 'delete') {
		die "propertry 'delete' is only allowed in [PENDING]\n"
		    if !$pending;
		# fixme: check syntax?
		next;
	    }
	    eval { $value = check_type($key, $value); };
	    die "unable to parse value of '$key' - $@" if $@;

	    $cref->{$key} = $value;

	    if (!$snapname && is_valid_drivename($key)) {
		my $drive = parse_drive($key, $value);
		$used_volids->{$drive->{file}} = 1 if $drive && $drive->{file};
	    }
	}
    };

    &$cleanup_config($conf);

    &$cleanup_config($conf->{pending}, 1);

    foreach my $snapname (keys %{$conf->{snapshots}}) {
	die "internal error" if $snapname eq 'pending';
	&$cleanup_config($conf->{snapshots}->{$snapname}, undef, $snapname);
    }

    # remove 'unusedX' settings if we re-add a volume
    foreach my $key (keys %$conf) {
	my $value = $conf->{$key};
	if ($key =~ m/^unused/ && $used_volids->{$value}) {
	    delete $conf->{$key};
	}
    }

    my $generate_raw_config = sub {
	my ($conf, $pending) = @_;

	my $raw = '';

	# add description as comment to top of file
	if (defined(my $descr = $conf->{description})) {
	    if ($descr) {
		foreach my $cl (split(/\n/, $descr)) {
		    $raw .= '#' .  PVE::Tools::encode_text($cl) . "\n";
		}
	    } else {
		$raw .= "#\n" if $pending;
	    }
	}

	foreach my $key (sort keys %$conf) {
	    next if $key eq 'digest' || $key eq 'description' || $key eq 'pending' || $key eq 'snapshots';
	    $raw .= "$key: $conf->{$key}\n";
	}
	return $raw;
    };

    my $raw = &$generate_raw_config($conf);

    if (scalar(keys %{$conf->{pending}})){
	$raw .= "\n[PENDING]\n";
	$raw .= &$generate_raw_config($conf->{pending}, 1);
    }

    foreach my $snapname (sort keys %{$conf->{snapshots}}) {
	$raw .= "\n[$snapname]\n";
	$raw .= &$generate_raw_config($conf->{snapshots}->{$snapname});
    }

    return $raw;
}

sub load_defaults {

    my $res = {};

    # we use static defaults from our JSON schema configuration
    foreach my $key (keys %$confdesc) {
	if (defined(my $default = $confdesc->{$key}->{default})) {
	    $res->{$key} = $default;
	}
    }

    return $res;
}

sub config_list {
    my $vmlist = PVE::Cluster::get_vmlist();
    my $res = {};
    return $res if !$vmlist || !$vmlist->{ids};
    my $ids = $vmlist->{ids};

    foreach my $vmid (keys %$ids) {
	my $d = $ids->{$vmid};
	next if !$d->{node} || $d->{node} ne $nodename;
	next if !$d->{type} || $d->{type} ne 'qemu';
	$res->{$vmid}->{exists} = 1;
    }
    return $res;
}

# test if VM uses local resources (to prevent migration)
sub check_local_resources {
    my ($conf, $noerr) = @_;

    my @loc_res = ();

    push @loc_res, "hostusb" if $conf->{hostusb}; # old syntax
    push @loc_res, "hostpci" if $conf->{hostpci}; # old syntax

    push @loc_res, "ivshmem" if $conf->{ivshmem};

    foreach my $k (keys %$conf) {
	next if $k =~ m/^usb/ && ($conf->{$k} eq 'spice');
	# sockets are safe: they will recreated be on the target side post-migrate
	next if $k =~ m/^serial/ && ($conf->{$k} eq 'socket');
	push @loc_res, $k if $k =~ m/^(usb|hostpci|serial|parallel)\d+$/;
    }

    die "VM uses local resources\n" if scalar @loc_res && !$noerr;

    return \@loc_res;
}

# check if used storages are available on all nodes (use by migrate)
sub check_storage_availability {
    my ($storecfg, $conf, $node) = @_;

    foreach_drive($conf, sub {
	my ($ds, $drive) = @_;

	my $volid = $drive->{file};
	return if !$volid;

	my ($sid, $volname) = PVE::Storage::parse_volume_id($volid, 1);
	return if !$sid;

	# check if storage is available on both nodes
	my $scfg = PVE::Storage::storage_check_node($storecfg, $sid);
	PVE::Storage::storage_check_node($storecfg, $sid, $node);
   });
}

# list nodes where all VM images are available (used by has_feature API)
sub shared_nodes {
    my ($conf, $storecfg) = @_;

    my $nodelist = PVE::Cluster::get_nodelist();
    my $nodehash = { map { $_ => 1 } @$nodelist };
    my $nodename = PVE::INotify::nodename();

    foreach_drive($conf, sub {
	my ($ds, $drive) = @_;

	my $volid = $drive->{file};
	return if !$volid;

	my ($storeid, $volname) = PVE::Storage::parse_volume_id($volid, 1);
	if ($storeid) {
	    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
	    if ($scfg->{disable}) {
		$nodehash = {};
	    } elsif (my $avail = $scfg->{nodes}) {
		foreach my $node (keys %$nodehash) {
		    delete $nodehash->{$node} if !$avail->{$node};
		}
	    } elsif (!$scfg->{shared}) {
		foreach my $node (keys %$nodehash) {
		    delete $nodehash->{$node} if $node ne $nodename
		}
	    }
	}
    });

    return $nodehash
}

sub check_local_storage_availability {
    my ($conf, $storecfg) = @_;

    my $nodelist = PVE::Cluster::get_nodelist();
    my $nodehash = { map { $_ => {} } @$nodelist };

    foreach_drive($conf, sub {
	my ($ds, $drive) = @_;

	my $volid = $drive->{file};
	return if !$volid;

	my ($storeid, $volname) = PVE::Storage::parse_volume_id($volid, 1);
	if ($storeid) {
	    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);

	    if ($scfg->{disable}) {
		foreach my $node (keys %$nodehash) {
		    $nodehash->{$node}->{unavailable_storages}->{$storeid} = 1;
		}
	    } elsif (my $avail = $scfg->{nodes}) {
		foreach my $node (keys %$nodehash) {
		    if (!$avail->{$node}) {
			$nodehash->{$node}->{unavailable_storages}->{$storeid} = 1;
		    }
		}
	    }
	}
    });

    foreach my $node (values %$nodehash) {
	if (my $unavail = $node->{unavailable_storages}) {
	    $node->{unavailable_storages} = [ sort keys %$unavail ];
	}
    }

    return $nodehash
}

sub check_cmdline {
    my ($pidfile, $pid) = @_;

    my $fh = IO::File->new("/proc/$pid/cmdline", "r");
    if (defined($fh)) {
	my $line = <$fh>;
	$fh->close;
	return undef if !$line;
	my @param = split(/\0/, $line);

	my $cmd = $param[0];
	return if !$cmd || ($cmd !~ m|kvm$| && $cmd !~ m@(?:^|/)qemu-system-[^/]+$@);

	for (my $i = 0; $i < scalar (@param); $i++) {
	    my $p = $param[$i];
	    next if !$p;
	    if (($p eq '-pidfile') || ($p eq '--pidfile')) {
		my $p = $param[$i+1];
		return 1 if $p && ($p eq $pidfile);
		return undef;
	    }
	}
    }
    return undef;
}

sub check_running {
    my ($vmid, $nocheck, $node) = @_;

    my $filename = PVE::QemuConfig->config_file($vmid, $node);

    die "unable to find configuration file for VM $vmid - no such machine\n"
	if !$nocheck && ! -f $filename;

    my $pidfile = pidfile_name($vmid);

    if (my $fd = IO::File->new("<$pidfile")) {
	my $st = stat($fd);
	my $line = <$fd>;
	close($fd);

	my $mtime = $st->mtime;
	if ($mtime > time()) {
	    warn "file '$filename' modified in future\n";
	}

	if ($line =~ m/^(\d+)$/) {
	    my $pid = $1;
	    if (check_cmdline($pidfile, $pid)) {
		if (my $pinfo = PVE::ProcFSTools::check_process_running($pid)) {
		    return $pid;
		}
	    }
	}
    }

    return undef;
}

sub vzlist {

    my $vzlist = config_list();

    my $fd = IO::Dir->new($var_run_tmpdir) || return $vzlist;

    while (defined(my $de = $fd->read)) {
	next if $de !~ m/^(\d+)\.pid$/;
	my $vmid = $1;
	next if !defined($vzlist->{$vmid});
	if (my $pid = check_running($vmid)) {
	    $vzlist->{$vmid}->{pid} = $pid;
	}
    }

    return $vzlist;
}

sub disksize {
    my ($storecfg, $conf) = @_;

    my $bootdisk = $conf->{bootdisk};
    return undef if !$bootdisk;
    return undef if !is_valid_drivename($bootdisk);

    return undef if !$conf->{$bootdisk};

    my $drive = parse_drive($bootdisk, $conf->{$bootdisk});
    return undef if !defined($drive);

    return undef if drive_is_cdrom($drive);

    my $volid = $drive->{file};
    return undef if !$volid;

    return $drive->{size};
}

our $vmstatus_return_properties = {
    vmid => get_standard_option('pve-vmid'),
    status => {
	description => "Qemu process status.",
	type => 'string',
	enum => ['stopped', 'running'],
    },
    maxmem => {
	description => "Maximum memory in bytes.",
	type => 'integer',
	optional => 1,
	renderer => 'bytes',
    },
    maxdisk => {
	description => "Root disk size in bytes.",
	type => 'integer',
	optional => 1,
	renderer => 'bytes',
    },
    name => {
	description => "VM name.",
	type => 'string',
	optional => 1,
    },
    qmpstatus => {
	description => "Qemu QMP agent status.",
	type => 'string',
	optional => 1,
    },
    pid => {
	description => "PID of running qemu process.",
	type => 'integer',
	optional => 1,
    },
    uptime => {
	description => "Uptime.",
	type => 'integer',
	optional => 1,
	renderer => 'duration',
    },
    cpus => {
	description => "Maximum usable CPUs.",
	type => 'number',
	optional => 1,
    },
    lock => {
	description => "The current config lock, if any.",
	type => 'string',
	optional => 1,
    }
};

my $last_proc_pid_stat;

# get VM status information
# This must be fast and should not block ($full == false)
# We only query KVM using QMP if $full == true (this can be slow)
sub vmstatus {
    my ($opt_vmid, $full) = @_;

    my $res = {};

    my $storecfg = PVE::Storage::config();

    my $list = vzlist();
    my $defaults = load_defaults();

    my ($uptime) = PVE::ProcFSTools::read_proc_uptime(1);

    my $cpucount = $cpuinfo->{cpus} || 1;

    foreach my $vmid (keys %$list) {
	next if $opt_vmid && ($vmid ne $opt_vmid);

	my $cfspath = PVE::QemuConfig->cfs_config_path($vmid);
	my $conf = PVE::Cluster::cfs_read_file($cfspath) || {};

	my $d = { vmid => $vmid };
	$d->{pid} = $list->{$vmid}->{pid};

	# fixme: better status?
	$d->{status} = $list->{$vmid}->{pid} ? 'running' : 'stopped';

	my $size = disksize($storecfg, $conf);
	if (defined($size)) {
	    $d->{disk} = 0; # no info available
	    $d->{maxdisk} = $size;
	} else {
	    $d->{disk} = 0;
	    $d->{maxdisk} = 0;
	}

	$d->{cpus} = ($conf->{sockets} || $defaults->{sockets})
	    * ($conf->{cores} || $defaults->{cores});
	$d->{cpus} = $cpucount if $d->{cpus} > $cpucount;
	$d->{cpus} = $conf->{vcpus} if $conf->{vcpus};

	$d->{name} = $conf->{name} || "VM $vmid";
	$d->{maxmem} = $conf->{memory} ? $conf->{memory}*(1024*1024)
	    : $defaults->{memory}*(1024*1024);

	if ($conf->{balloon}) {
	    $d->{balloon_min} = $conf->{balloon}*(1024*1024);
	    $d->{shares} = defined($conf->{shares}) ? $conf->{shares}
		: $defaults->{shares};
	}

	$d->{uptime} = 0;
	$d->{cpu} = 0;
	$d->{mem} = 0;

	$d->{netout} = 0;
	$d->{netin} = 0;

	$d->{diskread} = 0;
	$d->{diskwrite} = 0;

        $d->{template} = PVE::QemuConfig->is_template($conf);

	$d->{serial} = 1 if conf_has_serial($conf);
	$d->{lock} = $conf->{lock} if $conf->{lock};

	$res->{$vmid} = $d;
    }

    my $netdev = PVE::ProcFSTools::read_proc_net_dev();
    foreach my $dev (keys %$netdev) {
	next if $dev !~ m/^tap([1-9]\d*)i/;
	my $vmid = $1;
	my $d = $res->{$vmid};
	next if !$d;

	$d->{netout} += $netdev->{$dev}->{receive};
	$d->{netin} += $netdev->{$dev}->{transmit};

	if ($full) {
	    $d->{nics}->{$dev}->{netout} = $netdev->{$dev}->{receive};
	    $d->{nics}->{$dev}->{netin} = $netdev->{$dev}->{transmit};
	}

    }

    my $ctime = gettimeofday;

    foreach my $vmid (keys %$list) {

	my $d = $res->{$vmid};
	my $pid = $d->{pid};
	next if !$pid;

	my $pstat = PVE::ProcFSTools::read_proc_pid_stat($pid);
	next if !$pstat; # not running

	my $used = $pstat->{utime} + $pstat->{stime};

	$d->{uptime} = int(($uptime - $pstat->{starttime})/$cpuinfo->{user_hz});

	if ($pstat->{vsize}) {
	    $d->{mem} = int(($pstat->{rss}/$pstat->{vsize})*$d->{maxmem});
	}

	my $old = $last_proc_pid_stat->{$pid};
	if (!$old) {
	    $last_proc_pid_stat->{$pid} = {
		time => $ctime,
		used => $used,
		cpu => 0,
	    };
	    next;
	}

	my $dtime = ($ctime -  $old->{time}) * $cpucount * $cpuinfo->{user_hz};

	if ($dtime > 1000) {
	    my $dutime = $used -  $old->{used};

	    $d->{cpu} = (($dutime/$dtime)* $cpucount) / $d->{cpus};
	    $last_proc_pid_stat->{$pid} = {
		time => $ctime,
		used => $used,
		cpu => $d->{cpu},
	    };
	} else {
	    $d->{cpu} = $old->{cpu};
	}
    }

    return $res if !$full;

    my $qmpclient = PVE::QMPClient->new();

    my $ballooncb = sub {
	my ($vmid, $resp) = @_;

	my $info = $resp->{'return'};
	return if !$info->{max_mem};

	my $d = $res->{$vmid};

	# use memory assigned to VM
	$d->{maxmem} = $info->{max_mem};
	$d->{balloon} = $info->{actual};

	if (defined($info->{total_mem}) && defined($info->{free_mem})) {
	    $d->{mem} = $info->{total_mem} - $info->{free_mem};
	    $d->{freemem} = $info->{free_mem};
	}

	$d->{ballooninfo} = $info;
    };

    my $blockstatscb = sub {
	my ($vmid, $resp) = @_;
	my $data = $resp->{'return'} || [];
	my $totalrdbytes = 0;
	my $totalwrbytes = 0;

	for my $blockstat (@$data) {
	    $totalrdbytes = $totalrdbytes + $blockstat->{stats}->{rd_bytes};
	    $totalwrbytes = $totalwrbytes + $blockstat->{stats}->{wr_bytes};

	    $blockstat->{device} =~ s/drive-//;
	    $res->{$vmid}->{blockstat}->{$blockstat->{device}} = $blockstat->{stats};
	}
	$res->{$vmid}->{diskread} = $totalrdbytes;
	$res->{$vmid}->{diskwrite} = $totalwrbytes;
    };

    my $statuscb = sub {
	my ($vmid, $resp) = @_;

	$qmpclient->queue_cmd($vmid, $blockstatscb, 'query-blockstats');
	# this fails if ballon driver is not loaded, so this must be
	# the last commnand (following command are aborted if this fails).
	$qmpclient->queue_cmd($vmid, $ballooncb, 'query-balloon');

	my $status = 'unknown';
	if (!defined($status = $resp->{'return'}->{status})) {
	    warn "unable to get VM status\n";
	    return;
	}

	$res->{$vmid}->{qmpstatus} = $resp->{'return'}->{status};
    };

    foreach my $vmid (keys %$list) {
	next if $opt_vmid && ($vmid ne $opt_vmid);
	next if !$res->{$vmid}->{pid}; # not running
	$qmpclient->queue_cmd($vmid, $statuscb, 'query-status');
    }

    $qmpclient->queue_execute(undef, 2);

    foreach my $vmid (keys %$list) {
	next if $opt_vmid && ($vmid ne $opt_vmid);
	$res->{$vmid}->{qmpstatus} = $res->{$vmid}->{status} if !$res->{$vmid}->{qmpstatus};
    }

    return $res;
}

sub foreach_drive {
    my ($conf, $func, @param) = @_;

    foreach my $ds (valid_drive_names()) {
	next if !defined($conf->{$ds});

	my $drive = parse_drive($ds, $conf->{$ds});
	next if !$drive;

	&$func($ds, $drive, @param);
    }
}

sub foreach_volid {
    my ($conf, $func, @param) = @_;

    my $volhash = {};

    my $test_volid = sub {
	my ($volid, $is_cdrom, $replicate, $shared, $snapname, $size) = @_;

	return if !$volid;

	$volhash->{$volid}->{cdrom} //= 1;
	$volhash->{$volid}->{cdrom} = 0 if !$is_cdrom;

	$volhash->{$volid}->{replicate} //= 0;
	$volhash->{$volid}->{replicate} = 1 if $replicate;

	$volhash->{$volid}->{shared} //= 0;
	$volhash->{$volid}->{shared} = 1 if $shared;

	$volhash->{$volid}->{referenced_in_config} //= 0;
	$volhash->{$volid}->{referenced_in_config} = 1 if !defined($snapname);

	$volhash->{$volid}->{referenced_in_snapshot}->{$snapname} = 1
	    if defined($snapname);
	$volhash->{$volid}->{size} = $size if $size;
    };

    foreach_drive($conf, sub {
	my ($ds, $drive) = @_;
	$test_volid->($drive->{file}, drive_is_cdrom($drive), $drive->{replicate} // 1, $drive->{shared}, undef, $drive->{size});
    });

    foreach my $snapname (keys %{$conf->{snapshots}}) {
	my $snap = $conf->{snapshots}->{$snapname};
	$test_volid->($snap->{vmstate}, 0, 1, $snapname);
	foreach_drive($snap, sub {
	    my ($ds, $drive) = @_;
	    $test_volid->($drive->{file}, drive_is_cdrom($drive), $drive->{replicate} // 1, $drive->{shared}, $snapname);
        });
    }

    foreach my $volid (keys %$volhash) {
	&$func($volid, $volhash->{$volid}, @param);
    }
}

sub conf_has_serial {
    my ($conf) = @_;

    for (my $i = 0; $i < $MAX_SERIAL_PORTS; $i++)  {
	if ($conf->{"serial$i"}) {
	    return 1;
	}
    }

    return 0;
}

sub conf_has_audio {
    my ($conf, $id) = @_;

    $id //= 0;
    my $audio = $conf->{"audio$id"};
    return undef if !defined($audio);

    my $audioproperties = PVE::JSONSchema::parse_property_string($audio_fmt, $audio);
    my $audiodriver = $audioproperties->{driver} // 'spice';

    return {
	dev => $audioproperties->{device},
	dev_id => "audiodev$id",
	backend => $audiodriver,
	backend_id => "$audiodriver-backend${id}",
    };
}

sub vga_conf_has_spice {
    my ($vga) = @_;

    my $vgaconf = parse_vga($vga);
    my $vgatype = $vgaconf->{type};
    return 0 if !$vgatype || $vgatype !~ m/^qxl([234])?$/;

    return $1 || 1;
}

my $host_arch; # FIXME: fix PVE::Tools::get_host_arch
sub get_host_arch() {
    $host_arch = (POSIX::uname())[4] if !$host_arch;
    return $host_arch;
}

sub is_native($) {
    my ($arch) = @_;
    return get_host_arch() eq $arch;
}

my $default_machines = {
    x86_64 => 'pc',
    aarch64 => 'virt',
};

sub get_basic_machine_info {
    my ($conf, $forcemachine) = @_;

    my $arch = $conf->{arch} // get_host_arch();
    my $machine = $forcemachine || $conf->{machine} || $default_machines->{$arch};
    return ($arch, $machine);
}

sub get_ovmf_files($) {
    my ($arch) = @_;

    my $ovmf = $OVMF->{$arch}
	or die "no OVMF images known for architecture '$arch'\n";

    return @$ovmf;
}

my $Arch2Qemu = {
    aarch64 => '/usr/bin/qemu-system-aarch64',
    x86_64 => '/usr/bin/qemu-system-x86_64',
};
sub get_command_for_arch($) {
    my ($arch) = @_;
    return '/usr/bin/kvm' if is_native($arch);

    my $cmd = $Arch2Qemu->{$arch}
	or die "don't know how to emulate architecture '$arch'\n";
    return $cmd;
}

sub get_cpu_options {
    my ($conf, $arch, $kvm, $machine_type, $kvm_off, $kvmver, $winversion, $gpu_passthrough) = @_;

    my $cpuFlags = [];
    my $ostype = $conf->{ostype};

    my $cpu = $kvm ? "kvm64" : "qemu64";
    if ($arch eq 'aarch64') {
	$cpu = 'cortex-a57';
    }
    my $hv_vendor_id;
    if (my $cputype = $conf->{cpu}) {
	my $cpuconf = PVE::JSONSchema::parse_property_string($cpu_fmt, $cputype)
	    or die "Cannot parse cpu description: $cputype\n";
	$cpu = $cpuconf->{cputype};
	$kvm_off = 1 if $cpuconf->{hidden};
	$hv_vendor_id = $cpuconf->{'hv-vendor-id'};

	if (defined(my $flags = $cpuconf->{flags})) {
	    push @$cpuFlags, split(";", $flags);
	}
    }

    push @$cpuFlags , '+lahf_lm' if $cpu eq 'kvm64' && $arch eq 'x86_64';

    push @$cpuFlags , '-x2apic'
	if $conf->{ostype} && $conf->{ostype} eq 'solaris';

    push @$cpuFlags, '+sep' if $cpu eq 'kvm64' || $cpu eq 'kvm32';

    push @$cpuFlags, '-rdtscp' if $cpu =~ m/^Opteron/;

    if (qemu_machine_feature_enabled ($machine_type, $kvmver, 2, 3) && $arch eq 'x86_64') {

	push @$cpuFlags , '+kvm_pv_unhalt' if $kvm;
	push @$cpuFlags , '+kvm_pv_eoi' if $kvm;
    }

    add_hyperv_enlightenments($cpuFlags, $winversion, $machine_type, $kvmver, $conf->{bios}, $gpu_passthrough, $hv_vendor_id) if $kvm;

    push @$cpuFlags, 'enforce' if $cpu ne 'host' && $kvm && $arch eq 'x86_64';

    push @$cpuFlags, 'kvm=off' if $kvm_off;

    if (my $cpu_vendor = $cpu_vendor_list->{$cpu}) {
	push @$cpuFlags, "vendor=${cpu_vendor}"
	    if $cpu_vendor ne 'default';
    } elsif ($arch ne 'aarch64') {
	die "internal error"; # should not happen
    }

    $cpu .= "," . join(',', @$cpuFlags) if scalar(@$cpuFlags);

    return ('-cpu', $cpu);
}

sub config_to_command {
    my ($storecfg, $vmid, $conf, $defaults, $forcemachine) = @_;

    my $cmd = [];
    my $globalFlags = [];
    my $machineFlags = [];
    my $rtcFlags = [];
    my $devices = [];
    my $pciaddr = '';
    my $bridges = {};
    my $vernum = 0; # unknown
    my $ostype = $conf->{ostype};
    my $winversion = windows_version($ostype);
    my $kvm = $conf->{kvm};

    my ($arch, $machine_type) = get_basic_machine_info($conf, $forcemachine);
    my $kvm_binary = get_command_for_arch($arch);
    my $kvmver = kvm_user_version($kvm_binary);
    $kvm //= 1 if is_native($arch);

    if ($kvm) {
	die "KVM virtualisation configured, but not available. Either disable in VM configuration or enable in BIOS.\n"
	    if !defined kvm_version();
    }

    if ($kvmver =~ m/^(\d+)\.(\d+)$/) {
	$vernum = $1*1000000+$2*1000;
    } elsif ($kvmver =~ m/^(\d+)\.(\d+)\.(\d+)$/) {
	$vernum = $1*1000000+$2*1000+$3;
    }

    die "detected old qemu-kvm binary ($kvmver)\n" if $vernum < 15000;

    my $have_ovz = -f '/proc/vz/vestat';

    my $q35 = machine_type_is_q35($conf);
    my $hotplug_features = parse_hotplug_features(defined($conf->{hotplug}) ? $conf->{hotplug} : '1');
    my $use_old_bios_files = undef;
    ($use_old_bios_files, $machine_type) = qemu_use_old_bios_files($machine_type);

    my $cpuunits = defined($conf->{cpuunits}) ?
            $conf->{cpuunits} : $defaults->{cpuunits};

    push @$cmd, $kvm_binary;

    push @$cmd, '-id', $vmid;

    my $vmname = $conf->{name} || "vm$vmid";

    push @$cmd, '-name', $vmname;

    my $use_virtio = 0;

    my $qmpsocket = qmp_socket($vmid);
    push @$cmd, '-chardev', "socket,id=qmp,path=$qmpsocket,server,nowait";
    push @$cmd, '-mon', "chardev=qmp,mode=control";

    if (qemu_machine_feature_enabled($machine_type, $kvmver, 2, 12)) {
	push @$cmd, '-chardev', "socket,id=qmp-event,path=/var/run/qmeventd.sock,reconnect=5";
	push @$cmd, '-mon', "chardev=qmp-event,mode=control";
    }

    push @$cmd, '-pidfile' , pidfile_name($vmid);

    push @$cmd, '-daemonize';

    if ($conf->{smbios1}) {
	my $smbios_conf = parse_smbios1($conf->{smbios1});
	if ($smbios_conf->{base64}) {
	    # Do not pass base64 flag to qemu
	    delete $smbios_conf->{base64};
	    my $smbios_string = "";
	    foreach my $key (keys %$smbios_conf) {
		my $value;
		if ($key eq "uuid") {
		    $value = $smbios_conf->{uuid}
		} else {
		    $value = decode_base64($smbios_conf->{$key});
		}
		# qemu accepts any binary data, only commas need escaping by double comma
		$value =~ s/,/,,/g;
		$smbios_string .= "," . $key . "=" . $value if $value;
	    }
	    push @$cmd, '-smbios', "type=1" . $smbios_string;
	} else {
	    push @$cmd, '-smbios', "type=1,$conf->{smbios1}";
	}
    }

    if ($conf->{vmgenid}) {
	push @$devices, '-device', 'vmgenid,guid='.$conf->{vmgenid};
    }

    my ($ovmf_code, $ovmf_vars) = get_ovmf_files($arch);
    if ($conf->{bios} && $conf->{bios} eq 'ovmf') {
	die "uefi base image not found\n" if ! -f $ovmf_code;

	my $path;
	my $format;
	if (my $efidisk = $conf->{efidisk0}) {
	    my $d = PVE::JSONSchema::parse_property_string($efidisk_fmt, $efidisk);
	    my ($storeid, $volname) = PVE::Storage::parse_volume_id($d->{file}, 1);
	    $format = $d->{format};
	    if ($storeid) {
		$path = PVE::Storage::path($storecfg, $d->{file});
		if (!defined($format)) {
		    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
		    $format = qemu_img_format($scfg, $volname);
		}
	    } else {
		$path = $d->{file};
		die "efidisk format must be specified\n"
		    if !defined($format);
	    }
	} else {
	    warn "no efidisk configured! Using temporary efivars disk.\n";
	    $path = "/tmp/$vmid-ovmf.fd";
	    PVE::Tools::file_copy($ovmf_vars, $path, -s $ovmf_vars);
	    $format = 'raw';
	}

	push @$cmd, '-drive', "if=pflash,unit=0,format=raw,readonly,file=$ovmf_code";
	push @$cmd, '-drive', "if=pflash,unit=1,format=$format,id=drive-efidisk0,file=$path";
    }

    # load q35 config
    if ($q35) {
	# we use different pcie-port hardware for qemu >= 4.0 for passthrough
	if (qemu_machine_feature_enabled($machine_type, $kvmver, 4, 0)) {
	    push @$devices, '-readconfig', '/usr/share/qemu-server/pve-q35-4.0.cfg';
	} else {
	    push @$devices, '-readconfig', '/usr/share/qemu-server/pve-q35.cfg';
	}
    }

    # add usb controllers
    my @usbcontrollers = PVE::QemuServer::USB::get_usb_controllers($conf, $bridges, $arch, $machine_type, $usbdesc->{format}, $MAX_USB_DEVICES);
    push @$devices, @usbcontrollers if @usbcontrollers;
    my $vga = parse_vga($conf->{vga});

    my $qxlnum = vga_conf_has_spice($conf->{vga});
    $vga->{type} = 'qxl' if $qxlnum;

    if (!$vga->{type}) {
	if ($arch eq 'aarch64') {
	    $vga->{type} = 'virtio';
	} elsif (qemu_machine_feature_enabled($machine_type, $kvmver, 2, 9)) {
	    $vga->{type} = (!$winversion || $winversion >= 6) ? 'std' : 'cirrus';
	} else {
	    $vga->{type} = ($winversion >= 6) ? 'std' : 'cirrus';
	}
    }

    # enable absolute mouse coordinates (needed by vnc)
    my $tablet;
    if (defined($conf->{tablet})) {
	$tablet = $conf->{tablet};
    } else {
	$tablet = $defaults->{tablet};
	$tablet = 0 if $qxlnum; # disable for spice because it is not needed
	$tablet = 0 if $vga->{type} =~ m/^serial\d+$/; # disable if we use serial terminal (no vga card)
    }

    if ($tablet) {
	push @$devices, '-device', print_tabletdevice_full($conf, $arch) if $tablet;
	my $kbd = print_keyboarddevice_full($conf, $arch);
	push @$devices, '-device', $kbd if defined($kbd);
    }

    my $kvm_off = 0;
    my $gpu_passthrough;

    # host pci devices
    for (my $i = 0; $i < $MAX_HOSTPCI_DEVICES; $i++)  {
	my $id = "hostpci$i";
	my $d = parse_hostpci($conf->{$id});
	next if !$d;

	if (my $pcie = $d->{pcie}) {
	    die "q35 machine model is not enabled" if !$q35;
	    # win7 wants to have the pcie devices directly on the pcie bus
	    # instead of in the root port
	    if ($winversion == 7) {
		$pciaddr = print_pcie_addr("${id}bus0");
	    } else {
		# add more root ports if needed, 4 are present by default
		# by pve-q35 cfgs, rest added here on demand.
		if ($i > 3) {
		    push @$devices, '-device', print_pcie_root_port($i);
		}
		$pciaddr = print_pcie_addr($id);
	    }
	} else {
	    $pciaddr = print_pci_addr($id, $bridges, $arch, $machine_type);
	}

	my $xvga = '';
	if ($d->{'x-vga'}) {
	    $xvga = ',x-vga=on' if !($conf->{bios} && $conf->{bios} eq 'ovmf');
	    $kvm_off = 1;
	    $vga->{type} = 'none' if !defined($conf->{vga});
	    $gpu_passthrough = 1;
	}

	my $pcidevices = $d->{pciid};
	my $multifunction = 1 if @$pcidevices > 1;

	my $sysfspath;
	if ($d->{mdev} && scalar(@$pcidevices) == 1) {
	    my $pci_id = $pcidevices->[0]->{id};
	    my $uuid = PVE::SysFSTools::generate_mdev_uuid($vmid, $i);
	    $sysfspath = "/sys/bus/pci/devices/0000:$pci_id/$uuid";
	} elsif ($d->{mdev}) {
	    warn "ignoring mediated device '$id' with multifunction device\n";
	}

	my $j=0;
	foreach my $pcidevice (@$pcidevices) {
	    my $devicestr = "vfio-pci";

	    if ($sysfspath) {
		$devicestr .= ",sysfsdev=$sysfspath";
	    } else {
		$devicestr .= ",host=$pcidevice->{id}";
	    }

	    my $mf_addr = $multifunction ? ".$j" : '';
	    $devicestr .= ",id=${id}${mf_addr}${pciaddr}${mf_addr}";

	    if ($j == 0) {
		$devicestr .= ',rombar=0' if defined($d->{rombar}) && !$d->{rombar};
		$devicestr .= "$xvga";
		$devicestr .= ",multifunction=on" if $multifunction;
		$devicestr .= ",romfile=/usr/share/kvm/$d->{romfile}" if $d->{romfile};
	    }

	    push @$devices, '-device', $devicestr;
	    $j++;
	}
    }

    # usb devices
    my @usbdevices = PVE::QemuServer::USB::get_usb_devices($conf, $usbdesc->{format}, $MAX_USB_DEVICES);
    push @$devices, @usbdevices if @usbdevices;
    # serial devices
    for (my $i = 0; $i < $MAX_SERIAL_PORTS; $i++)  {
	if (my $path = $conf->{"serial$i"}) {
	    if ($path eq 'socket') {
		my $socket = "/var/run/qemu-server/${vmid}.serial$i";
		push @$devices, '-chardev', "socket,id=serial$i,path=$socket,server,nowait";
		# On aarch64, serial0 is the UART device. Qemu only allows
		# connecting UART devices via the '-serial' command line, as
		# the device has a fixed slot on the hardware...
		if ($arch eq 'aarch64' && $i == 0) {
		    push @$devices, '-serial', "chardev:serial$i";
		} else {
		    push @$devices, '-device', "isa-serial,chardev=serial$i";
		}
	    } else {
		die "no such serial device\n" if ! -c $path;
		push @$devices, '-chardev', "tty,id=serial$i,path=$path";
		push @$devices, '-device', "isa-serial,chardev=serial$i";
	    }
	}
    }

    # parallel devices
    for (my $i = 0; $i < $MAX_PARALLEL_PORTS; $i++)  {
	if (my $path = $conf->{"parallel$i"}) {
	    die "no such parallel device\n" if ! -c $path;
	    my $devtype = $path =~ m!^/dev/usb/lp! ? 'tty' : 'parport';
	    push @$devices, '-chardev', "$devtype,id=parallel$i,path=$path";
	    push @$devices, '-device', "isa-parallel,chardev=parallel$i";
	}
    }

    if (my $audio = conf_has_audio($conf)) {

	my $audiopciaddr = print_pci_addr("audio0", $bridges, $arch, $machine_type);

	my $id = $audio->{dev_id};
	if ($audio->{dev} eq 'AC97') {
	    push @$devices, '-device', "AC97,id=${id}${audiopciaddr}";
	} elsif ($audio->{dev} =~ /intel\-hda$/) {
	    push @$devices, '-device', "$audio->{dev},id=${id}${audiopciaddr}";
	    push @$devices, '-device', "hda-micro,id=${id}-codec0,bus=${id}.0,cad=0";
	    push @$devices, '-device', "hda-duplex,id=${id}-codec1,bus=${id}.0,cad=1";
	} else {
	    die "unkown audio device '$audio->{dev}', implement me!";
	}

	push @$devices, '-audiodev', "$audio->{backend},id=$audio->{backend_id}";
    }

    my $sockets = 1;
    $sockets = $conf->{smp} if $conf->{smp}; # old style - no longer iused
    $sockets = $conf->{sockets} if  $conf->{sockets};

    my $cores = $conf->{cores} || 1;

    my $maxcpus = $sockets * $cores;

    my $vcpus = $conf->{vcpus} ? $conf->{vcpus} : $maxcpus;

    my $allowed_vcpus = $cpuinfo->{cpus};

    die "MAX $allowed_vcpus vcpus allowed per VM on this node\n"
	if ($allowed_vcpus < $maxcpus);

    if($hotplug_features->{cpu} && qemu_machine_feature_enabled ($machine_type, $kvmver, 2, 7)) {

	push @$cmd, '-smp', "1,sockets=$sockets,cores=$cores,maxcpus=$maxcpus";
        for (my $i = 2; $i <= $vcpus; $i++)  {
	    my $cpustr = print_cpu_device($conf,$i);
	    push @$cmd, '-device', $cpustr;
	}

    } else {

	push @$cmd, '-smp', "$vcpus,sockets=$sockets,cores=$cores,maxcpus=$maxcpus";
    }
    push @$cmd, '-nodefaults';

    my $bootorder = $conf->{boot} || $confdesc->{boot}->{default};

    my $bootindex_hash = {};
    my $i = 1;
    foreach my $o (split(//, $bootorder)) {
	$bootindex_hash->{$o} = $i*100;
	$i++;
    }

    push @$cmd, '-boot', "menu=on,strict=on,reboot-timeout=1000,splash=/usr/share/qemu-server/bootsplash.jpg";

    push @$cmd, '-no-acpi' if defined($conf->{acpi}) && $conf->{acpi} == 0;

    push @$cmd, '-no-reboot' if  defined($conf->{reboot}) && $conf->{reboot} == 0;

    if ($vga->{type} && $vga->{type} !~ m/^serial\d+$/ && $vga->{type} ne 'none'){
	push @$devices, '-device', print_vga_device($conf, $vga, $arch, $machine_type, undef, $qxlnum, $bridges);
	my $socket = vnc_socket($vmid);
	push @$cmd,  '-vnc', "unix:$socket,password";
    } else {
	push @$cmd, '-vga', 'none' if $vga->{type} eq 'none';
	push @$cmd, '-nographic';
    }

    # time drift fix
    my $tdf = defined($conf->{tdf}) ? $conf->{tdf} : $defaults->{tdf};

    my $useLocaltime = $conf->{localtime};

    if ($winversion >= 5) { # windows
	$useLocaltime = 1 if !defined($conf->{localtime});

	# use time drift fix when acpi is enabled
	if (!(defined($conf->{acpi}) && $conf->{acpi} == 0)) {
	    $tdf = 1 if !defined($conf->{tdf});
	}
    }

    if ($winversion >= 6) {
	push @$globalFlags, 'kvm-pit.lost_tick_policy=discard';
	push @$cmd, '-no-hpet';
    }

    push @$rtcFlags, 'driftfix=slew' if $tdf;

    if (!$kvm) {
	push @$machineFlags, 'accel=tcg';
    }

    if ($machine_type) {
	push @$machineFlags, "type=${machine_type}";
    }

    if (($conf->{startdate}) && ($conf->{startdate} ne 'now')) {
	push @$rtcFlags, "base=$conf->{startdate}";
    } elsif ($useLocaltime) {
	push @$rtcFlags, 'base=localtime';
    }

    push @$cmd, get_cpu_options($conf, $arch, $kvm, $machine_type, $kvm_off, $kvmver, $winversion, $gpu_passthrough);

    PVE::QemuServer::Memory::config($conf, $vmid, $sockets, $cores, $defaults, $hotplug_features, $cmd);

    push @$cmd, '-S' if $conf->{freeze};

    push @$cmd, '-k', $conf->{keyboard} if defined($conf->{keyboard});

    if (parse_guest_agent($conf)->{enabled}) {
	my $qgasocket = qmp_socket($vmid, 1);
	my $pciaddr = print_pci_addr("qga0", $bridges, $arch, $machine_type);
	push @$devices, '-chardev', "socket,path=$qgasocket,server,nowait,id=qga0";
	push @$devices, '-device', "virtio-serial,id=qga0$pciaddr";
	push @$devices, '-device', 'virtserialport,chardev=qga0,name=org.qemu.guest_agent.0';
    }

    my $spice_port;

    if ($qxlnum) {
	if ($qxlnum > 1) {
	    if ($winversion){
		for(my $i = 1; $i < $qxlnum; $i++){
		    push @$devices, '-device', print_vga_device($conf, $vga, $arch, $machine_type, $i, $qxlnum, $bridges);
		}
	    } else {
		# assume other OS works like Linux
		my ($ram, $vram) = ("134217728", "67108864");
		if ($vga->{memory}) {
		    $ram = PVE::Tools::convert_size($qxlnum*4*$vga->{memory}, 'mb' => 'b');
		    $vram = PVE::Tools::convert_size($qxlnum*2*$vga->{memory}, 'mb' => 'b');
		}
		push @$cmd, '-global', "qxl-vga.ram_size=$ram";
		push @$cmd, '-global', "qxl-vga.vram_size=$vram";
	    }
	}

	my $pciaddr = print_pci_addr("spice", $bridges, $arch, $machine_type);

	my $nodename = PVE::INotify::nodename();
	my $pfamily = PVE::Tools::get_host_address_family($nodename);
	my @nodeaddrs = PVE::Tools::getaddrinfo_all('localhost', family => $pfamily);
	die "failed to get an ip address of type $pfamily for 'localhost'\n" if !@nodeaddrs;
	my $localhost = PVE::Network::addr_to_ip($nodeaddrs[0]->{addr});
	$spice_port = PVE::Tools::next_spice_port($pfamily, $localhost);

	my $spice_enhancement = PVE::JSONSchema::parse_property_string($spice_enhancements_fmt, $conf->{spice_enhancements} // '');
	if ($spice_enhancement->{foldersharing}) {
	    push @$devices, '-chardev', "spiceport,id=foldershare,name=org.spice-space.webdav.0";
	    push @$devices, '-device', "virtserialport,chardev=foldershare,name=org.spice-space.webdav.0";
	}

	my $spice_opts = "tls-port=${spice_port},addr=$localhost,tls-ciphers=HIGH,seamless-migration=on";
	$spice_opts .= ",streaming-video=$spice_enhancement->{videostreaming}" if $spice_enhancement->{videostreaming};
	push @$devices, '-spice', "$spice_opts";

	push @$devices, '-device', "virtio-serial,id=spice$pciaddr";
	push @$devices, '-chardev', "spicevmc,id=vdagent,name=vdagent";
	push @$devices, '-device', "virtserialport,chardev=vdagent,name=com.redhat.spice.0";

    }

    # enable balloon by default, unless explicitly disabled
    if (!defined($conf->{balloon}) || $conf->{balloon}) {
	$pciaddr = print_pci_addr("balloon0", $bridges, $arch, $machine_type);
	push @$devices, '-device', "virtio-balloon-pci,id=balloon0$pciaddr";
    }

    if ($conf->{watchdog}) {
	my $wdopts = parse_watchdog($conf->{watchdog});
	$pciaddr = print_pci_addr("watchdog", $bridges, $arch, $machine_type);
	my $watchdog = $wdopts->{model} || 'i6300esb';
	push @$devices, '-device', "$watchdog$pciaddr";
	push @$devices, '-watchdog-action', $wdopts->{action} if $wdopts->{action};
    }

    my $vollist = [];
    my $scsicontroller = {};
    my $ahcicontroller = {};
    my $scsihw = defined($conf->{scsihw}) ? $conf->{scsihw} : $defaults->{scsihw};

    # Add iscsi initiator name if available
    if (my $initiator = get_initiator_name()) {
	push @$devices, '-iscsi', "initiator-name=$initiator";
    }

    foreach_drive($conf, sub {
	my ($ds, $drive) = @_;

	if (PVE::Storage::parse_volume_id($drive->{file}, 1)) {
	    push @$vollist, $drive->{file};
	}

	# ignore efidisk here, already added in bios/fw handling code above
	return if $drive->{interface} eq 'efidisk';

	$use_virtio = 1 if $ds =~ m/^virtio/;

	if (drive_is_cdrom ($drive)) {
	    if ($bootindex_hash->{d}) {
		$drive->{bootindex} = $bootindex_hash->{d};
		$bootindex_hash->{d} += 1;
	    }
	} else {
	    if ($bootindex_hash->{c}) {
		$drive->{bootindex} = $bootindex_hash->{c} if $conf->{bootdisk} && ($conf->{bootdisk} eq $ds);
		$bootindex_hash->{c} += 1;
	    }
	}

	if($drive->{interface} eq 'virtio'){
           push @$cmd, '-object', "iothread,id=iothread-$ds" if $drive->{iothread};
	}

        if ($drive->{interface} eq 'scsi') {

	    my ($maxdev, $controller, $controller_prefix) = scsihw_infos($conf, $drive);

	    $pciaddr = print_pci_addr("$controller_prefix$controller", $bridges, $arch, $machine_type);
	    my $scsihw_type = $scsihw =~ m/^virtio-scsi-single/ ? "virtio-scsi-pci" : $scsihw;

	    my $iothread = '';
	    if($conf->{scsihw} && $conf->{scsihw} eq "virtio-scsi-single" && $drive->{iothread}){
		$iothread .= ",iothread=iothread-$controller_prefix$controller";
		push @$cmd, '-object', "iothread,id=iothread-$controller_prefix$controller";
	    } elsif ($drive->{iothread}) {
		warn "iothread is only valid with virtio disk or virtio-scsi-single controller, ignoring\n";
	    }

	    my $queues = '';
	    if($conf->{scsihw} && $conf->{scsihw} eq "virtio-scsi-single" && $drive->{queues}){
		$queues = ",num_queues=$drive->{queues}";
	    }

	    push @$devices, '-device', "$scsihw_type,id=$controller_prefix$controller$pciaddr$iothread$queues" if !$scsicontroller->{$controller};
	    $scsicontroller->{$controller}=1;
        }

        if ($drive->{interface} eq 'sata') {
           my $controller = int($drive->{index} / $MAX_SATA_DISKS);
           $pciaddr = print_pci_addr("ahci$controller", $bridges, $arch, $machine_type);
           push @$devices, '-device', "ahci,id=ahci$controller,multifunction=on$pciaddr" if !$ahcicontroller->{$controller};
           $ahcicontroller->{$controller}=1;
        }

	my $drive_cmd = print_drive_full($storecfg, $vmid, $drive);
	push @$devices, '-drive',$drive_cmd;
	push @$devices, '-device', print_drivedevice_full($storecfg, $conf, $vmid, $drive, $bridges, $arch, $machine_type);
    });

    for (my $i = 0; $i < $MAX_NETS; $i++) {
         next if !$conf->{"net$i"};
         my $d = parse_net($conf->{"net$i"});
         next if !$d;

         $use_virtio = 1 if $d->{model} eq 'virtio';

         if ($bootindex_hash->{n}) {
            $d->{bootindex} = $bootindex_hash->{n};
            $bootindex_hash->{n} += 1;
         }

         my $netdevfull = print_netdev_full($vmid, $conf, $arch, $d, "net$i");
         push @$devices, '-netdev', $netdevfull;

         my $netdevicefull = print_netdevice_full($vmid, $conf, $d, "net$i", $bridges, $use_old_bios_files, $arch, $machine_type);
         push @$devices, '-device', $netdevicefull;
    }

    if ($conf->{ivshmem}) {
	my $ivshmem = PVE::JSONSchema::parse_property_string($ivshmem_fmt, $conf->{ivshmem});

	my $bus;
	if ($q35) {
	    $bus = print_pcie_addr("ivshmem");
	} else {
	    $bus = print_pci_addr("ivshmem", $bridges, $arch, $machine_type);
	}

	my $ivshmem_name = $ivshmem->{name} // $vmid;
	my $path = '/dev/shm/pve-shm-' . $ivshmem_name;

	push @$devices, '-device', "ivshmem-plain,memdev=ivshmem$bus,";
	push @$devices, '-object', "memory-backend-file,id=ivshmem,share=on,mem-path=$path,size=$ivshmem->{size}M";
    }

    if (!$q35) {
	# add pci bridges
        if (qemu_machine_feature_enabled ($machine_type, $kvmver, 2, 3)) {
	   $bridges->{1} = 1;
	   $bridges->{2} = 1;
	}

	$bridges->{3} = 1 if $scsihw =~ m/^virtio-scsi-single/;

	while (my ($k, $v) = each %$bridges) {
	    $pciaddr = print_pci_addr("pci.$k", undef, $arch, $machine_type);
	    unshift @$devices, '-device', "pci-bridge,id=pci.$k,chassis_nr=$k$pciaddr" if $k > 0;
	}
    }

    push @$cmd, @$devices;
    push @$cmd, '-rtc', join(',', @$rtcFlags)
	if scalar(@$rtcFlags);
    push @$cmd, '-machine', join(',', @$machineFlags)
	if scalar(@$machineFlags);
    push @$cmd, '-global', join(',', @$globalFlags)
	if scalar(@$globalFlags);

    if (my $vmstate = $conf->{vmstate}) {
	my $statepath = PVE::Storage::path($storecfg, $vmstate);
	PVE::Storage::activate_volumes($storecfg, [$vmstate]);
	push @$cmd, '-loadstate', $statepath;
    }

    # add custom args
    if ($conf->{args}) {
	my $aa = PVE::Tools::split_args($conf->{args});
	push @$cmd, @$aa;
    }

    return wantarray ? ($cmd, $vollist, $spice_port) : $cmd;
}

sub vnc_socket {
    my ($vmid) = @_;
    return "${var_run_tmpdir}/$vmid.vnc";
}

sub spice_port {
    my ($vmid) = @_;

    my $res = vm_mon_cmd($vmid, 'query-spice');

    return $res->{'tls-port'} || $res->{'port'} || die "no spice port\n";
}

sub qmp_socket {
    my ($vmid, $qga, $name) = @_;
    my $sockettype = $qga ? 'qga' : 'qmp';
    my $ext = $name ? '-'.$name : '';
    return "${var_run_tmpdir}/$vmid$ext.$sockettype";
}

sub pidfile_name {
    my ($vmid) = @_;
    return "${var_run_tmpdir}/$vmid.pid";
}

sub vm_devices_list {
    my ($vmid) = @_;

    my $res = vm_mon_cmd($vmid, 'query-pci');
    my $devices_to_check = [];
    my $devices = {};
    foreach my $pcibus (@$res) {
	push @$devices_to_check, @{$pcibus->{devices}},
    }

    while (@$devices_to_check) {
	my $to_check = [];
	for my $d (@$devices_to_check) {
	    $devices->{$d->{'qdev_id'}} = 1 if $d->{'qdev_id'};
	    next if !$d->{'pci_bridge'};

	    $devices->{$d->{'qdev_id'}} += scalar(@{$d->{'pci_bridge'}->{devices}});
	    push @$to_check, @{$d->{'pci_bridge'}->{devices}};
	}
	$devices_to_check = $to_check;
    }

    my $resblock = vm_mon_cmd($vmid, 'query-block');
    foreach my $block (@$resblock) {
	if($block->{device} =~ m/^drive-(\S+)/){
		$devices->{$1} = 1;
	}
    }

    my $resmice = vm_mon_cmd($vmid, 'query-mice');
    foreach my $mice (@$resmice) {
	if ($mice->{name} eq 'QEMU HID Tablet') {
	    $devices->{tablet} = 1;
	    last;
	}
    }

    # for usb devices there is no query-usb
    # but we can iterate over the entries in
    # qom-list path=/machine/peripheral
    my $resperipheral = vm_mon_cmd($vmid, 'qom-list', path => '/machine/peripheral');
    foreach my $per (@$resperipheral) {
	if ($per->{name} =~ m/^usb\d+$/) {
	    $devices->{$per->{name}} = 1;
	}
    }

    return $devices;
}

sub vm_deviceplug {
    my ($storecfg, $conf, $vmid, $deviceid, $device, $arch, $machine_type) = @_;

    my $q35 = machine_type_is_q35($conf);

    my $devices_list = vm_devices_list($vmid);
    return 1 if defined($devices_list->{$deviceid});

    qemu_add_pci_bridge($storecfg, $conf, $vmid, $deviceid, $arch, $machine_type); # add PCI bridge if we need it for the device

    if ($deviceid eq 'tablet') {

	qemu_deviceadd($vmid, print_tabletdevice_full($conf, $arch));

    } elsif ($deviceid eq 'keyboard') {

	qemu_deviceadd($vmid, print_keyboarddevice_full($conf, $arch));

    } elsif ($deviceid =~ m/^usb(\d+)$/) {

	die "usb hotplug currently not reliable\n";
	# since we can't reliably hot unplug all added usb devices
	# and usb passthrough disables live migration
	# we disable usb hotplugging for now
	qemu_deviceadd($vmid, PVE::QemuServer::USB::print_usbdevice_full($conf, $deviceid, $device));

    } elsif ($deviceid =~ m/^(virtio)(\d+)$/) {

	qemu_iothread_add($vmid, $deviceid, $device);

        qemu_driveadd($storecfg, $vmid, $device);
        my $devicefull = print_drivedevice_full($storecfg, $conf, $vmid, $device, $arch, $machine_type);

        qemu_deviceadd($vmid, $devicefull);
	eval { qemu_deviceaddverify($vmid, $deviceid); };
	if (my $err = $@) {
	    eval { qemu_drivedel($vmid, $deviceid); };
	    warn $@ if $@;
	    die $err;
        }

    } elsif ($deviceid =~ m/^(virtioscsi|scsihw)(\d+)$/) {


        my $scsihw = defined($conf->{scsihw}) ? $conf->{scsihw} : "lsi";
        my $pciaddr = print_pci_addr($deviceid, undef, $arch, $machine_type);
	my $scsihw_type = $scsihw eq 'virtio-scsi-single' ? "virtio-scsi-pci" : $scsihw;

        my $devicefull = "$scsihw_type,id=$deviceid$pciaddr";

	if($deviceid =~ m/^virtioscsi(\d+)$/ && $device->{iothread}) {
	    qemu_iothread_add($vmid, $deviceid, $device);
	    $devicefull .= ",iothread=iothread-$deviceid";
	}

	if($deviceid =~ m/^virtioscsi(\d+)$/ && $device->{queues}) {
	    $devicefull .= ",num_queues=$device->{queues}";
	}

        qemu_deviceadd($vmid, $devicefull);
        qemu_deviceaddverify($vmid, $deviceid);

    } elsif ($deviceid =~ m/^(scsi)(\d+)$/) {

        qemu_findorcreatescsihw($storecfg,$conf, $vmid, $device, $arch, $machine_type);
        qemu_driveadd($storecfg, $vmid, $device);

	my $devicefull = print_drivedevice_full($storecfg, $conf, $vmid, $device, $arch, $machine_type);
	eval { qemu_deviceadd($vmid, $devicefull); };
	if (my $err = $@) {
	    eval { qemu_drivedel($vmid, $deviceid); };
	    warn $@ if $@;
	    die $err;
        }

    } elsif ($deviceid =~ m/^(net)(\d+)$/) {

	return undef if !qemu_netdevadd($vmid, $conf, $arch, $device, $deviceid);

	my $machine_type = PVE::QemuServer::qemu_machine_pxe($vmid, $conf);
	my $use_old_bios_files = undef;
	($use_old_bios_files, $machine_type) = qemu_use_old_bios_files($machine_type);

	my $netdevicefull = print_netdevice_full($vmid, $conf, $device, $deviceid, undef, $use_old_bios_files, $arch, $machine_type);
	qemu_deviceadd($vmid, $netdevicefull);
	eval {
	    qemu_deviceaddverify($vmid, $deviceid);
	    qemu_set_link_status($vmid, $deviceid, !$device->{link_down});
	};
	if (my $err = $@) {
	    eval { qemu_netdevdel($vmid, $deviceid); };
	    warn $@ if $@;
	    die $err;
	}

    } elsif (!$q35 && $deviceid =~ m/^(pci\.)(\d+)$/) {

	my $bridgeid = $2;
	my $pciaddr = print_pci_addr($deviceid, undef, $arch, $machine_type);
	my $devicefull = "pci-bridge,id=pci.$bridgeid,chassis_nr=$bridgeid$pciaddr";

	qemu_deviceadd($vmid, $devicefull);
	qemu_deviceaddverify($vmid, $deviceid);

    } else {
	die "can't hotplug device '$deviceid'\n";
    }

    return 1;
}

# fixme: this should raise exceptions on error!
sub vm_deviceunplug {
    my ($vmid, $conf, $deviceid) = @_;

    my $devices_list = vm_devices_list($vmid);
    return 1 if !defined($devices_list->{$deviceid});

    die "can't unplug bootdisk" if $conf->{bootdisk} && $conf->{bootdisk} eq $deviceid;

    if ($deviceid eq 'tablet' || $deviceid eq 'keyboard') {

	qemu_devicedel($vmid, $deviceid);

    } elsif ($deviceid =~ m/^usb\d+$/) {

	die "usb hotplug currently not reliable\n";
	# when unplugging usb devices this way,
	# there may be remaining usb controllers/hubs
	# so we disable it for now
	qemu_devicedel($vmid, $deviceid);
	qemu_devicedelverify($vmid, $deviceid);

    } elsif ($deviceid =~ m/^(virtio)(\d+)$/) {

        qemu_devicedel($vmid, $deviceid);
        qemu_devicedelverify($vmid, $deviceid);
        qemu_drivedel($vmid, $deviceid);
	qemu_iothread_del($conf, $vmid, $deviceid);

    } elsif ($deviceid =~ m/^(virtioscsi|scsihw)(\d+)$/) {

	qemu_devicedel($vmid, $deviceid);
	qemu_devicedelverify($vmid, $deviceid);
	qemu_iothread_del($conf, $vmid, $deviceid);

    } elsif ($deviceid =~ m/^(scsi)(\d+)$/) {

        qemu_devicedel($vmid, $deviceid);
        qemu_drivedel($vmid, $deviceid);
	qemu_deletescsihw($conf, $vmid, $deviceid);

    } elsif ($deviceid =~ m/^(net)(\d+)$/) {

        qemu_devicedel($vmid, $deviceid);
        qemu_devicedelverify($vmid, $deviceid);
        qemu_netdevdel($vmid, $deviceid);

    } else {
	die "can't unplug device '$deviceid'\n";
    }

    return 1;
}

sub qemu_deviceadd {
    my ($vmid, $devicefull) = @_;

    $devicefull = "driver=".$devicefull;
    my %options =  split(/[=,]/, $devicefull);

    vm_mon_cmd($vmid, "device_add" , %options);
}

sub qemu_devicedel {
    my ($vmid, $deviceid) = @_;

    my $ret = vm_mon_cmd($vmid, "device_del", id => $deviceid);
}

sub qemu_iothread_add {
    my($vmid, $deviceid, $device) = @_;

    if ($device->{iothread}) {
	my $iothreads = vm_iothreads_list($vmid);
	qemu_objectadd($vmid, "iothread-$deviceid", "iothread") if !$iothreads->{"iothread-$deviceid"};
    }
}

sub qemu_iothread_del {
    my($conf, $vmid, $deviceid) = @_;

    my $confid = $deviceid;
    if ($deviceid =~ m/^(?:virtioscsi|scsihw)(\d+)$/) {
	$confid = 'scsi' . $1;
    }
    my $device = parse_drive($confid, $conf->{$confid});
    if ($device->{iothread}) {
	my $iothreads = vm_iothreads_list($vmid);
	qemu_objectdel($vmid, "iothread-$deviceid") if $iothreads->{"iothread-$deviceid"};
    }
}

sub qemu_objectadd {
    my($vmid, $objectid, $qomtype) = @_;

    vm_mon_cmd($vmid, "object-add", id => $objectid, "qom-type" => $qomtype);

    return 1;
}

sub qemu_objectdel {
    my($vmid, $objectid) = @_;

    vm_mon_cmd($vmid, "object-del", id => $objectid);

    return 1;
}

sub qemu_driveadd {
    my ($storecfg, $vmid, $device) = @_;

    my $drive = print_drive_full($storecfg, $vmid, $device);
    $drive =~ s/\\/\\\\/g;
    my $ret = vm_human_monitor_command($vmid, "drive_add auto \"$drive\"");

    # If the command succeeds qemu prints: "OK"
    return 1 if $ret =~ m/OK/s;

    die "adding drive failed: $ret\n";
}

sub qemu_drivedel {
    my($vmid, $deviceid) = @_;

    my $ret = vm_human_monitor_command($vmid, "drive_del drive-$deviceid");
    $ret =~ s/^\s+//;

    return 1 if $ret eq "";

    # NB: device not found errors mean the drive was auto-deleted and we ignore the error
    return 1 if $ret =~ m/Device \'.*?\' not found/s;

    die "deleting drive $deviceid failed : $ret\n";
}

sub qemu_deviceaddverify {
    my ($vmid, $deviceid) = @_;

    for (my $i = 0; $i <= 5; $i++) {
         my $devices_list = vm_devices_list($vmid);
         return 1 if defined($devices_list->{$deviceid});
         sleep 1;
    }

    die "error on hotplug device '$deviceid'\n";
}


sub qemu_devicedelverify {
    my ($vmid, $deviceid) = @_;

    # need to verify that the device is correctly removed as device_del
    # is async and empty return is not reliable

    for (my $i = 0; $i <= 5; $i++) {
         my $devices_list = vm_devices_list($vmid);
         return 1 if !defined($devices_list->{$deviceid});
         sleep 1;
    }

    die "error on hot-unplugging device '$deviceid'\n";
}

sub qemu_findorcreatescsihw {
    my ($storecfg, $conf, $vmid, $device, $arch, $machine_type) = @_;

    my ($maxdev, $controller, $controller_prefix) = scsihw_infos($conf, $device);

    my $scsihwid="$controller_prefix$controller";
    my $devices_list = vm_devices_list($vmid);

    if(!defined($devices_list->{$scsihwid})) {
	vm_deviceplug($storecfg, $conf, $vmid, $scsihwid, $device, $arch, $machine_type);
    }

    return 1;
}

sub qemu_deletescsihw {
    my ($conf, $vmid, $opt) = @_;

    my $device = parse_drive($opt, $conf->{$opt});

    if ($conf->{scsihw} && ($conf->{scsihw} eq 'virtio-scsi-single')) {
	vm_deviceunplug($vmid, $conf, "virtioscsi$device->{index}");
	return 1;
    }

    my ($maxdev, $controller, $controller_prefix) = scsihw_infos($conf, $device);

    my $devices_list = vm_devices_list($vmid);
    foreach my $opt (keys %{$devices_list}) {
	if (PVE::QemuServer::is_valid_drivename($opt)) {
	    my $drive = PVE::QemuServer::parse_drive($opt, $conf->{$opt});
	    if($drive->{interface} eq 'scsi' && $drive->{index} < (($maxdev-1)*($controller+1))) {
		return 1;
	    }
	}
    }

    my $scsihwid="scsihw$controller";

    vm_deviceunplug($vmid, $conf, $scsihwid);

    return 1;
}

sub qemu_add_pci_bridge {
    my ($storecfg, $conf, $vmid, $device, $arch, $machine_type) = @_;

    my $bridges = {};

    my $bridgeid;

    print_pci_addr($device, $bridges, $arch, $machine_type);

    while (my ($k, $v) = each %$bridges) {
	$bridgeid = $k;
    }
    return 1 if !defined($bridgeid) || $bridgeid < 1;

    my $bridge = "pci.$bridgeid";
    my $devices_list = vm_devices_list($vmid);

    if (!defined($devices_list->{$bridge})) {
	vm_deviceplug($storecfg, $conf, $vmid, $bridge, $arch, $machine_type);
    }

    return 1;
}

sub qemu_set_link_status {
    my ($vmid, $device, $up) = @_;

    vm_mon_cmd($vmid, "set_link", name => $device,
	       up => $up ? JSON::true : JSON::false);
}

sub qemu_netdevadd {
    my ($vmid, $conf, $arch, $device, $deviceid) = @_;

    my $netdev = print_netdev_full($vmid, $conf, $arch, $device, $deviceid, 1);
    my %options =  split(/[=,]/, $netdev);

    vm_mon_cmd($vmid, "netdev_add",  %options);
    return 1;
}

sub qemu_netdevdel {
    my ($vmid, $deviceid) = @_;

    vm_mon_cmd($vmid, "netdev_del", id => $deviceid);
}

sub qemu_usb_hotplug {
    my ($storecfg, $conf, $vmid, $deviceid, $device, $arch, $machine_type) = @_;

    return if !$device;

    # remove the old one first
    vm_deviceunplug($vmid, $conf, $deviceid);

    # check if xhci controller is necessary and available
    if ($device->{usb3}) {

	my $devicelist = vm_devices_list($vmid);

	if (!$devicelist->{xhci}) {
	    my $pciaddr = print_pci_addr("xhci", undef, $arch, $machine_type);
	    qemu_deviceadd($vmid, "nec-usb-xhci,id=xhci$pciaddr");
	}
    }
    my $d = parse_usb_device($device->{host});
    $d->{usb3} = $device->{usb3};

    # add the new one
    vm_deviceplug($storecfg, $conf, $vmid, $deviceid, $d, $arch, $machine_type);
}

sub qemu_cpu_hotplug {
    my ($vmid, $conf, $vcpus) = @_;

    my $machine_type = PVE::QemuServer::get_current_qemu_machine($vmid);

    my $sockets = 1;
    $sockets = $conf->{smp} if $conf->{smp}; # old style - no longer iused
    $sockets = $conf->{sockets} if  $conf->{sockets};
    my $cores = $conf->{cores} || 1;
    my $maxcpus = $sockets * $cores;

    $vcpus = $maxcpus if !$vcpus;

    die "you can't add more vcpus than maxcpus\n"
	if $vcpus > $maxcpus;

    my $currentvcpus = $conf->{vcpus} || $maxcpus;

    if ($vcpus < $currentvcpus) {

	if (qemu_machine_feature_enabled ($machine_type, undef, 2, 7)) {

	    for (my $i = $currentvcpus; $i > $vcpus; $i--) {
		qemu_devicedel($vmid, "cpu$i");
		my $retry = 0;
		my $currentrunningvcpus = undef;
		while (1) {
		    $currentrunningvcpus = vm_mon_cmd($vmid, "query-cpus");
		    last if scalar(@{$currentrunningvcpus}) == $i-1;
		    raise_param_exc({ vcpus => "error unplugging cpu$i" }) if $retry > 5;
		    $retry++;
		    sleep 1;
		}
		#update conf after each succesfull cpu unplug
		$conf->{vcpus} = scalar(@{$currentrunningvcpus});
		PVE::QemuConfig->write_config($vmid, $conf);
	    }
	} else {
	    die "cpu hot-unplugging requires qemu version 2.7 or higher\n";
	}

	return;
    }

    my $currentrunningvcpus = vm_mon_cmd($vmid, "query-cpus");
    die "vcpus in running vm does not match its configuration\n"
	if scalar(@{$currentrunningvcpus}) != $currentvcpus;

    if (qemu_machine_feature_enabled ($machine_type, undef, 2, 7)) {

	for (my $i = $currentvcpus+1; $i <= $vcpus; $i++) {
	    my $cpustr = print_cpu_device($conf, $i);
	    qemu_deviceadd($vmid, $cpustr);

	    my $retry = 0;
	    my $currentrunningvcpus = undef;
	    while (1) {
		$currentrunningvcpus = vm_mon_cmd($vmid, "query-cpus");
		last if scalar(@{$currentrunningvcpus}) == $i;
		raise_param_exc({ vcpus => "error hotplugging cpu$i" }) if $retry > 10;
		sleep 1;
		$retry++;
	    }
            #update conf after each succesfull cpu hotplug
	    $conf->{vcpus} = scalar(@{$currentrunningvcpus});
	    PVE::QemuConfig->write_config($vmid, $conf);
	}
    } else {

	for (my $i = $currentvcpus; $i < $vcpus; $i++) {
	    vm_mon_cmd($vmid, "cpu-add", id => int($i));
	}
    }
}

sub qemu_block_set_io_throttle {
    my ($vmid, $deviceid,
	$bps, $bps_rd, $bps_wr, $iops, $iops_rd, $iops_wr,
	$bps_max, $bps_rd_max, $bps_wr_max, $iops_max, $iops_rd_max, $iops_wr_max,
	$bps_max_length, $bps_rd_max_length, $bps_wr_max_length,
	$iops_max_length, $iops_rd_max_length, $iops_wr_max_length) = @_;

    return if !check_running($vmid) ;

    vm_mon_cmd($vmid, "block_set_io_throttle", device => $deviceid,
	bps => int($bps),
	bps_rd => int($bps_rd),
	bps_wr => int($bps_wr),
	iops => int($iops),
	iops_rd => int($iops_rd),
	iops_wr => int($iops_wr),
	bps_max => int($bps_max),
	bps_rd_max => int($bps_rd_max),
	bps_wr_max => int($bps_wr_max),
	iops_max => int($iops_max),
	iops_rd_max => int($iops_rd_max),
	iops_wr_max => int($iops_wr_max),
	bps_max_length => int($bps_max_length),
	bps_rd_max_length => int($bps_rd_max_length),
	bps_wr_max_length => int($bps_wr_max_length),
	iops_max_length => int($iops_max_length),
	iops_rd_max_length => int($iops_rd_max_length),
	iops_wr_max_length => int($iops_wr_max_length),
    );

}

# old code, only used to shutdown old VM after update
sub __read_avail {
    my ($fh, $timeout) = @_;

    my $sel = new IO::Select;
    $sel->add($fh);

    my $res = '';
    my $buf;

    my @ready;
    while (scalar (@ready = $sel->can_read($timeout))) {
	my $count;
	if ($count = $fh->sysread($buf, 8192)) {
	    if ($buf =~ /^(.*)\(qemu\) $/s) {
		$res .= $1;
		last;
	    } else {
		$res .= $buf;
	    }
	} else {
	    if (!defined($count)) {
		die "$!\n";
	    }
	    last;
	}
    }

    die "monitor read timeout\n" if !scalar(@ready);

    return $res;
}

sub qemu_block_resize {
    my ($vmid, $deviceid, $storecfg, $volid, $size) = @_;

    my $running = check_running($vmid);

    $size = 0 if !PVE::Storage::volume_resize($storecfg, $volid, $size, $running);

    return if !$running;

    vm_mon_cmd($vmid, "block_resize", device => $deviceid, size => int($size));

}

sub qemu_volume_snapshot {
    my ($vmid, $deviceid, $storecfg, $volid, $snap) = @_;

    my $running = check_running($vmid);

    if ($running && do_snapshots_with_qemu($storecfg, $volid)){
	vm_mon_cmd($vmid, 'blockdev-snapshot-internal-sync', device => $deviceid, name => $snap);
    } else {
	PVE::Storage::volume_snapshot($storecfg, $volid, $snap);
    }
}

sub qemu_volume_snapshot_delete {
    my ($vmid, $deviceid, $storecfg, $volid, $snap) = @_;

    my $running = check_running($vmid);

    if($running) {

	$running = undef;
	my $conf = PVE::QemuConfig->load_config($vmid);
	foreach_drive($conf, sub {
	    my ($ds, $drive) = @_;
	    $running = 1 if $drive->{file} eq $volid;
	});
    }

    if ($running && do_snapshots_with_qemu($storecfg, $volid)){
	vm_mon_cmd($vmid, 'blockdev-snapshot-delete-internal-sync', device => $deviceid, name => $snap);
    } else {
	PVE::Storage::volume_snapshot_delete($storecfg, $volid, $snap, $running);
    }
}

sub set_migration_caps {
    my ($vmid) = @_;

    my $cap_ref = [];

    my $enabled_cap = {
	"auto-converge" => 1,
	"xbzrle" => 1,
	"x-rdma-pin-all" => 0,
	"zero-blocks" => 0,
	"compress" => 0
    };

    my $supported_capabilities = vm_mon_cmd_nocheck($vmid, "query-migrate-capabilities");

    for my $supported_capability (@$supported_capabilities) {
	push @$cap_ref, {
	    capability => $supported_capability->{capability},
	    state => $enabled_cap->{$supported_capability->{capability}} ? JSON::true : JSON::false,
	};
    }

    vm_mon_cmd_nocheck($vmid, "migrate-set-capabilities", capabilities => $cap_ref);
}

my $fast_plug_option = {
    'lock' => 1,
    'name' => 1,
    'onboot' => 1,
    'shares' => 1,
    'startup' => 1,
    'description' => 1,
    'protection' => 1,
    'vmstatestorage' => 1,
    'hookscript' => 1,
};

# hotplug changes in [PENDING]
# $selection hash can be used to only apply specified options, for
# example: { cores => 1 } (only apply changed 'cores')
# $errors ref is used to return error messages
sub vmconfig_hotplug_pending {
    my ($vmid, $conf, $storecfg, $selection, $errors) = @_;

    my $defaults = load_defaults();
    my ($arch, $machine_type) = get_basic_machine_info($conf, undef);

    # commit values which do not have any impact on running VM first
    # Note: those option cannot raise errors, we we do not care about
    # $selection and always apply them.

    my $add_error = sub {
	my ($opt, $msg) = @_;
	$errors->{$opt} = "hotplug problem - $msg";
    };

    my $changes = 0;
    foreach my $opt (keys %{$conf->{pending}}) { # add/change
	if ($fast_plug_option->{$opt}) {
	    $conf->{$opt} = $conf->{pending}->{$opt};
	    delete $conf->{pending}->{$opt};
	    $changes = 1;
	}
    }

    if ($changes) {
	PVE::QemuConfig->write_config($vmid, $conf);
	$conf = PVE::QemuConfig->load_config($vmid); # update/reload
    }

    my $hotplug_features = parse_hotplug_features(defined($conf->{hotplug}) ? $conf->{hotplug} : '1');

    my $pending_delete_hash = split_flagged_list($conf->{pending}->{delete});
    while (my ($opt, $force) = each %$pending_delete_hash) {
	next if $selection && !$selection->{$opt};
	eval {
	    if ($opt eq 'hotplug') {
		die "skip\n" if ($conf->{hotplug} =~ /memory/);
	    } elsif ($opt eq 'tablet') {
		die "skip\n" if !$hotplug_features->{usb};
		if ($defaults->{tablet}) {
		    vm_deviceplug($storecfg, $conf, $vmid, 'tablet', $arch, $machine_type);
		    vm_deviceplug($storecfg, $conf, $vmid, 'keyboard', $arch, $machine_type)
			if $arch eq 'aarch64';
		} else {
		    vm_deviceunplug($vmid, $conf, 'tablet');
		    vm_deviceunplug($vmid, $conf, 'keyboard') if $arch eq 'aarch64';
		}
	    } elsif ($opt =~ m/^usb\d+/) {
		die "skip\n";
		# since we cannot reliably hot unplug usb devices
		# we are disabling it
		die "skip\n" if !$hotplug_features->{usb} || $conf->{$opt} =~ m/spice/i;
		vm_deviceunplug($vmid, $conf, $opt);
	    } elsif ($opt eq 'vcpus') {
		die "skip\n" if !$hotplug_features->{cpu};
		qemu_cpu_hotplug($vmid, $conf, undef);
            } elsif ($opt eq 'balloon') {
		# enable balloon device is not hotpluggable
		die "skip\n" if defined($conf->{balloon}) && $conf->{balloon} == 0;
		# here we reset the ballooning value to memory
		my $balloon = $conf->{memory} || $defaults->{memory};
		vm_mon_cmd($vmid, "balloon", value => $balloon*1024*1024);
	    } elsif ($fast_plug_option->{$opt}) {
		# do nothing
	    } elsif ($opt =~ m/^net(\d+)$/) {
		die "skip\n" if !$hotplug_features->{network};
		vm_deviceunplug($vmid, $conf, $opt);
	    } elsif (is_valid_drivename($opt)) {
		die "skip\n" if !$hotplug_features->{disk} || $opt =~ m/(ide|sata)(\d+)/;
		vm_deviceunplug($vmid, $conf, $opt);
		vmconfig_delete_or_detach_drive($vmid, $storecfg, $conf, $opt, $force);
	    } elsif ($opt =~ m/^memory$/) {
		die "skip\n" if !$hotplug_features->{memory};
		PVE::QemuServer::Memory::qemu_memory_hotplug($vmid, $conf, $defaults, $opt);
	    } elsif ($opt eq 'cpuunits') {
		cgroups_write("cpu", $vmid, "cpu.shares", $defaults->{cpuunits});
	    } elsif ($opt eq 'cpulimit') {
		cgroups_write("cpu", $vmid, "cpu.cfs_quota_us", -1);
	    } else {
		die "skip\n";
	    }
	};
	if (my $err = $@) {
	    &$add_error($opt, $err) if $err ne "skip\n";
	} else {
	    # save new config if hotplug was successful
	    delete $conf->{$opt};
	    vmconfig_undelete_pending_option($conf, $opt);
	    PVE::QemuConfig->write_config($vmid, $conf);
	    $conf = PVE::QemuConfig->load_config($vmid); # update/reload
	}
    }

    my $apply_pending_cloudinit;
    $apply_pending_cloudinit = sub {
	my ($key, $value) = @_;
	$apply_pending_cloudinit = sub {}; # once is enough

	my @cloudinit_opts = keys %$confdesc_cloudinit;
	foreach my $opt (keys %{$conf->{pending}}) {
	    next if !grep { $_ eq $opt } @cloudinit_opts;
	    $conf->{$opt} = delete $conf->{pending}->{$opt};
	}

	my $new_conf = { %$conf };
	$new_conf->{$key} = $value;
	PVE::QemuServer::Cloudinit::generate_cloudinitconfig($new_conf, $vmid);
    };

    foreach my $opt (keys %{$conf->{pending}}) {
	next if $selection && !$selection->{$opt};
	my $value = $conf->{pending}->{$opt};
	eval {
	    if ($opt eq 'hotplug') {
		die "skip\n" if ($value =~ /memory/) || ($value !~ /memory/ && $conf->{hotplug} =~ /memory/);
	    } elsif ($opt eq 'tablet') {
		die "skip\n" if !$hotplug_features->{usb};
		if ($value == 1) {
		    vm_deviceplug($storecfg, $conf, $vmid, 'tablet', $arch, $machine_type);
		    vm_deviceplug($storecfg, $conf, $vmid, 'keyboard', $arch, $machine_type)
			if $arch eq 'aarch64';
		} elsif ($value == 0) {
		    vm_deviceunplug($vmid, $conf, 'tablet');
		    vm_deviceunplug($vmid, $conf, 'keyboard') if $arch eq 'aarch64';
		}
	    } elsif ($opt =~ m/^usb\d+$/) {
		die "skip\n";
		# since we cannot reliably hot unplug usb devices
		# we are disabling it
		die "skip\n" if !$hotplug_features->{usb} || $value =~ m/spice/i;
		my $d = eval { PVE::JSONSchema::parse_property_string($usbdesc->{format}, $value) };
		die "skip\n" if !$d;
		qemu_usb_hotplug($storecfg, $conf, $vmid, $opt, $d, $arch, $machine_type);
	    } elsif ($opt eq 'vcpus') {
		die "skip\n" if !$hotplug_features->{cpu};
		qemu_cpu_hotplug($vmid, $conf, $value);
	    } elsif ($opt eq 'balloon') {
		# enable/disable balloning device is not hotpluggable
		my $old_balloon_enabled =  !!(!defined($conf->{balloon}) || $conf->{balloon});
		my $new_balloon_enabled =  !!(!defined($conf->{pending}->{balloon}) || $conf->{pending}->{balloon});
		die "skip\n" if $old_balloon_enabled != $new_balloon_enabled;

		# allow manual ballooning if shares is set to zero
		if ((defined($conf->{shares}) && ($conf->{shares} == 0))) {
		    my $balloon = $conf->{pending}->{balloon} || $conf->{memory} || $defaults->{memory};
		    vm_mon_cmd($vmid, "balloon", value => $balloon*1024*1024);
		}
	    } elsif ($opt =~ m/^net(\d+)$/) {
		# some changes can be done without hotplug
		vmconfig_update_net($storecfg, $conf, $hotplug_features->{network},
				    $vmid, $opt, $value, $arch, $machine_type);
	    } elsif (is_valid_drivename($opt)) {
		# some changes can be done without hotplug
		my $drive = parse_drive($opt, $value);
		if (drive_is_cloudinit($drive)) {
		    &$apply_pending_cloudinit($opt, $value);
		}
		vmconfig_update_disk($storecfg, $conf, $hotplug_features->{disk},
				     $vmid, $opt, $value, 1, $arch, $machine_type);
	    } elsif ($opt =~ m/^memory$/) { #dimms
		die "skip\n" if !$hotplug_features->{memory};
		$value = PVE::QemuServer::Memory::qemu_memory_hotplug($vmid, $conf, $defaults, $opt, $value);
	    } elsif ($opt eq 'cpuunits') {
		cgroups_write("cpu", $vmid, "cpu.shares", $conf->{pending}->{$opt});
	    } elsif ($opt eq 'cpulimit') {
		my $cpulimit = $conf->{pending}->{$opt} == 0 ? -1 : int($conf->{pending}->{$opt} * 100000);
		cgroups_write("cpu", $vmid, "cpu.cfs_quota_us", $cpulimit);
	    } else {
		die "skip\n";  # skip non-hot-pluggable options
	    }
	};
	if (my $err = $@) {
	    &$add_error($opt, $err) if $err ne "skip\n";
	} else {
	    # save new config if hotplug was successful
	    $conf->{$opt} = $value;
	    delete $conf->{pending}->{$opt};
	    PVE::QemuConfig->write_config($vmid, $conf);
	    $conf = PVE::QemuConfig->load_config($vmid); # update/reload
	}
    }
}

sub try_deallocate_drive {
    my ($storecfg, $vmid, $conf, $key, $drive, $rpcenv, $authuser, $force) = @_;

    if (($force || $key =~ /^unused/) && !drive_is_cdrom($drive, 1)) {
	my $volid = $drive->{file};
	if (vm_is_volid_owner($storecfg, $vmid, $volid)) {
	    my $sid = PVE::Storage::parse_volume_id($volid);
	    $rpcenv->check($authuser, "/storage/$sid", ['Datastore.AllocateSpace']);

	    # check if the disk is really unused
	    die "unable to delete '$volid' - volume is still in use (snapshot?)\n"
		if is_volume_in_use($storecfg, $conf, $key, $volid);
	    PVE::Storage::vdisk_free($storecfg, $volid);
	    return 1;
	} else {
	    # If vm is not owner of this disk remove from config
	    return 1;
	}
    }

    return undef;
}

sub vmconfig_delete_or_detach_drive {
    my ($vmid, $storecfg, $conf, $opt, $force) = @_;

    my $drive = parse_drive($opt, $conf->{$opt});

    my $rpcenv = PVE::RPCEnvironment::get();
    my $authuser = $rpcenv->get_user();

    if ($force) {
	$rpcenv->check_vm_perm($authuser, $vmid, undef, ['VM.Config.Disk']);
	try_deallocate_drive($storecfg, $vmid, $conf, $opt, $drive, $rpcenv, $authuser, $force);
    } else {
	vmconfig_register_unused_drive($storecfg, $vmid, $conf, $drive);
    }
}

sub vmconfig_apply_pending {
    my ($vmid, $conf, $storecfg) = @_;

    # cold plug

    my $pending_delete_hash = split_flagged_list($conf->{pending}->{delete});
    while (my ($opt, $force) = each %$pending_delete_hash) {
	die "internal error" if $opt =~ m/^unused/;
	$conf = PVE::QemuConfig->load_config($vmid); # update/reload
	if (!defined($conf->{$opt})) {
	    vmconfig_undelete_pending_option($conf, $opt);
	    PVE::QemuConfig->write_config($vmid, $conf);
	} elsif (is_valid_drivename($opt)) {
	    vmconfig_delete_or_detach_drive($vmid, $storecfg, $conf, $opt, $force);
	    vmconfig_undelete_pending_option($conf, $opt);
	    delete $conf->{$opt};
	    PVE::QemuConfig->write_config($vmid, $conf);
	} else {
	    vmconfig_undelete_pending_option($conf, $opt);
	    delete $conf->{$opt};
	    PVE::QemuConfig->write_config($vmid, $conf);
	}
    }

    $conf = PVE::QemuConfig->load_config($vmid); # update/reload

    foreach my $opt (keys %{$conf->{pending}}) { # add/change
	$conf = PVE::QemuConfig->load_config($vmid); # update/reload

	if (defined($conf->{$opt}) && ($conf->{$opt} eq $conf->{pending}->{$opt})) {
	    # skip if nothing changed
	} elsif (is_valid_drivename($opt)) {
	    vmconfig_register_unused_drive($storecfg, $vmid, $conf, parse_drive($opt, $conf->{$opt}))
		if defined($conf->{$opt});
	    $conf->{$opt} = $conf->{pending}->{$opt};
	} else {
	    $conf->{$opt} = $conf->{pending}->{$opt};
	}

	delete $conf->{pending}->{$opt};
	PVE::QemuConfig->write_config($vmid, $conf);
    }
}

my $safe_num_ne = sub {
    my ($a, $b) = @_;

    return 0 if !defined($a) && !defined($b);
    return 1 if !defined($a);
    return 1 if !defined($b);

    return $a != $b;
};

my $safe_string_ne = sub {
    my ($a, $b) = @_;

    return 0 if !defined($a) && !defined($b);
    return 1 if !defined($a);
    return 1 if !defined($b);

    return $a ne $b;
};

sub vmconfig_update_net {
    my ($storecfg, $conf, $hotplug, $vmid, $opt, $value, $arch, $machine_type) = @_;

    my $newnet = parse_net($value);

    if ($conf->{$opt}) {
	my $oldnet = parse_net($conf->{$opt});

	if (&$safe_string_ne($oldnet->{model}, $newnet->{model}) ||
	    &$safe_string_ne($oldnet->{macaddr}, $newnet->{macaddr}) ||
	    &$safe_num_ne($oldnet->{queues}, $newnet->{queues}) ||
	    !($newnet->{bridge} && $oldnet->{bridge})) { # bridge/nat mode change

            # for non online change, we try to hot-unplug
	    die "skip\n" if !$hotplug;
	    vm_deviceunplug($vmid, $conf, $opt);
	} else {

	    die "internal error" if $opt !~ m/net(\d+)/;
	    my $iface = "tap${vmid}i$1";

	    if (&$safe_string_ne($oldnet->{bridge}, $newnet->{bridge}) ||
		&$safe_num_ne($oldnet->{tag}, $newnet->{tag}) ||
		&$safe_string_ne($oldnet->{trunks}, $newnet->{trunks}) ||
		&$safe_num_ne($oldnet->{firewall}, $newnet->{firewall})) {
		PVE::Network::tap_unplug($iface);
		PVE::Network::tap_plug($iface, $newnet->{bridge}, $newnet->{tag}, $newnet->{firewall}, $newnet->{trunks}, $newnet->{rate});
	    } elsif (&$safe_num_ne($oldnet->{rate}, $newnet->{rate})) {
		# Rate can be applied on its own but any change above needs to
		# include the rate in tap_plug since OVS resets everything.
		PVE::Network::tap_rate_limit($iface, $newnet->{rate});
	    }

	    if (&$safe_string_ne($oldnet->{link_down}, $newnet->{link_down})) {
		qemu_set_link_status($vmid, $opt, !$newnet->{link_down});
	    }

	    return 1;
	}
    }

    if ($hotplug) {
	vm_deviceplug($storecfg, $conf, $vmid, $opt, $newnet, $arch, $machine_type);
    } else {
	die "skip\n";
    }
}

sub vmconfig_update_disk {
    my ($storecfg, $conf, $hotplug, $vmid, $opt, $value, $force, $arch, $machine_type) = @_;

    # fixme: do we need force?

    my $drive = parse_drive($opt, $value);

    if ($conf->{$opt}) {

	if (my $old_drive = parse_drive($opt, $conf->{$opt}))  {

	    my $media = $drive->{media} || 'disk';
	    my $oldmedia = $old_drive->{media} || 'disk';
	    die "unable to change media type\n" if $media ne $oldmedia;

	    if (!drive_is_cdrom($old_drive)) {

		if ($drive->{file} ne $old_drive->{file}) {

		    die "skip\n" if !$hotplug;

		    # unplug and register as unused
		    vm_deviceunplug($vmid, $conf, $opt);
		    vmconfig_register_unused_drive($storecfg, $vmid, $conf, $old_drive)

		} else {
		    # update existing disk

		    # skip non hotpluggable value
		    if (&$safe_string_ne($drive->{discard}, $old_drive->{discard}) ||
			&$safe_string_ne($drive->{iothread}, $old_drive->{iothread}) ||
			&$safe_string_ne($drive->{queues}, $old_drive->{queues}) ||
			&$safe_string_ne($drive->{cache}, $old_drive->{cache})) {
			die "skip\n";
		    }

		    # apply throttle
		    if (&$safe_num_ne($drive->{mbps}, $old_drive->{mbps}) ||
			&$safe_num_ne($drive->{mbps_rd}, $old_drive->{mbps_rd}) ||
			&$safe_num_ne($drive->{mbps_wr}, $old_drive->{mbps_wr}) ||
			&$safe_num_ne($drive->{iops}, $old_drive->{iops}) ||
			&$safe_num_ne($drive->{iops_rd}, $old_drive->{iops_rd}) ||
			&$safe_num_ne($drive->{iops_wr}, $old_drive->{iops_wr}) ||
			&$safe_num_ne($drive->{mbps_max}, $old_drive->{mbps_max}) ||
			&$safe_num_ne($drive->{mbps_rd_max}, $old_drive->{mbps_rd_max}) ||
			&$safe_num_ne($drive->{mbps_wr_max}, $old_drive->{mbps_wr_max}) ||
			&$safe_num_ne($drive->{iops_max}, $old_drive->{iops_max}) ||
			&$safe_num_ne($drive->{iops_rd_max}, $old_drive->{iops_rd_max}) ||
			&$safe_num_ne($drive->{iops_wr_max}, $old_drive->{iops_wr_max}) ||
			&$safe_num_ne($drive->{bps_max_length}, $old_drive->{bps_max_length}) ||
			&$safe_num_ne($drive->{bps_rd_max_length}, $old_drive->{bps_rd_max_length}) ||
			&$safe_num_ne($drive->{bps_wr_max_length}, $old_drive->{bps_wr_max_length}) ||
			&$safe_num_ne($drive->{iops_max_length}, $old_drive->{iops_max_length}) ||
			&$safe_num_ne($drive->{iops_rd_max_length}, $old_drive->{iops_rd_max_length}) ||
			&$safe_num_ne($drive->{iops_wr_max_length}, $old_drive->{iops_wr_max_length})) {

			qemu_block_set_io_throttle($vmid,"drive-$opt",
						   ($drive->{mbps} || 0)*1024*1024,
						   ($drive->{mbps_rd} || 0)*1024*1024,
						   ($drive->{mbps_wr} || 0)*1024*1024,
						   $drive->{iops} || 0,
						   $drive->{iops_rd} || 0,
						   $drive->{iops_wr} || 0,
						   ($drive->{mbps_max} || 0)*1024*1024,
						   ($drive->{mbps_rd_max} || 0)*1024*1024,
						   ($drive->{mbps_wr_max} || 0)*1024*1024,
						   $drive->{iops_max} || 0,
						   $drive->{iops_rd_max} || 0,
						   $drive->{iops_wr_max} || 0,
						   $drive->{bps_max_length} || 1,
						   $drive->{bps_rd_max_length} || 1,
						   $drive->{bps_wr_max_length} || 1,
						   $drive->{iops_max_length} || 1,
						   $drive->{iops_rd_max_length} || 1,
						   $drive->{iops_wr_max_length} || 1);

		    }

		    return 1;
	        }

	    } else { # cdrom

		if ($drive->{file} eq 'none') {
		    vm_mon_cmd($vmid, "eject",force => JSON::true,device => "drive-$opt");
		    if (drive_is_cloudinit($old_drive)) {
			vmconfig_register_unused_drive($storecfg, $vmid, $conf, $old_drive);
		    }
		} else {
		    my $path = get_iso_path($storecfg, $vmid, $drive->{file});
		    vm_mon_cmd($vmid, "eject", force => JSON::true,device => "drive-$opt"); # force eject if locked
		    vm_mon_cmd($vmid, "change", device => "drive-$opt",target => "$path") if $path;
		}

		return 1;
	    }
	}
    }

    die "skip\n" if !$hotplug || $opt =~ m/(ide|sata)(\d+)/;
    # hotplug new disks
    PVE::Storage::activate_volumes($storecfg, [$drive->{file}]) if $drive->{file} !~ m|^/dev/.+|;
    vm_deviceplug($storecfg, $conf, $vmid, $opt, $drive, $arch, $machine_type);
}

sub vm_start {
    my ($storecfg, $vmid, $statefile, $skiplock, $migratedfrom, $paused,
	$forcemachine, $spice_ticket, $migration_network, $migration_type, $targetstorage) = @_;

    PVE::QemuConfig->lock_config($vmid, sub {
	my $conf = PVE::QemuConfig->load_config($vmid, $migratedfrom);

	die "you can't start a vm if it's a template\n" if PVE::QemuConfig->is_template($conf);

	my $is_suspended = PVE::QemuConfig->has_lock($conf, 'suspended');

	PVE::QemuConfig->check_lock($conf)
	    if !($skiplock || $is_suspended);

	die "VM $vmid already running\n" if check_running($vmid, undef, $migratedfrom);

	if (!$statefile && scalar(keys %{$conf->{pending}})) {
	    vmconfig_apply_pending($vmid, $conf, $storecfg);
	    $conf = PVE::QemuConfig->load_config($vmid); # update/reload
	}

	PVE::QemuServer::Cloudinit::generate_cloudinitconfig($conf, $vmid);

	my $defaults = load_defaults();

	# set environment variable useful inside network script
	$ENV{PVE_MIGRATED_FROM} = $migratedfrom if $migratedfrom;

	my $local_volumes = {};

	if ($targetstorage) {
	    foreach_drive($conf, sub {
		my ($ds, $drive) = @_;

		return if drive_is_cdrom($drive);

		my $volid = $drive->{file};

		return if !$volid;

		my ($storeid, $volname) = PVE::Storage::parse_volume_id($volid);

		my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
		return if $scfg->{shared};
		$local_volumes->{$ds} = [$volid, $storeid, $volname];
	    });

	    my $format = undef;

	    foreach my $opt (sort keys %$local_volumes) {

		my ($volid, $storeid, $volname) = @{$local_volumes->{$opt}};
		my $drive = parse_drive($opt, $conf->{$opt});

		#if remote storage is specified, use default format
		if ($targetstorage && $targetstorage ne "1") {
		    $storeid = $targetstorage;
		    my ($defFormat, $validFormats) = PVE::Storage::storage_default_format($storecfg, $storeid);
		    $format = $defFormat;
		} else {
		    #else we use same format than original
		    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
		    $format = qemu_img_format($scfg, $volid);
		}

		my $newvolid = PVE::Storage::vdisk_alloc($storecfg, $storeid, $vmid, $format, undef, ($drive->{size}/1024));
		my $newdrive = $drive;
		$newdrive->{format} = $format;
		$newdrive->{file} = $newvolid;
		my $drivestr = PVE::QemuServer::print_drive($vmid, $newdrive);
		$local_volumes->{$opt} = $drivestr;
		#pass drive to conf for command line
		$conf->{$opt} = $drivestr;
	    }
	}

	PVE::GuestHelpers::exec_hookscript($conf, $vmid, 'pre-start', 1);

	if ($is_suspended) {
	    # enforce machine type on suspended vm to ensure HW compatibility
	    $forcemachine = $conf->{runningmachine};
	    print "Resuming suspended VM\n";
	}

	my ($cmd, $vollist, $spice_port) = config_to_command($storecfg, $vmid, $conf, $defaults, $forcemachine);

	my $migrate_port = 0;
	my $migrate_uri;
	if ($statefile) {
	    if ($statefile eq 'tcp') {
		my $localip = "localhost";
		my $datacenterconf = PVE::Cluster::cfs_read_file('datacenter.cfg');
		my $nodename = PVE::INotify::nodename();

		if (!defined($migration_type)) {
		    if (defined($datacenterconf->{migration}->{type})) {
			$migration_type = $datacenterconf->{migration}->{type};
		    } else {
			$migration_type = 'secure';
		    }
		}

		if ($migration_type eq 'insecure') {
		    my $migrate_network_addr = PVE::Cluster::get_local_migration_ip($migration_network);
		    if ($migrate_network_addr) {
			$localip = $migrate_network_addr;
		    } else {
			$localip = PVE::Cluster::remote_node_ip($nodename, 1);
		    }

		    $localip = "[$localip]" if Net::IP::ip_is_ipv6($localip);
		}

		my $pfamily = PVE::Tools::get_host_address_family($nodename);
		$migrate_port = PVE::Tools::next_migrate_port($pfamily);
		$migrate_uri = "tcp:${localip}:${migrate_port}";
		push @$cmd, '-incoming', $migrate_uri;
		push @$cmd, '-S';

	    } elsif ($statefile eq 'unix') {
		# should be default for secure migrations as a ssh TCP forward
		# tunnel is not deterministic reliable ready and fails regurarly
		# to set up in time, so use UNIX socket forwards
		my $socket_addr = "/run/qemu-server/$vmid.migrate";
		unlink $socket_addr;

		$migrate_uri = "unix:$socket_addr";

		push @$cmd, '-incoming', $migrate_uri;
		push @$cmd, '-S';

	    } else {
		push @$cmd, '-loadstate', $statefile;
	    }
	} elsif ($paused) {
	    push @$cmd, '-S';
	}

	# host pci devices
        for (my $i = 0; $i < $MAX_HOSTPCI_DEVICES; $i++)  {
          my $d = parse_hostpci($conf->{"hostpci$i"});
          next if !$d;
	  my $pcidevices = $d->{pciid};
	  foreach my $pcidevice (@$pcidevices) {
		my $pciid = $pcidevice->{id};

		my $info = PVE::SysFSTools::pci_device_info("0000:$pciid");
		die "IOMMU not present\n" if !PVE::SysFSTools::check_iommu_support();
		die "no pci device info for device '$pciid'\n" if !$info;

		if ($d->{mdev}) {
		    my $uuid = PVE::SysFSTools::generate_mdev_uuid($vmid, $i);
		    PVE::SysFSTools::pci_create_mdev_device($pciid, $uuid, $d->{mdev});
		} else {
		    die "can't unbind/bind pci group to vfio '$pciid'\n"
			if !PVE::SysFSTools::pci_dev_group_bind_to_vfio($pciid);
		    die "can't reset pci device '$pciid'\n"
			if $info->{has_fl_reset} and !PVE::SysFSTools::pci_dev_reset($info);
		}
	  }
        }

	PVE::Storage::activate_volumes($storecfg, $vollist);

	eval {
	    run_command(['/bin/systemctl', 'stop', "$vmid.scope"],
		outfunc => sub {}, errfunc => sub {});
	};
	# Issues with the above 'stop' not being fully completed are extremely rare, a very low
	# timeout should be more than enough here...
	PVE::Systemd::wait_for_unit_removed("$vmid.scope", 5);

	my $cpuunits = defined($conf->{cpuunits}) ? $conf->{cpuunits}
	                                          : $defaults->{cpuunits};

	my $start_timeout = ($conf->{hugepages} || $is_suspended) ? 300 : 30;
	my %run_params = (timeout => $statefile ? undef : $start_timeout, umask => 0077);

	my %properties = (
	    Slice => 'qemu.slice',
	    KillMode => 'none',
	    CPUShares => $cpuunits
	);

	if (my $cpulimit = $conf->{cpulimit}) {
	    $properties{CPUQuota} = int($cpulimit * 100);
	}
	$properties{timeout} = 10 if $statefile; # setting up the scope shoul be quick

	my $run_qemu = sub {
	    PVE::Tools::run_fork sub {
		PVE::Systemd::enter_systemd_scope($vmid, "Proxmox VE VM $vmid", %properties);
		run_command($cmd, %run_params);
	    };
	};

	if ($conf->{hugepages}) {

	    my $code = sub {
		my $hugepages_topology = PVE::QemuServer::Memory::hugepages_topology($conf);
		my $hugepages_host_topology = PVE::QemuServer::Memory::hugepages_host_topology();

		PVE::QemuServer::Memory::hugepages_mount();
		PVE::QemuServer::Memory::hugepages_allocate($hugepages_topology, $hugepages_host_topology);

		eval { $run_qemu->() };
		if (my $err = $@) {
		    PVE::QemuServer::Memory::hugepages_reset($hugepages_host_topology);
		    die $err;
		}

		PVE::QemuServer::Memory::hugepages_pre_deallocate($hugepages_topology);
	    };
	    eval { PVE::QemuServer::Memory::hugepages_update_locked($code); };

	} else {
	    eval { $run_qemu->() };
	}

	if (my $err = $@) {
	    # deactivate volumes if start fails
	    eval { PVE::Storage::deactivate_volumes($storecfg, $vollist); };
	    die "start failed: $err";
	}

	print "migration listens on $migrate_uri\n" if $migrate_uri;

	if ($statefile && $statefile ne 'tcp' && $statefile ne 'unix')  {
	    eval { vm_mon_cmd_nocheck($vmid, "cont"); };
	    warn $@ if $@;
	}

	#start nbd server for storage migration
	if ($targetstorage) {
	    my $nodename = PVE::INotify::nodename();
	    my $migrate_network_addr = PVE::Cluster::get_local_migration_ip($migration_network);
	    my $localip = $migrate_network_addr ? $migrate_network_addr : PVE::Cluster::remote_node_ip($nodename, 1);
	    my $pfamily = PVE::Tools::get_host_address_family($nodename);
	    $migrate_port = PVE::Tools::next_migrate_port($pfamily);

	    vm_mon_cmd_nocheck($vmid, "nbd-server-start", addr => { type => 'inet', data => { host => "${localip}", port => "${migrate_port}" } } );

	    $localip = "[$localip]" if Net::IP::ip_is_ipv6($localip);

	    foreach my $opt (sort keys %$local_volumes) {
		my $volid = $local_volumes->{$opt};
		vm_mon_cmd_nocheck($vmid, "nbd-server-add", device => "drive-$opt", writable => JSON::true );
		my $migrate_storage_uri = "nbd:${localip}:${migrate_port}:exportname=drive-$opt";
		print "storage migration listens on $migrate_storage_uri volume:$volid\n";
	    }
	}

	if ($migratedfrom) {
	    eval {
		set_migration_caps($vmid);
	    };
	    warn $@ if $@;

	    if ($spice_port) {
	        print "spice listens on port $spice_port\n";
		if ($spice_ticket) {
		    vm_mon_cmd_nocheck($vmid, "set_password", protocol => 'spice', password => $spice_ticket);
		    vm_mon_cmd_nocheck($vmid, "expire_password", protocol => 'spice', time => "+30");
		}
	    }

	} else {
	    vm_mon_cmd_nocheck($vmid, "balloon", value => $conf->{balloon}*1024*1024)
		if !$statefile && $conf->{balloon};

	    foreach my $opt (keys %$conf) {
		next if $opt !~  m/^net\d+$/;
		my $nicconf = parse_net($conf->{$opt});
		qemu_set_link_status($vmid, $opt, 0) if $nicconf->{link_down};
	    }
	}

	vm_mon_cmd_nocheck($vmid, 'qom-set',
		    path => "machine/peripheral/balloon0",
		    property => "guest-stats-polling-interval",
		    value => 2) if (!defined($conf->{balloon}) || $conf->{balloon});

	if ($is_suspended && (my $vmstate = $conf->{vmstate})) {
	    print "Resumed VM, removing state\n";
	    delete $conf->@{qw(lock vmstate runningmachine)};
	    PVE::Storage::deactivate_volumes($storecfg, [$vmstate]);
	    PVE::Storage::vdisk_free($storecfg, $vmstate);
	    PVE::QemuConfig->write_config($vmid, $conf);
	}

	PVE::GuestHelpers::exec_hookscript($conf, $vmid, 'post-start');
    });
}

sub vm_mon_cmd {
    my ($vmid, $execute, %params) = @_;

    my $cmd = { execute => $execute, arguments => \%params };
    vm_qmp_command($vmid, $cmd);
}

sub vm_mon_cmd_nocheck {
    my ($vmid, $execute, %params) = @_;

    my $cmd = { execute => $execute, arguments => \%params };
    vm_qmp_command($vmid, $cmd, 1);
}

sub vm_qmp_command {
    my ($vmid, $cmd, $nocheck) = @_;

    my $res;

    my $timeout;
    if ($cmd->{arguments}) {
	$timeout = delete $cmd->{arguments}->{timeout};
    }

    eval {
	die "VM $vmid not running\n" if !check_running($vmid, $nocheck);
	my $sname = qmp_socket($vmid);
	if (-e $sname) { # test if VM is reasonambe new and supports qmp/qga
	    my $qmpclient = PVE::QMPClient->new();

	    $res = $qmpclient->cmd($vmid, $cmd, $timeout);
	} else {
	    die "unable to open monitor socket\n";
	}
    };
    if (my $err = $@) {
	syslog("err", "VM $vmid qmp command failed - $err");
	die $err;
    }

    return $res;
}

sub vm_human_monitor_command {
    my ($vmid, $cmdline) = @_;

    my $cmd = {
	execute => 'human-monitor-command',
	arguments => { 'command-line' => $cmdline},
    };

    return vm_qmp_command($vmid, $cmd);
}

sub vm_commandline {
    my ($storecfg, $vmid, $snapname) = @_;

    my $conf = PVE::QemuConfig->load_config($vmid);

    if ($snapname) {
	my $snapshot = $conf->{snapshots}->{$snapname};
	die "snapshot '$snapname' does not exist\n" if !defined($snapshot);

	$snapshot->{digest} = $conf->{digest}; # keep file digest for API

	$conf = $snapshot;
    }

    my $defaults = load_defaults();

    my $cmd = config_to_command($storecfg, $vmid, $conf, $defaults);

    return PVE::Tools::cmd2string($cmd);
}

sub vm_reset {
    my ($vmid, $skiplock) = @_;

    PVE::QemuConfig->lock_config($vmid, sub {

	my $conf = PVE::QemuConfig->load_config($vmid);

	PVE::QemuConfig->check_lock($conf) if !$skiplock;

	vm_mon_cmd($vmid, "system_reset");
    });
}

sub get_vm_volumes {
    my ($conf) = @_;

    my $vollist = [];
    foreach_volid($conf, sub {
	my ($volid, $attr) = @_;

	return if $volid =~ m|^/|;

	my ($sid, $volname) = PVE::Storage::parse_volume_id($volid, 1);
	return if !$sid;

	push @$vollist, $volid;
    });

    return $vollist;
}

sub vm_stop_cleanup {
    my ($storecfg, $vmid, $conf, $keepActive, $apply_pending_changes) = @_;

    eval {

	if (!$keepActive) {
	    my $vollist = get_vm_volumes($conf);
	    PVE::Storage::deactivate_volumes($storecfg, $vollist);
	}

	foreach my $ext (qw(mon qmp pid vnc qga)) {
	    unlink "/var/run/qemu-server/${vmid}.$ext";
	}

	if ($conf->{ivshmem}) {
	    my $ivshmem = PVE::JSONSchema::parse_property_string($ivshmem_fmt, $conf->{ivshmem});
	    # just delete it for now, VMs which have this already open do not
	    # are affected, but new VMs will get a separated one. If this
	    # becomes an issue we either add some sort of ref-counting or just
	    # add a "don't delete on stop" flag to the ivshmem format.
	    unlink '/dev/shm/pve-shm-' . ($ivshmem->{name} // $vmid);
	}

	foreach my $key (keys %$conf) {
	    next if $key !~ m/^hostpci(\d+)$/;
	    my $hostpciindex = $1;
	    my $d = parse_hostpci($conf->{$key});
	    my $uuid = PVE::SysFSTools::generate_mdev_uuid($vmid, $hostpciindex);

	    foreach my $pci (@{$d->{pciid}}) {
		my $pciid = $pci->{id};
		PVE::SysFSTools::pci_cleanup_mdev_device($pciid, $uuid);
	    }
	}

	vmconfig_apply_pending($vmid, $conf, $storecfg) if $apply_pending_changes;
    };
    warn $@ if $@; # avoid errors - just warn
}

# Note: use $nockeck to skip tests if VM configuration file exists.
# We need that when migration VMs to other nodes (files already moved)
# Note: we set $keepActive in vzdump stop mode - volumes need to stay active
sub vm_stop {
    my ($storecfg, $vmid, $skiplock, $nocheck, $timeout, $shutdown, $force, $keepActive, $migratedfrom) = @_;

    $force = 1 if !defined($force) && !$shutdown;

    if ($migratedfrom){
	my $pid = check_running($vmid, $nocheck, $migratedfrom);
	kill 15, $pid if $pid;
	my $conf = PVE::QemuConfig->load_config($vmid, $migratedfrom);
	vm_stop_cleanup($storecfg, $vmid, $conf, $keepActive, 0);
	return;
    }

    PVE::QemuConfig->lock_config($vmid, sub {

	my $pid = check_running($vmid, $nocheck);
	return if !$pid;

	my $conf;
	if (!$nocheck) {
	    $conf = PVE::QemuConfig->load_config($vmid);
	    PVE::QemuConfig->check_lock($conf) if !$skiplock;
	    if (!defined($timeout) && $shutdown && $conf->{startup}) {
		my $opts = PVE::JSONSchema::pve_parse_startup_order($conf->{startup});
		$timeout = $opts->{down} if $opts->{down};
	    }
	    PVE::GuestHelpers::exec_hookscript($conf, $vmid, 'pre-stop');
	}

	eval {
	    if ($shutdown) {
		if (defined($conf) && parse_guest_agent($conf)->{enabled}) {
		    vm_qmp_command($vmid, {
			execute => "guest-shutdown",
			arguments => { timeout => $timeout }
		    }, $nocheck);
		} else {
		    vm_qmp_command($vmid, { execute => "system_powerdown" }, $nocheck);
		}
	    } else {
		vm_qmp_command($vmid, { execute => "quit" }, $nocheck);
	    }
	};
	my $err = $@;

	if (!$err) {
	    $timeout = 60 if !defined($timeout);

	    my $count = 0;
	    while (($count < $timeout) && check_running($vmid, $nocheck)) {
		$count++;
		sleep 1;
	    }

	    if ($count >= $timeout) {
		if ($force) {
		    warn "VM still running - terminating now with SIGTERM\n";
		    kill 15, $pid;
		} else {
		    die "VM quit/powerdown failed - got timeout\n";
		}
	    } else {
		vm_stop_cleanup($storecfg, $vmid, $conf, $keepActive, 1) if $conf;
		return;
	    }
	} else {
	    if ($force) {
		warn "VM quit/powerdown failed - terminating now with SIGTERM\n";
		kill 15, $pid;
	    } else {
		die "VM quit/powerdown failed\n";
	    }
	}

	# wait again
	$timeout = 10;

	my $count = 0;
	while (($count < $timeout) && check_running($vmid, $nocheck)) {
	    $count++;
	    sleep 1;
	}

	if ($count >= $timeout) {
	    warn "VM still running - terminating now with SIGKILL\n";
	    kill 9, $pid;
	    sleep 1;
	}

	vm_stop_cleanup($storecfg, $vmid, $conf, $keepActive, 1) if $conf;
   });
}

sub vm_suspend {
    my ($vmid, $skiplock, $includestate, $statestorage) = @_;

    my $conf;
    my $path;
    my $storecfg;
    my $vmstate;

    PVE::QemuConfig->lock_config($vmid, sub {

	$conf = PVE::QemuConfig->load_config($vmid);

	my $is_backing_up = PVE::QemuConfig->has_lock($conf, 'backup');
	PVE::QemuConfig->check_lock($conf)
	    if !($skiplock || $is_backing_up);

	die "cannot suspend to disk during backup\n"
	    if $is_backing_up && $includestate;

	if ($includestate) {
	    $conf->{lock} = 'suspending';
	    my $date = strftime("%Y-%m-%d", localtime(time()));
	    $storecfg = PVE::Storage::config();
	    $vmstate = PVE::QemuConfig->__snapshot_save_vmstate($vmid, $conf, "suspend-$date", $storecfg, $statestorage, 1);
	    $path = PVE::Storage::path($storecfg, $vmstate);
	    PVE::QemuConfig->write_config($vmid, $conf);
	} else {
	    vm_mon_cmd($vmid, "stop");
	}
    });

    if ($includestate) {
	# save vm state
	PVE::Storage::activate_volumes($storecfg, [$vmstate]);

	eval {
	    vm_mon_cmd($vmid, "savevm-start", statefile => $path);
	    for(;;) {
		my $state = vm_mon_cmd_nocheck($vmid, "query-savevm");
		if (!$state->{status}) {
		    die "savevm not active\n";
		} elsif ($state->{status} eq 'active') {
		    sleep(1);
		    next;
		} elsif ($state->{status} eq 'completed') {
		    print "State saved, quitting\n";
		    last;
		} elsif ($state->{status} eq 'failed' && $state->{error}) {
		    die "query-savevm failed with error '$state->{error}'\n"
		} else {
		    die "query-savevm returned status '$state->{status}'\n";
		}
	    }
	};
	my $err = $@;

	PVE::QemuConfig->lock_config($vmid, sub {
	    $conf = PVE::QemuConfig->load_config($vmid);
	    if ($err) {
		# cleanup, but leave suspending lock, to indicate something went wrong
		eval {
		    vm_mon_cmd($vmid, "savevm-end");
		    PVE::Storage::deactivate_volumes($storecfg, [$vmstate]);
		    PVE::Storage::vdisk_free($storecfg, $vmstate);
		    delete $conf->@{qw(vmstate runningmachine)};
		    PVE::QemuConfig->write_config($vmid, $conf);
		};
		warn $@ if $@;
		die $err;
	    }

	    die "lock changed unexpectedly\n"
		if !PVE::QemuConfig->has_lock($conf, 'suspending');

	    vm_qmp_command($vmid, { execute => "quit" });
	    $conf->{lock} = 'suspended';
	    PVE::QemuConfig->write_config($vmid, $conf);
	});
    }
}

sub vm_resume {
    my ($vmid, $skiplock, $nocheck) = @_;

    PVE::QemuConfig->lock_config($vmid, sub {
	my $vm_mon_cmd = $nocheck ? \&vm_mon_cmd_nocheck : \&vm_mon_cmd;
	my $res = $vm_mon_cmd->($vmid, 'query-status');
	my $resume_cmd = 'cont';

	if ($res->{status} && $res->{status} eq 'suspended') {
	    $resume_cmd = 'system_wakeup';
	}

	if (!$nocheck) {

	    my $conf = PVE::QemuConfig->load_config($vmid);

	    PVE::QemuConfig->check_lock($conf)
		if !($skiplock || PVE::QemuConfig->has_lock($conf, 'backup'));
	}

	$vm_mon_cmd->($vmid, $resume_cmd);
    });
}

sub vm_sendkey {
    my ($vmid, $skiplock, $key) = @_;

    PVE::QemuConfig->lock_config($vmid, sub {

	my $conf = PVE::QemuConfig->load_config($vmid);

	# there is no qmp command, so we use the human monitor command
	my $res = vm_human_monitor_command($vmid, "sendkey $key");
	die $res if $res ne '';
    });
}

sub vm_destroy {
    my ($storecfg, $vmid, $skiplock) = @_;

    PVE::QemuConfig->lock_config($vmid, sub {

	my $conf = PVE::QemuConfig->load_config($vmid);

	if (!check_running($vmid)) {
	    destroy_vm($storecfg, $vmid, undef, $skiplock);
	} else {
	    die "VM $vmid is running - destroy failed\n";
	}
    });
}

# vzdump restore implementaion

sub tar_archive_read_firstfile {
    my $archive = shift;

    die "ERROR: file '$archive' does not exist\n" if ! -f $archive;

    # try to detect archive type first
    my $pid = open (my $fh, '-|', 'tar', 'tf', $archive) ||
	die "unable to open file '$archive'\n";
    my $firstfile = <$fh>;
    kill 15, $pid;
    close $fh;

    die "ERROR: archive contaions no data\n" if !$firstfile;
    chomp $firstfile;

    return $firstfile;
}

sub tar_restore_cleanup {
    my ($storecfg, $statfile) = @_;

    print STDERR "starting cleanup\n";

    if (my $fd = IO::File->new($statfile, "r")) {
	while (defined(my $line = <$fd>)) {
	    if ($line =~ m/vzdump:([^\s:]*):(\S+)$/) {
		my $volid = $2;
		eval {
		    if ($volid =~ m|^/|) {
			unlink $volid || die 'unlink failed\n';
		    } else {
			PVE::Storage::vdisk_free($storecfg, $volid);
		    }
		    print STDERR "temporary volume '$volid' sucessfuly removed\n";
		};
		print STDERR "unable to cleanup '$volid' - $@" if $@;
	    } else {
		print STDERR "unable to parse line in statfile - $line";
	    }
	}
	$fd->close();
    }
}

sub restore_archive {
    my ($archive, $vmid, $user, $opts) = @_;

    my $format = $opts->{format};
    my $comp;

    if ($archive =~ m/\.tgz$/ || $archive =~ m/\.tar\.gz$/) {
	$format = 'tar' if !$format;
	$comp = 'gzip';
    } elsif ($archive =~ m/\.tar$/) {
	$format = 'tar' if !$format;
    } elsif ($archive =~ m/.tar.lzo$/) {
	$format = 'tar' if !$format;
	$comp = 'lzop';
    } elsif ($archive =~ m/\.vma$/) {
	$format = 'vma' if !$format;
    } elsif ($archive =~ m/\.vma\.gz$/) {
	$format = 'vma' if !$format;
	$comp = 'gzip';
    } elsif ($archive =~ m/\.vma\.lzo$/) {
	$format = 'vma' if !$format;
	$comp = 'lzop';
    } else {
	$format = 'vma' if !$format; # default
    }

    # try to detect archive format
    if ($format eq 'tar') {
	return restore_tar_archive($archive, $vmid, $user, $opts);
    } else {
	return restore_vma_archive($archive, $vmid, $user, $opts, $comp);
    }
}

sub restore_update_config_line {
    my ($outfd, $cookie, $vmid, $map, $line, $unique) = @_;

    return if $line =~ m/^\#qmdump\#/;
    return if $line =~ m/^\#vzdump\#/;
    return if $line =~ m/^lock:/;
    return if $line =~ m/^unused\d+:/;
    return if $line =~ m/^parent:/;

    my $dc = PVE::Cluster::cfs_read_file('datacenter.cfg');
    if (($line =~ m/^(vlan(\d+)):\s*(\S+)\s*$/)) {
	# try to convert old 1.X settings
	my ($id, $ind, $ethcfg) = ($1, $2, $3);
	foreach my $devconfig (PVE::Tools::split_list($ethcfg)) {
	    my ($model, $macaddr) = split(/\=/, $devconfig);
	    $macaddr = PVE::Tools::random_ether_addr($dc->{mac_prefix}) if !$macaddr || $unique;
	    my $net = {
		model => $model,
		bridge => "vmbr$ind",
		macaddr => $macaddr,
	    };
	    my $netstr = print_net($net);

	    print $outfd "net$cookie->{netcount}: $netstr\n";
	    $cookie->{netcount}++;
	}
    } elsif (($line =~ m/^(net\d+):\s*(\S+)\s*$/) && $unique) {
	my ($id, $netstr) = ($1, $2);
	my $net = parse_net($netstr);
	$net->{macaddr} = PVE::Tools::random_ether_addr($dc->{mac_prefix}) if $net->{macaddr};
	$netstr = print_net($net);
	print $outfd "$id: $netstr\n";
    } elsif ($line =~ m/^((ide|scsi|virtio|sata|efidisk)\d+):\s*(\S+)\s*$/) {
	my $virtdev = $1;
	my $value = $3;
	my $di = parse_drive($virtdev, $value);
	if (defined($di->{backup}) && !$di->{backup}) {
	    print $outfd "#$line";
	} elsif ($map->{$virtdev}) {
	    delete $di->{format}; # format can change on restore
	    $di->{file} = $map->{$virtdev};
	    $value = print_drive($vmid, $di);
	    print $outfd "$virtdev: $value\n";
	} else {
	    print $outfd $line;
	}
    } elsif (($line =~ m/^vmgenid: (.*)/)) {
	my $vmgenid = $1;
	if ($vmgenid ne '0') {
	    # always generate a new vmgenid if there was a valid one setup
	    $vmgenid = generate_uuid();
	}
	print $outfd "vmgenid: $vmgenid\n";
    } elsif (($line =~ m/^(smbios1: )(.*)/) && $unique) {
	my ($uuid, $uuid_str);
	UUID::generate($uuid);
	UUID::unparse($uuid, $uuid_str);
	my $smbios1 = parse_smbios1($2);
	$smbios1->{uuid} = $uuid_str;
	print $outfd $1.print_smbios1($smbios1)."\n";
    } else {
	print $outfd $line;
    }
}

sub scan_volids {
    my ($cfg, $vmid) = @_;

    my $info = PVE::Storage::vdisk_list($cfg, undef, $vmid);

    my $volid_hash = {};
    foreach my $storeid (keys %$info) {
	foreach my $item (@{$info->{$storeid}}) {
	    next if !($item->{volid} && $item->{size});
	    $item->{path} = PVE::Storage::path($cfg, $item->{volid});
	    $volid_hash->{$item->{volid}} = $item;
	}
    }

    return $volid_hash;
}

sub is_volume_in_use {
    my ($storecfg, $conf, $skip_drive, $volid) = @_;

    my $path = PVE::Storage::path($storecfg, $volid);

    my $scan_config = sub {
	my ($cref, $snapname) = @_;

	foreach my $key (keys %$cref) {
	    my $value = $cref->{$key};
	    if (is_valid_drivename($key)) {
		next if $skip_drive && $key eq $skip_drive;
		my $drive = parse_drive($key, $value);
		next if !$drive || !$drive->{file} || drive_is_cdrom($drive);
		return 1 if $volid eq $drive->{file};
		if ($drive->{file} =~ m!^/!) {
		    return 1 if $drive->{file} eq $path;
		} else {
		    my ($storeid, $volname) = PVE::Storage::parse_volume_id($drive->{file}, 1);
		    next if !$storeid;
		    my $scfg = PVE::Storage::storage_config($storecfg, $storeid, 1);
		    next if !$scfg;
		    return 1 if $path eq PVE::Storage::path($storecfg, $drive->{file}, $snapname);
		}
	    }
	}

	return 0;
    };

    return 1 if &$scan_config($conf);

    undef $skip_drive;

    foreach my $snapname (keys %{$conf->{snapshots}}) {
	return 1 if &$scan_config($conf->{snapshots}->{$snapname}, $snapname);
    }

    return 0;
}

sub update_disksize {
    my ($vmid, $conf, $volid_hash) = @_;

    my $changes;
    my $prefix = "VM $vmid:";

    # used and unused disks
    my $referenced = {};

    # Note: it is allowed to define multiple storages with same path (alias), so
    # we need to check both 'volid' and real 'path' (two different volid can point
    # to the same path).

    my $referencedpath = {};

    # update size info
    foreach my $opt (keys %$conf) {
	if (is_valid_drivename($opt)) {
	    my $drive = parse_drive($opt, $conf->{$opt});
	    my $volid = $drive->{file};
	    next if !$volid;

	    $referenced->{$volid} = 1;
	    if ($volid_hash->{$volid} &&
		(my $path = $volid_hash->{$volid}->{path})) {
		$referencedpath->{$path} = 1;
	    }

	    next if drive_is_cdrom($drive);
	    next if !$volid_hash->{$volid};

	    $drive->{size} = $volid_hash->{$volid}->{size};
	    my $new = print_drive($vmid, $drive);
	    if ($new ne $conf->{$opt}) {
		$changes = 1;
		$conf->{$opt} = $new;
		print "$prefix update disk '$opt' information.\n";
	    }
	}
    }

    # remove 'unusedX' entry if volume is used
    foreach my $opt (keys %$conf) {
	next if $opt !~ m/^unused\d+$/;
	my $volid = $conf->{$opt};
	my $path = $volid_hash->{$volid}->{path} if $volid_hash->{$volid};
	if ($referenced->{$volid} || ($path && $referencedpath->{$path})) {
	    print "$prefix remove entry '$opt', its volume '$volid' is in use.\n";
	    $changes = 1;
	    delete $conf->{$opt};
	}

	$referenced->{$volid} = 1;
	$referencedpath->{$path} = 1 if $path;
    }

    foreach my $volid (sort keys %$volid_hash) {
	next if $volid =~ m/vm-$vmid-state-/;
	next if $referenced->{$volid};
	my $path = $volid_hash->{$volid}->{path};
	next if !$path; # just to be sure
	next if $referencedpath->{$path};
	$changes = 1;
	my $key = PVE::QemuConfig->add_unused_volume($conf, $volid);
	print "$prefix add unreferenced volume '$volid' as '$key' to config.\n";
	$referencedpath->{$path} = 1; # avoid to add more than once (aliases)
    }

    return $changes;
}

sub rescan {
    my ($vmid, $nolock, $dryrun) = @_;

    my $cfg = PVE::Storage::config();

    # FIXME: Remove once our RBD plugin can handle CT and VM on a single storage
    # see: https://pve.proxmox.com/pipermail/pve-devel/2018-July/032900.html
    foreach my $stor (keys %{$cfg->{ids}}) {
	delete($cfg->{ids}->{$stor}) if ! $cfg->{ids}->{$stor}->{content}->{images};
    }

    print "rescan volumes...\n";
    my $volid_hash = scan_volids($cfg, $vmid);

    my $updatefn =  sub {
	my ($vmid) = @_;

	my $conf = PVE::QemuConfig->load_config($vmid);

	PVE::QemuConfig->check_lock($conf);

	my $vm_volids = {};
	foreach my $volid (keys %$volid_hash) {
	    my $info = $volid_hash->{$volid};
	    $vm_volids->{$volid} = $info if $info->{vmid} && $info->{vmid} == $vmid;
	}

	my $changes = update_disksize($vmid, $conf, $vm_volids);

	PVE::QemuConfig->write_config($vmid, $conf) if $changes && !$dryrun;
    };

    if (defined($vmid)) {
	if ($nolock) {
	    &$updatefn($vmid);
	} else {
	    PVE::QemuConfig->lock_config($vmid, $updatefn, $vmid);
	}
    } else {
	my $vmlist = config_list();
	foreach my $vmid (keys %$vmlist) {
	    if ($nolock) {
		&$updatefn($vmid);
	    } else {
		PVE::QemuConfig->lock_config($vmid, $updatefn, $vmid);
	    }
	}
    }
}

sub restore_vma_archive {
    my ($archive, $vmid, $user, $opts, $comp) = @_;

    my $readfrom = $archive;

    my $cfg = PVE::Storage::config();
    my $commands = [];
    my $bwlimit = $opts->{bwlimit};

    my $dbg_cmdstring = '';
    my $add_pipe = sub {
	my ($cmd) = @_;
	push @$commands, $cmd;
	$dbg_cmdstring .= ' | ' if length($dbg_cmdstring);
	$dbg_cmdstring .= PVE::Tools::cmd2string($cmd);
	$readfrom = '-';
    };

    my $input = undef;
    if ($archive eq '-') {
	$input = '<&STDIN';
    } else {
	# If we use a backup from a PVE defined storage we also consider that
	# storage's rate limit:
	my (undef, $volid) = PVE::Storage::path_to_volume_id($cfg, $archive);
	if (defined($volid)) {
	    my ($sid, undef) = PVE::Storage::parse_volume_id($volid);
	    my $readlimit = PVE::Storage::get_bandwidth_limit('restore', [$sid], $bwlimit);
	    if ($readlimit) {
		print STDERR "applying read rate limit: $readlimit\n";
		my $cstream = ['cstream', '-t', $readlimit*1024, '--', $readfrom];
		$add_pipe->($cstream);
	    }
	}
    }

    if ($comp) {
	my $cmd;
	if ($comp eq 'gzip') {
	    $cmd = ['zcat', $readfrom];
	} elsif ($comp eq 'lzop') {
	    $cmd = ['lzop', '-d', '-c', $readfrom];
	} else {
	    die "unknown compression method '$comp'\n";
	}
	$add_pipe->($cmd);
    }

    my $tmpdir = "/var/tmp/vzdumptmp$$";
    rmtree $tmpdir;

    # disable interrupts (always do cleanups)
    local $SIG{INT} =
	local $SIG{TERM} =
	local $SIG{QUIT} =
	local $SIG{HUP} = sub { warn "got interrupt - ignored\n"; };

    my $mapfifo = "/var/tmp/vzdumptmp$$.fifo";
    POSIX::mkfifo($mapfifo, 0600);
    my $fifofh;

    my $openfifo = sub {
	open($fifofh, '>', $mapfifo) || die $!;
    };

    $add_pipe->(['vma', 'extract', '-v', '-r', $mapfifo, $readfrom, $tmpdir]);

    my $oldtimeout;
    my $timeout = 5;

    my $devinfo = {};

    my $rpcenv = PVE::RPCEnvironment::get();

    my $conffile = PVE::QemuConfig->config_file($vmid);
    my $tmpfn = "$conffile.$$.tmp";

    # Note: $oldconf is undef if VM does not exists
    my $cfs_path = PVE::QemuConfig->cfs_config_path($vmid);
    my $oldconf = PVE::Cluster::cfs_read_file($cfs_path);

    my %storage_limits;

    my $print_devmap = sub {
	my $virtdev_hash = {};

	my $cfgfn = "$tmpdir/qemu-server.conf";

	# we can read the config - that is already extracted
	my $fh = IO::File->new($cfgfn, "r") ||
	    "unable to read qemu-server.conf - $!\n";

	my $fwcfgfn = "$tmpdir/qemu-server.fw";
	if (-f $fwcfgfn) {
	    my $pve_firewall_dir = '/etc/pve/firewall';
	    mkdir $pve_firewall_dir; # make sure the dir exists
	    PVE::Tools::file_copy($fwcfgfn, "${pve_firewall_dir}/$vmid.fw");
	}

	while (defined(my $line = <$fh>)) {
	    if ($line =~ m/^\#qmdump\#map:(\S+):(\S+):(\S*):(\S*):$/) {
		my ($virtdev, $devname, $storeid, $format) = ($1, $2, $3, $4);
		die "archive does not contain data for drive '$virtdev'\n"
		    if !$devinfo->{$devname};
		if (defined($opts->{storage})) {
		    $storeid = $opts->{storage} || 'local';
		} elsif (!$storeid) {
		    $storeid = 'local';
		}
		$format = 'raw' if !$format;
		$devinfo->{$devname}->{devname} = $devname;
		$devinfo->{$devname}->{virtdev} = $virtdev;
		$devinfo->{$devname}->{format} = $format;
		$devinfo->{$devname}->{storeid} = $storeid;

		# check permission on storage
		my $pool = $opts->{pool}; # todo: do we need that?
		if ($user ne 'root@pam') {
		    $rpcenv->check($user, "/storage/$storeid", ['Datastore.AllocateSpace']);
		}

		$storage_limits{$storeid} = $bwlimit;

		$virtdev_hash->{$virtdev} = $devinfo->{$devname};
	    } elsif ($line =~ m/^((?:ide|sata|scsi)\d+):\s*(.*)\s*$/) {
		my $virtdev = $1;
		my $drive = parse_drive($virtdev, $2);
		if (drive_is_cloudinit($drive)) {
		    my ($storeid, $volname) = PVE::Storage::parse_volume_id($drive->{file});
		    my $scfg = PVE::Storage::storage_config($cfg, $storeid);
		    my $format = qemu_img_format($scfg, $volname); # has 'raw' fallback

		    my $d = {
			format => $format,
			storeid => $opts->{storage} // $storeid,
			size => PVE::QemuServer::Cloudinit::CLOUDINIT_DISK_SIZE,
			file => $drive->{file}, # to make drive_is_cloudinit check possible
			name => "vm-$vmid-cloudinit",
			is_cloudinit => 1,
		    };
		    $virtdev_hash->{$virtdev} = $d;
		}
	    }
	}

	foreach my $key (keys %storage_limits) {
	    my $limit = PVE::Storage::get_bandwidth_limit('restore', [$key], $bwlimit);
	    next if !$limit;
	    print STDERR "rate limit for storage $key: $limit KiB/s\n";
	    $storage_limits{$key} = $limit * 1024;
	}

	foreach my $devname (keys %$devinfo) {
	    die "found no device mapping information for device '$devname'\n"
		if !$devinfo->{$devname}->{virtdev};
	}

	# create empty/temp config
	if ($oldconf) {
	    PVE::Tools::file_set_contents($conffile, "memory: 128\n");
	    foreach_drive($oldconf, sub {
		my ($ds, $drive) = @_;

		return if !$drive->{is_cloudinit} && drive_is_cdrom($drive);

		my $volid = $drive->{file};
		return if !$volid || $volid =~ m|^/|;

		my ($path, $owner) = PVE::Storage::path($cfg, $volid);
		return if !$path || !$owner || ($owner != $vmid);

		# Note: only delete disk we want to restore
		# other volumes will become unused
		if ($virtdev_hash->{$ds}) {
		    eval { PVE::Storage::vdisk_free($cfg, $volid); };
		    if (my $err = $@) {
			warn $err;
		    }
		}
	    });

	    # delete vmstate files, after the restore we have no snapshots anymore
	    foreach my $snapname (keys %{$oldconf->{snapshots}}) {
		my $snap = $oldconf->{snapshots}->{$snapname};
		if ($snap->{vmstate}) {
		    eval { PVE::Storage::vdisk_free($cfg, $snap->{vmstate}); };
		    if (my $err = $@) {
			warn $err;
		    }
		}
	    }
	}

	my $map = {};
	foreach my $virtdev (sort keys %$virtdev_hash) {
	    my $d = $virtdev_hash->{$virtdev};
	    my $alloc_size = int(($d->{size} + 1024 - 1)/1024);
	    my $storeid = $d->{storeid};
	    my $scfg = PVE::Storage::storage_config($cfg, $storeid);

	    my $map_opts = '';
	    if (my $limit = $storage_limits{$storeid}) {
		$map_opts .= "throttling.bps=$limit:throttling.group=$storeid:";
	    }

	    # test if requested format is supported
	    my ($defFormat, $validFormats) = PVE::Storage::storage_default_format($cfg, $storeid);
	    my $supported = grep { $_ eq $d->{format} } @$validFormats;
	    $d->{format} = $defFormat if !$supported;

	    my $name;
	    if ($d->{is_cloudinit}) {
		$name = $d->{name};
		$name .= ".$d->{format}" if $d->{format} ne 'raw';
	    }

	    my $volid = PVE::Storage::vdisk_alloc($cfg, $storeid, $vmid, $d->{format}, $name, $alloc_size);
	    print STDERR "new volume ID is '$volid'\n";
	    $d->{volid} = $volid;

	    PVE::Storage::activate_volumes($cfg, [$volid]);

	    my $write_zeros = 1;
	    if (PVE::Storage::volume_has_feature($cfg, 'sparseinit', $volid)) {
		$write_zeros = 0;
	    }

	    if (!$d->{is_cloudinit}) {
		my $path = PVE::Storage::path($cfg, $volid);

		print $fifofh "${map_opts}format=$d->{format}:${write_zeros}:$d->{devname}=$path\n";

		print "map '$d->{devname}' to '$path' (write zeros = ${write_zeros})\n";
	    }
	    $map->{$virtdev} = $volid;
	}

	$fh->seek(0, 0) || die "seek failed - $!\n";

	my $outfd = new IO::File ($tmpfn, "w") ||
	    die "unable to write config for VM $vmid\n";

	my $cookie = { netcount => 0 };
	while (defined(my $line = <$fh>)) {
	    restore_update_config_line($outfd, $cookie, $vmid, $map, $line, $opts->{unique});
	}

	$fh->close();
	$outfd->close();
    };

    eval {
	# enable interrupts
	local $SIG{INT} =
	    local $SIG{TERM} =
	    local $SIG{QUIT} =
	    local $SIG{HUP} =
	    local $SIG{PIPE} = sub { die "interrupted by signal\n"; };
	local $SIG{ALRM} = sub { die "got timeout\n"; };

	$oldtimeout = alarm($timeout);

	my $parser = sub {
	    my $line = shift;

	    print "$line\n";

	    if ($line =~ m/^DEV:\sdev_id=(\d+)\ssize:\s(\d+)\sdevname:\s(\S+)$/) {
		my ($dev_id, $size, $devname) = ($1, $2, $3);
		$devinfo->{$devname} = { size => $size, dev_id => $dev_id };
	    } elsif ($line =~ m/^CTIME: /) {
		# we correctly received the vma config, so we can disable
		# the timeout now for disk allocation (set to 10 minutes, so
		# that we always timeout if something goes wrong)
		alarm(600);
		&$print_devmap();
		print $fifofh "done\n";
		my $tmp = $oldtimeout || 0;
		$oldtimeout = undef;
		alarm($tmp);
		close($fifofh);
	    }
	};

	print "restore vma archive: $dbg_cmdstring\n";
	run_command($commands, input => $input, outfunc => $parser, afterfork => $openfifo);
    };
    my $err = $@;

    alarm($oldtimeout) if $oldtimeout;

    my $vollist = [];
    foreach my $devname (keys %$devinfo) {
	my $volid = $devinfo->{$devname}->{volid};
	push @$vollist, $volid if $volid;
    }

    PVE::Storage::deactivate_volumes($cfg, $vollist);

    unlink $mapfifo;

    if ($err) {
	rmtree $tmpdir;
	unlink $tmpfn;

	foreach my $devname (keys %$devinfo) {
	    my $volid = $devinfo->{$devname}->{volid};
	    next if !$volid;
	    eval {
		if ($volid =~ m|^/|) {
		    unlink $volid || die 'unlink failed\n';
		} else {
		    PVE::Storage::vdisk_free($cfg, $volid);
		}
		print STDERR "temporary volume '$volid' sucessfuly removed\n";
	    };
	    print STDERR "unable to cleanup '$volid' - $@" if $@;
	}
	die $err;
    }

    rmtree $tmpdir;

    rename($tmpfn, $conffile) ||
	die "unable to commit configuration file '$conffile'\n";

    PVE::Cluster::cfs_update(); # make sure we read new file

    eval { rescan($vmid, 1); };
    warn $@ if $@;
}

sub restore_tar_archive {
    my ($archive, $vmid, $user, $opts) = @_;

    if ($archive ne '-') {
	my $firstfile = tar_archive_read_firstfile($archive);
	die "ERROR: file '$archive' dos not lock like a QemuServer vzdump backup\n"
	    if $firstfile ne 'qemu-server.conf';
    }

    my $storecfg = PVE::Storage::config();

    # destroy existing data - keep empty config
    my $vmcfgfn = PVE::QemuConfig->config_file($vmid);
    destroy_vm($storecfg, $vmid, 1) if -f $vmcfgfn;

    my $tocmd = "/usr/lib/qemu-server/qmextract";

    $tocmd .= " --storage " . PVE::Tools::shellquote($opts->{storage}) if $opts->{storage};
    $tocmd .= " --pool " . PVE::Tools::shellquote($opts->{pool}) if $opts->{pool};
    $tocmd .= ' --prealloc' if $opts->{prealloc};
    $tocmd .= ' --info' if $opts->{info};

    # tar option "xf" does not autodetect compression when read from STDIN,
    # so we pipe to zcat
    my $cmd = "zcat -f|tar xf " . PVE::Tools::shellquote($archive) . " " .
	PVE::Tools::shellquote("--to-command=$tocmd");

    my $tmpdir = "/var/tmp/vzdumptmp$$";
    mkpath $tmpdir;

    local $ENV{VZDUMP_TMPDIR} = $tmpdir;
    local $ENV{VZDUMP_VMID} = $vmid;
    local $ENV{VZDUMP_USER} = $user;

    my $conffile = PVE::QemuConfig->config_file($vmid);
    my $tmpfn = "$conffile.$$.tmp";

    # disable interrupts (always do cleanups)
    local $SIG{INT} =
	local $SIG{TERM} =
	local $SIG{QUIT} =
	local $SIG{HUP} = sub { print STDERR "got interrupt - ignored\n"; };

    eval {
	# enable interrupts
	local $SIG{INT} =
	    local $SIG{TERM} =
	    local $SIG{QUIT} =
	    local $SIG{HUP} =
	    local $SIG{PIPE} = sub { die "interrupted by signal\n"; };

	if ($archive eq '-') {
	    print "extracting archive from STDIN\n";
	    run_command($cmd, input => "<&STDIN");
	} else {
	    print "extracting archive '$archive'\n";
	    run_command($cmd);
	}

	return if $opts->{info};

	# read new mapping
	my $map = {};
	my $statfile = "$tmpdir/qmrestore.stat";
	if (my $fd = IO::File->new($statfile, "r")) {
	    while (defined (my $line = <$fd>)) {
		if ($line =~ m/vzdump:([^\s:]*):(\S+)$/) {
		    $map->{$1} = $2 if $1;
		} else {
		    print STDERR "unable to parse line in statfile - $line\n";
		}
	    }
	    $fd->close();
	}

	my $confsrc = "$tmpdir/qemu-server.conf";

	my $srcfd = new IO::File($confsrc, "r") ||
	    die "unable to open file '$confsrc'\n";

	my $outfd = new IO::File ($tmpfn, "w") ||
	    die "unable to write config for VM $vmid\n";

	my $cookie = { netcount => 0 };
	while (defined (my $line = <$srcfd>)) {
	    restore_update_config_line($outfd, $cookie, $vmid, $map, $line, $opts->{unique});
	}

	$srcfd->close();
	$outfd->close();
    };
    my $err = $@;

    if ($err) {

	unlink $tmpfn;

	tar_restore_cleanup($storecfg, "$tmpdir/qmrestore.stat") if !$opts->{info};

	die $err;
    }

    rmtree $tmpdir;

    rename $tmpfn, $conffile ||
	die "unable to commit configuration file '$conffile'\n";

    PVE::Cluster::cfs_update(); # make sure we read new file

    eval { rescan($vmid, 1); };
    warn $@ if $@;
};

sub foreach_storage_used_by_vm {
    my ($conf, $func) = @_;

    my $sidhash = {};

    foreach_drive($conf, sub {
	my ($ds, $drive) = @_;
	return if drive_is_cdrom($drive);

	my $volid = $drive->{file};

	my ($sid, $volname) = PVE::Storage::parse_volume_id($volid, 1);
	$sidhash->{$sid} = $sid if $sid;
    });

    foreach my $sid (sort keys %$sidhash) {
	&$func($sid);
    }
}

sub do_snapshots_with_qemu {
    my ($storecfg, $volid) = @_;

    my $storage_name = PVE::Storage::parse_volume_id($volid);
    my $scfg = $storecfg->{ids}->{$storage_name};

    if ($qemu_snap_storage->{$scfg->{type}} && !$scfg->{krbd}){
	return 1;
    }

    if ($volid =~ m/\.(qcow2|qed)$/){
	return 1;
    }

    return undef;
}

sub qga_check_running {
    my ($vmid, $nowarn) = @_;

    eval { vm_mon_cmd($vmid, "guest-ping", timeout => 3); };
    if ($@) {
	warn "Qemu Guest Agent is not running - $@" if !$nowarn;
	return 0;
    }
    return 1;
}

sub template_create {
    my ($vmid, $conf, $disk) = @_;

    my $storecfg = PVE::Storage::config();

    foreach_drive($conf, sub {
	my ($ds, $drive) = @_;

	return if drive_is_cdrom($drive);
	return if $disk && $ds ne $disk;

	my $volid = $drive->{file};
	return if !PVE::Storage::volume_has_feature($storecfg, 'template', $volid);

	my $voliddst = PVE::Storage::vdisk_create_base($storecfg, $volid);
	$drive->{file} = $voliddst;
	$conf->{$ds} = print_drive($vmid, $drive);
	PVE::QemuConfig->write_config($vmid, $conf);
    });
}

sub convert_iscsi_path {
    my ($path) = @_;

    if ($path =~ m|^iscsi://([^/]+)/([^/]+)/(.+)$|) {
	my $portal = $1;
	my $target = $2;
	my $lun = $3;

	my $initiator_name = get_initiator_name();

	return "file.driver=iscsi,file.transport=tcp,file.initiator-name=$initiator_name,".
	       "file.portal=$portal,file.target=$target,file.lun=$lun,driver=raw";
    }

    die "cannot convert iscsi path '$path', unkown format\n";
}

sub qemu_img_convert {
    my ($src_volid, $dst_volid, $size, $snapname, $is_zero_initialized) = @_;

    my $storecfg = PVE::Storage::config();
    my ($src_storeid, $src_volname) = PVE::Storage::parse_volume_id($src_volid, 1);
    my ($dst_storeid, $dst_volname) = PVE::Storage::parse_volume_id($dst_volid, 1);

    if ($src_storeid && $dst_storeid) {

	PVE::Storage::activate_volumes($storecfg, [$src_volid], $snapname);

	my $src_scfg = PVE::Storage::storage_config($storecfg, $src_storeid);
	my $dst_scfg = PVE::Storage::storage_config($storecfg, $dst_storeid);

	my $src_format = qemu_img_format($src_scfg, $src_volname);
	my $dst_format = qemu_img_format($dst_scfg, $dst_volname);

	my $src_path = PVE::Storage::path($storecfg, $src_volid, $snapname);
	my $dst_path = PVE::Storage::path($storecfg, $dst_volid);

	my $src_is_iscsi = ($src_path =~ m|^iscsi://|);
	my $dst_is_iscsi = ($dst_path =~ m|^iscsi://|);

	my $cmd = [];
	push @$cmd, '/usr/bin/qemu-img', 'convert', '-p', '-n';
	push @$cmd, '-l', "snapshot.name=$snapname" if($snapname && $src_format eq "qcow2");
	push @$cmd, '-t', 'none' if $dst_scfg->{type} eq 'zfspool';
	push @$cmd, '-T', 'none' if $src_scfg->{type} eq 'zfspool';

	if ($src_is_iscsi) {
	    push @$cmd, '--image-opts';
	    $src_path = convert_iscsi_path($src_path);
	} else {
	    push @$cmd, '-f', $src_format;
	}

	if ($dst_is_iscsi) {
	    push @$cmd, '--target-image-opts';
	    $dst_path = convert_iscsi_path($dst_path);
	} else {
	    push @$cmd, '-O', $dst_format;
	}

	push @$cmd, $src_path;

	if (!$dst_is_iscsi && $is_zero_initialized) {
	    push @$cmd, "zeroinit:$dst_path";
	} else {
	    push @$cmd, $dst_path;
	}

	my $parser = sub {
	    my $line = shift;
	    if($line =~ m/\((\S+)\/100\%\)/){
		my $percent = $1;
		my $transferred = int($size * $percent / 100);
		my $remaining = $size - $transferred;

		print "transferred: $transferred bytes remaining: $remaining bytes total: $size bytes progression: $percent %\n";
	    }

	};

	eval  { run_command($cmd, timeout => undef, outfunc => $parser); };
	my $err = $@;
	die "copy failed: $err" if $err;
    }
}

sub qemu_img_format {
    my ($scfg, $volname) = @_;

    if ($scfg->{path} && $volname =~ m/\.($QEMU_FORMAT_RE)$/) {
	return $1;
    } else {
	return "raw";
    }
}

sub qemu_drive_mirror {
    my ($vmid, $drive, $dst_volid, $vmiddst, $is_zero_initialized, $jobs, $skipcomplete, $qga, $bwlimit) = @_;

    $jobs = {} if !$jobs;

    my $qemu_target;
    my $format;
    $jobs->{"drive-$drive"} = {};

    if ($dst_volid =~ /^nbd:/) {
	$qemu_target = $dst_volid;
	$format = "nbd";
    } else {
	my $storecfg = PVE::Storage::config();
	my ($dst_storeid, $dst_volname) = PVE::Storage::parse_volume_id($dst_volid);

	my $dst_scfg = PVE::Storage::storage_config($storecfg, $dst_storeid);

	$format = qemu_img_format($dst_scfg, $dst_volname);

	my $dst_path = PVE::Storage::path($storecfg, $dst_volid);

	$qemu_target = $is_zero_initialized ? "zeroinit:$dst_path" : $dst_path;
    }

    my $opts = { timeout => 10, device => "drive-$drive", mode => "existing", sync => "full", target => $qemu_target };
    $opts->{format} = $format if $format;

    if (defined($bwlimit)) {
	$opts->{speed} = $bwlimit * 1024;
	print "drive mirror is starting for drive-$drive with bandwidth limit: ${bwlimit} KB/s\n";
    } else {
	print "drive mirror is starting for drive-$drive\n";
    }

    # if a job already runs for this device we get an error, catch it for cleanup
    eval { vm_mon_cmd($vmid, "drive-mirror", %$opts); };
    if (my $err = $@) {
	eval { PVE::QemuServer::qemu_blockjobs_cancel($vmid, $jobs) };
	warn "$@\n" if $@;
	die "mirroring error: $err\n";
    }

    qemu_drive_mirror_monitor ($vmid, $vmiddst, $jobs, $skipcomplete, $qga);
}

sub qemu_drive_mirror_monitor {
    my ($vmid, $vmiddst, $jobs, $skipcomplete, $qga) = @_;

    eval {
	my $err_complete = 0;

	while (1) {
	    die "storage migration timed out\n" if $err_complete > 300;

	    my $stats = vm_mon_cmd($vmid, "query-block-jobs");

	    my $running_mirror_jobs = {};
	    foreach my $stat (@$stats) {
		next if $stat->{type} ne 'mirror';
		$running_mirror_jobs->{$stat->{device}} = $stat;
	    }

	    my $readycounter = 0;

	    foreach my $job (keys %$jobs) {

	        if(defined($jobs->{$job}->{complete}) && !defined($running_mirror_jobs->{$job})) {
		    print "$job : finished\n";
		    delete $jobs->{$job};
		    next;
		}

		die "$job: mirroring has been cancelled\n" if !defined($running_mirror_jobs->{$job});

		my $busy = $running_mirror_jobs->{$job}->{busy};
		my $ready = $running_mirror_jobs->{$job}->{ready};
		if (my $total = $running_mirror_jobs->{$job}->{len}) {
		    my $transferred = $running_mirror_jobs->{$job}->{offset} || 0;
		    my $remaining = $total - $transferred;
		    my $percent = sprintf "%.2f", ($transferred * 100 / $total);

		    print "$job: transferred: $transferred bytes remaining: $remaining bytes total: $total bytes progression: $percent % busy: $busy ready: $ready \n";
		}

		$readycounter++ if $running_mirror_jobs->{$job}->{ready};
	    }

	    last if scalar(keys %$jobs) == 0;

	    if ($readycounter == scalar(keys %$jobs)) {
		print "all mirroring jobs are ready \n";
		last if $skipcomplete; #do the complete later

		if ($vmiddst && $vmiddst != $vmid) {
		    my $agent_running = $qga && qga_check_running($vmid);
		    if ($agent_running) {
			print "freeze filesystem\n";
			eval { PVE::QemuServer::vm_mon_cmd($vmid, "guest-fsfreeze-freeze"); };
		    } else {
			print "suspend vm\n";
			eval { PVE::QemuServer::vm_suspend($vmid, 1); };
		    }

		    # if we clone a disk for a new target vm, we don't switch the disk
		    PVE::QemuServer::qemu_blockjobs_cancel($vmid, $jobs);

		    if ($agent_running) {
			print "unfreeze filesystem\n";
			eval { PVE::QemuServer::vm_mon_cmd($vmid, "guest-fsfreeze-thaw"); };
		    } else {
			print "resume vm\n";
			eval {  PVE::QemuServer::vm_resume($vmid, 1, 1); };
		    }

		    last;
		} else {

		    foreach my $job (keys %$jobs) {
			# try to switch the disk if source and destination are on the same guest
			print "$job: Completing block job...\n";

			eval { vm_mon_cmd($vmid, "block-job-complete", device => $job) };
			if ($@ =~ m/cannot be completed/) {
			    print "$job: Block job cannot be completed, try again.\n";
			    $err_complete++;
			}else {
			    print "$job: Completed successfully.\n";
			    $jobs->{$job}->{complete} = 1;
			}
		    }
		}
	    }
	    sleep 1;
	}
    };
    my $err = $@;

    if ($err) {
	eval { PVE::QemuServer::qemu_blockjobs_cancel($vmid, $jobs) };
	die "mirroring error: $err";
    }

}

sub qemu_blockjobs_cancel {
    my ($vmid, $jobs) = @_;

    foreach my $job (keys %$jobs) {
	print "$job: Cancelling block job\n";
	eval { vm_mon_cmd($vmid, "block-job-cancel", device => $job); };
	$jobs->{$job}->{cancel} = 1;
    }

    while (1) {
	my $stats = vm_mon_cmd($vmid, "query-block-jobs");

	my $running_jobs = {};
	foreach my $stat (@$stats) {
	    $running_jobs->{$stat->{device}} = $stat;
	}

	foreach my $job (keys %$jobs) {

	    if (defined($jobs->{$job}->{cancel}) && !defined($running_jobs->{$job})) {
		print "$job: Done.\n";
		delete $jobs->{$job};
	    }
	}

	last if scalar(keys %$jobs) == 0;

	sleep 1;
    }
}

sub clone_disk {
    my ($storecfg, $vmid, $running, $drivename, $drive, $snapname,
	$newvmid, $storage, $format, $full, $newvollist, $jobs, $skipcomplete, $qga, $bwlimit) = @_;

    my $newvolid;

    if (!$full) {
	print "create linked clone of drive $drivename ($drive->{file})\n";
	$newvolid = PVE::Storage::vdisk_clone($storecfg,  $drive->{file}, $newvmid, $snapname);
	push @$newvollist, $newvolid;
    } else {

	my ($storeid, $volname) = PVE::Storage::parse_volume_id($drive->{file});
	$storeid = $storage if $storage;

	my $dst_format = resolve_dst_disk_format($storecfg, $storeid, $volname, $format);
	my ($size) = PVE::Storage::volume_size_info($storecfg, $drive->{file}, 3);

	print "create full clone of drive $drivename ($drive->{file})\n";
	my $name = undef;
	if (drive_is_cloudinit($drive)) {
	    $name = "vm-$newvmid-cloudinit";
	    $snapname = undef;
	    # we only get here if it's supported by QEMU_FORMAT_RE, so just accept
	    if ($dst_format ne 'raw') {
		$name .= ".$dst_format";
	    }
	}
	$newvolid = PVE::Storage::vdisk_alloc($storecfg, $storeid, $newvmid, $dst_format, $name, ($size/1024));
	push @$newvollist, $newvolid;

	PVE::Storage::activate_volumes($storecfg, [$newvolid]);

	my $sparseinit = PVE::Storage::volume_has_feature($storecfg, 'sparseinit', $newvolid);
	if (!$running || $snapname) {
	    # TODO: handle bwlimits
	    qemu_img_convert($drive->{file}, $newvolid, $size, $snapname, $sparseinit);
	} else {

	    my $kvmver = get_running_qemu_version ($vmid);
	    if (!qemu_machine_feature_enabled (undef, $kvmver, 2, 7)) {
		die "drive-mirror with iothread requires qemu version 2.7 or higher\n"
		    if $drive->{iothread};
	    }

	    qemu_drive_mirror($vmid, $drivename, $newvolid, $newvmid, $sparseinit, $jobs, $skipcomplete, $qga, $bwlimit);
	}
    }

    my ($size) = PVE::Storage::volume_size_info($storecfg, $newvolid, 3);

    my $disk = $drive;
    $disk->{format} = undef;
    $disk->{file} = $newvolid;
    $disk->{size} = $size;

    return $disk;
}

# this only works if VM is running
sub get_current_qemu_machine {
    my ($vmid) = @_;

    my $cmd = { execute => 'query-machines', arguments => {} };
    my $res = vm_qmp_command($vmid, $cmd);

    my ($current, $default);
    foreach my $e (@$res) {
	$default = $e->{name} if $e->{'is-default'};
	$current = $e->{name} if $e->{'is-current'};
    }

    # fallback to the default machine if current is not supported by qemu
    return $current || $default || 'pc';
}

sub get_running_qemu_version {
    my ($vmid) = @_;
    my $cmd = { execute => 'query-version', arguments => {} };
    my $res = vm_qmp_command($vmid, $cmd);
    return "$res->{qemu}->{major}.$res->{qemu}->{minor}";
}

sub qemu_machine_feature_enabled {
    my ($machine, $kvmver, $version_major, $version_minor) = @_;

    my $current_major;
    my $current_minor;

    if ($machine && $machine =~ m/^((?:pc(-i440fx|-q35)?|virt)-(\d+)\.(\d+))/) {

	$current_major = $3;
	$current_minor = $4;

    } elsif ($kvmver =~ m/^(\d+)\.(\d+)/) {

	$current_major = $1;
	$current_minor = $2;
    }

    return 1 if $current_major > $version_major ||
                ($current_major == $version_major &&
                 $current_minor >= $version_minor);
}

sub qemu_machine_pxe {
    my ($vmid, $conf) = @_;

    my $machine =  PVE::QemuServer::get_current_qemu_machine($vmid);

    if ($conf->{machine} && $conf->{machine} =~ m/\.pxe$/) {
	$machine .= '.pxe';
    }

    return $machine;
}

sub qemu_use_old_bios_files {
    my ($machine_type) = @_;

    return if !$machine_type;

    my $use_old_bios_files = undef;

    if ($machine_type =~ m/^(\S+)\.pxe$/) {
        $machine_type = $1;
        $use_old_bios_files = 1;
    } else {
	my $kvmver = kvm_user_version();
        # Note: kvm version < 2.4 use non-efi pxe files, and have problems when we
        # load new efi bios files on migration. So this hack is required to allow
        # live migration from qemu-2.2 to qemu-2.4, which is sometimes used when
        # updrading from proxmox-ve-3.X to proxmox-ve 4.0
	$use_old_bios_files = !qemu_machine_feature_enabled ($machine_type, $kvmver, 2, 4);
    }

    return ($use_old_bios_files, $machine_type);
}

sub create_efidisk($$$$$) {
    my ($storecfg, $storeid, $vmid, $fmt, $arch) = @_;

    my (undef, $ovmf_vars) = get_ovmf_files($arch);
    die "EFI vars default image not found\n" if ! -f $ovmf_vars;

    my $vars_size = PVE::Tools::convert_size(-s $ovmf_vars, 'b' => 'kb');
    my $volid = PVE::Storage::vdisk_alloc($storecfg, $storeid, $vmid, $fmt, undef, $vars_size);
    PVE::Storage::activate_volumes($storecfg, [$volid]);

    my $path = PVE::Storage::path($storecfg, $volid);
    eval {
	run_command(['/usr/bin/qemu-img', 'convert', '-n', '-f', 'raw', '-O', $fmt, $ovmf_vars, $path]);
    };
    die "Copying EFI vars image failed: $@" if $@;

    return ($volid, $vars_size);
}

sub vm_iothreads_list {
    my ($vmid) = @_;

    my $res = vm_mon_cmd($vmid, 'query-iothreads');

    my $iothreads = {};
    foreach my $iothread (@$res) {
	$iothreads->{ $iothread->{id} } = $iothread->{"thread-id"};
    }

    return $iothreads;
}

sub scsihw_infos {
    my ($conf, $drive) = @_;

    my $maxdev = 0;

    if (!$conf->{scsihw} || ($conf->{scsihw} =~ m/^lsi/)) {
        $maxdev = 7;
    } elsif ($conf->{scsihw} && ($conf->{scsihw} eq 'virtio-scsi-single')) {
        $maxdev = 1;
    } else {
        $maxdev = 256;
    }

    my $controller = int($drive->{index} / $maxdev);
    my $controller_prefix = ($conf->{scsihw} && $conf->{scsihw} eq 'virtio-scsi-single') ? "virtioscsi" : "scsihw";

    return ($maxdev, $controller, $controller_prefix);
}

sub add_hyperv_enlightenments {
    my ($cpuFlags, $winversion, $machine_type, $kvmver, $bios, $gpu_passthrough, $hv_vendor_id) = @_;

    return if $winversion < 6;
    return if $bios && $bios eq 'ovmf' && $winversion < 8;

    if ($gpu_passthrough || defined($hv_vendor_id)) {
	$hv_vendor_id //= 'proxmox';
	push @$cpuFlags , "hv_vendor_id=$hv_vendor_id";
    }

    if (qemu_machine_feature_enabled ($machine_type, $kvmver, 2, 3)) {
	push @$cpuFlags , 'hv_spinlocks=0x1fff';
	push @$cpuFlags , 'hv_vapic';
	push @$cpuFlags , 'hv_time';
    } else {
	push @$cpuFlags , 'hv_spinlocks=0xffff';
    }

    if (qemu_machine_feature_enabled ($machine_type, $kvmver, 2, 6)) {
	push @$cpuFlags , 'hv_reset';
	push @$cpuFlags , 'hv_vpindex';
	push @$cpuFlags , 'hv_runtime';
    }

    if ($winversion >= 7) {
	push @$cpuFlags , 'hv_relaxed';

	if (qemu_machine_feature_enabled ($machine_type, $kvmver, 2, 12)) {
	    push @$cpuFlags , 'hv_synic';
	    push @$cpuFlags , 'hv_stimer';
	}

	if (qemu_machine_feature_enabled ($machine_type, $kvmver, 3, 1)) {
	    push @$cpuFlags , 'hv_ipi';
	}
    }
}

sub windows_version {
    my ($ostype) = @_;

    return 0 if !$ostype;

    my $winversion = 0;

    if($ostype eq 'wxp' || $ostype eq 'w2k3' || $ostype eq 'w2k') {
        $winversion = 5;
    } elsif($ostype eq 'w2k8' || $ostype eq 'wvista') {
        $winversion = 6;
    } elsif ($ostype =~ m/^win(\d+)$/) {
        $winversion = $1;
    }

    return $winversion;
}

sub resolve_dst_disk_format {
	my ($storecfg, $storeid, $src_volname, $format) = @_;
	my ($defFormat, $validFormats) = PVE::Storage::storage_default_format($storecfg, $storeid);

	if (!$format) {
	    # if no target format is specified, use the source disk format as hint
	    if ($src_volname) {
		my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
		$format = qemu_img_format($scfg, $src_volname);
	    } else {
		return $defFormat;
	    }
	}

	# test if requested format is supported - else use default
	my $supported = grep { $_ eq $format } @$validFormats;
	$format = $defFormat if !$supported;
	return $format;
}

sub resolve_first_disk {
    my $conf = shift;
    my @disks = PVE::QemuServer::valid_drive_names();
    my $firstdisk;
    foreach my $ds (reverse @disks) {
	next if !$conf->{$ds};
	my $disk = PVE::QemuServer::parse_drive($ds, $conf->{$ds});
	next if PVE::QemuServer::drive_is_cdrom($disk);
	$firstdisk = $ds;
    }
    return $firstdisk;
}

sub generate_uuid {
    my ($uuid, $uuid_str);
    UUID::generate($uuid);
    UUID::unparse($uuid, $uuid_str);
    return $uuid_str;
}

sub generate_smbios1_uuid {
    return "uuid=".generate_uuid();
}

sub nbd_stop {
    my ($vmid) = @_;

    vm_mon_cmd($vmid, 'nbd-server-stop');
}

# bash completion helper

sub complete_backup_archives {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Storage::config();

    my $storeid;

    if ($cvalue =~ m/^([^:]+):/) {
	$storeid = $1;
    }

    my $data = PVE::Storage::template_list($cfg, $storeid, 'backup');

    my $res = [];
    foreach my $id (keys %$data) {
	foreach my $item (@{$data->{$id}}) {
	    next if $item->{format} !~ m/^vma\.(gz|lzo)$/;
	    push @$res, $item->{volid} if defined($item->{volid});
	}
    }

    return $res;
}

my $complete_vmid_full = sub {
    my ($running) = @_;

    my $idlist = vmstatus();

    my $res = [];

    foreach my $id (keys %$idlist) {
	my $d = $idlist->{$id};
	if (defined($running)) {
	    next if $d->{template};
	    next if $running && $d->{status} ne 'running';
	    next if !$running && $d->{status} eq 'running';
	}
	push @$res, $id;

    }
    return $res;
};

sub complete_vmid {
    return &$complete_vmid_full();
}

sub complete_vmid_stopped {
    return &$complete_vmid_full(0);
}

sub complete_vmid_running {
    return &$complete_vmid_full(1);
}

sub complete_storage {

    my $cfg = PVE::Storage::config();
    my $ids = $cfg->{ids};

    my $res = [];
    foreach my $sid (keys %$ids) {
	next if !PVE::Storage::storage_check_enabled($cfg, $sid, undef, 1);
	next if !$ids->{$sid}->{content}->{images};
	push @$res, $sid;
    }

    return $res;
}

1;
