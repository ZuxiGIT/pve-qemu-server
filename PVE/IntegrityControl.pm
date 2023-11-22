package PVE::IntegrityControl;
use Data::Dumper;

use strict;
use warnings;
use PVE::QemuServer::Drive;
use PVE::IntegrityControlConfig;
use Sys::Guestfs;

sub check {
    my ($storecfg, $conf, $vmid) = @_;
    print "conf: ", Dumper($conf);
    print "storecfg: ", Dumper($storecfg);
    print "vmid: ", Dumper($vmid);

    my $bootdisks = PVE::QemuServer::Drive::get_bootdisks($conf);
    my $g = new Sys::Guestfs();

    for my $bootdisk (@$bootdisks) {
        next if !PVE::QemuServer::Drive::is_valid_drivename($bootdisk);
        print "bootdisk $bootdisk\n";
        my $drive = PVE::QemuServer::Drive::parse_drive($bootdisk, $conf->{$bootdisk});
        next if !defined($drive);
        next if PVE::QemuServer::Drive::drive_is_cdrom($drive);
        my $volid = $drive->{file};
        next if !$volid;
	    my ($size, $format, undef, undef) =  PVE::Storage::volume_size_info($storecfg, $volid);
        my $diskformat = $format;
	    my ($storeid, $storevolume) = PVE::Storage::parse_volume_id($volid, 1);
	    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
        print "path: ", my $diskpath = PVE::Storage::path($storecfg, $drive->{file}), "\n";

        print "scfg: ", Dumper($scfg), "\n";
        print "drive: ", Dumper($drive), "\n";
        print "volid: ", Dumper($volid), "\n";


        # Attach the disk image read-only to libguestfs.
        # You could also add an optional format => ... argument here.  This is
        # advisable since automatic format detection is insecure.
        $g->add_drive ($diskpath, readonly => 1, format => $diskformat);
    }

    # Run the libguestfs back-end.
    $g->launch ();

    # Ask libguestfs to inspect for operating systems.
    my @roots = $g->inspect_os ();
    if (@roots == 0) {
        print "inspect_vm: no operating systems found in \"" . join(", ", @$bootdisks) . "\"\n";
        return;
    }

    my %ic_files = PVE::IntegrityControlConfig->load_config($vmid);

    for my $root (@roots) {
        printf "Root device: %s\n", $root;

        # Print basic information about the operating system.
        printf "  Product name: %s\n", $g->inspect_get_product_name ($root);
        printf "  Version:      %d.%d\n",
            $g->inspect_get_major_version ($root),
            $g->inspect_get_minor_version ($root);
        printf "  Type:         %s\n", $g->inspect_get_type ($root);
        printf "  Distro:       %s\n", $g->inspect_get_distro ($root);

        # Mount up the disks, like guestfish -i.
        #
        # Sort keys by length, shortest first, so that we end up
        # mounting the filesystems in the correct order.
        my %mps = $g->inspect_get_mountpoints ($root);
        my @mps = sort { length $a <=> length $b } (keys %mps);
        for my $mp (@mps) {
            eval { $g->mount_ro ($mps{$mp}, $mp) };
            if ($@) {
                print "$@ (ignored)\n"
            }
        }
        # If /etc/issue.net file exists, print up to 3 lines.
        my $filename = "/etc/issue.net";
        if ($g->is_file ($filename)) {
            printf "--- %s ---\n", $filename;
            my @lines = $g->head_n (3, $filename);
            print "$_\n" foreach @lines;
        }

        # Unmount everything.
        $g->umount_all ()
    }



    # print "storecfg", Dumper($storecfg);
    # print "conf: ", Dumper($conf);
}

1;
