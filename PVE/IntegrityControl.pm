package PVE::IntegrityControl;
use Data::Dumper;

use strict;
use warnings;
use PVE::QemuServer::Drive;
use Sys::Guestfs;

sub check {
    my ($storecfg, $conf, $vmid) = @_;

    my $bootdisks = PVE::QemuServer::Drive::get_bootdisks($conf);
    my $path = '';
    my $diskformat = '';
    print "--------------------------\n";
    for my $bootdisk (@$bootdisks) {
        next if !PVE::QemuServer::Drive::is_valid_drivename($bootdisk);
        next if !$conf->{$bootdisk};
        print "bootdisk $bootdisk\n";
        my $drive = PVE::QemuServer::Drive::parse_drive($bootdisk, $conf->{$bootdisk});
        next if !defined($drive);
        print "drive: ", Dumper($drive), "\n";
        next if PVE::QemuServer::Drive::drive_is_cdrom($drive);
        my $volid = $drive->{file};
        next if !$volid;
        print "volid ", Dumper($volid);
	    my ($size, $format, undef, undef) =  PVE::Storage::volume_size_info($storecfg, $volid);
        print "format: $format\n";
        $diskformat = $format;
	    my ($storeid, $storevolume) = PVE::Storage::parse_volume_id($volid, 1);
        print "storevolume: $storevolume\n";
        print "storeid: $storeid\n";
	    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
        print "scfg: ", Dumper($scfg) if defined($scfg);
        print "storecfg: ", Dumper($storecfg);
        print "scfg->path: $scfg->{path}\n" if defined($scfg->{path});
        print "volid: $volid\n";
        print "drive size: $drive->{size}\n";
        print "path: ", $path = PVE::Storage::path($storecfg, $drive->{file}), "\n";
    }
    print "--------------------------\n";

    my $disk = $path;
    my $g = new Sys::Guestfs();

    # Attach the disk image read-only to libguestfs.
    # You could also add an optional format => ... argument here.  This is
    # advisable since automatic format detection is insecure.
    print __LINE__ . ": here\n";
    $g->add_drive_opts ($disk, readonly => 1, format => $diskformat);

    # Run the libguestfs back-end.
    print __LINE__ . ": here\n";
    $g->launch ();

    # Ask libguestfs to inspect for operating systems.
    print __LINE__ . ": here\n";
    my @roots = $g->inspect_os ();
    print __LINE__ . ": here\n";
    if (@roots == 0) {
        warn "inspect_vm: no operating systems found";
        return;
    }

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
