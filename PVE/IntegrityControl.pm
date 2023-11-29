package PVE::IntegrityControl;
use Data::Dumper;

use strict;
use warnings;
use PVE::Storage;
use PVE::QemuConfig;
use PVE::QemuServer::Drive;
use PVE::IntegrityControlConfig;
use Sys::Guestfs;

sub fill_absent_hashes {
    my ($vmid, $conf, $ic_conf_str) = @_;

    my $g = new Sys::Guestfs();

    my $ic_db = PVE::IntegrityControlDB::load_db($vmid);
    my $ic_conf = PVE::IntegrityControlConfig::parse_ic_config_str($ic_conf_str);
    my $ic_files = PVE::IntegrityControlConfig::parse_ic_files_locations($ic_conf->{files});

    my @roots = @{__get_vm_disk_roots($g, $vmid, $conf)};

    eval {
        for my $root (@roots) {
            print "skipping $root: no files to check\n" unless exists($ic_files->{$root});
            next unless exists($ic_files->{$root});

            __mount_vm_disk_fs($g, $root);

            for my $filename (@{$ic_files->{$root}}) {
                my $db_checksum = \$ic_db->{"$root:$filename"};
                next unless $$db_checksum eq "";

                die "failed to find file $root:$filename\n" unless $g->is_file ($filename);

                $$db_checksum = $g->checksum("sha256", $filename);
            }

            # delete after processing files in the disk's partitions
            delete $ic_files->{$root};

            # Unmount everything.
            $g->umount_all ()
        }

        if (scalar(keys %$ic_files) > 0) {
            die "failed to compute hashes for\n" . Dumper($ic_files) . "Check the correctness of disks and paths\n";
        }
    };

    if (my $err = $@) {
        # in case of error delete files in $ic_conf_str from db
        my @delete = PVE::Tools::split_list($ic_conf->{files});
        PVE::IntegrityControlDB::update_file_database($vmid, undef, \@delete);
        die $err;
    } else {
        PVE::IntegrityControlDB::write_db($vmid, $ic_db);
    }
}

sub __mount_vm_disk_fs {
    my ($g, $root) = @_;

    # Mount up the disks
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
}

sub __get_vm_disk_roots {
    my ($g, $vmid, $conf) = @_;

    my $storecfg = PVE::Storage::config();

    my $bootdisks = PVE::QemuServer::Drive::get_bootdisks($conf);
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



        # Attach the disk image read-only to libguestfs.
        # You could also add an optional format => ... argument here.  This is
        # advisable since automatic format detection is insecure.
        $g->add_drive ($diskpath, readonly => 1, format => $diskformat);
    }

    # Run the libguestfs back-end.
    $g->launch ();

    # Ask libguestfs to inspect for operating systems.
    my @roots = $g->inspect_os ();
    die "inspect_vm: no operating systems found in \"" . join(", ", @$bootdisks) . "\"\n" if @roots == 0;

    return \@roots;
}

sub check {
    my ($vmid, $conf) = @_;


    my $g = new Sys::Guestfs();
    my @roots = @{__get_vm_disk_roots($g, $vmid, $conf)};

    my $ic_db = PVE::IntegrityControlDB::load_db($vmid);
    my $ic_conf = PVE::IntegrityControlConfig::parse_ic_config_str($conf->{integrity_control});
    my $ic_files = PVE::IntegrityControlConfig::parse_ic_files_locations($ic_conf->{files});

    for my $root (@roots) {
        print "skipping $root: no files to check\n" unless exists($ic_files->{$root});
        next unless exists($ic_files->{$root});

        printf "Root device: %s\n", $root;

        # Print basic information about the operating system.
        printf "  Product name: %s\n", $g->inspect_get_product_name ($root);
        printf "  Version:      %d.%d\n",
            $g->inspect_get_major_version ($root),
            $g->inspect_get_minor_version ($root);
        printf "  Type:         %s\n", $g->inspect_get_type ($root);
        printf "  Distro:       %s\n", $g->inspect_get_distro ($root);

        __mount_vm_disk_fs($g, $root);

        foreach my $filename (@{$ic_files->{$root}}) {
            die "failed to find file $root:$filename\n" unless $g->is_file ($filename);

            my $checksum = $g->checksum("sha256", $filename);
            my $db_checksum = \$ic_db->{"$root:$filename"};

            if ($$db_checksum eq '') {
                print "added new hash $checksum for $root:$filename\n";
                $$db_checksum = $checksum;
            } elsif ($$db_checksum ne $checksum) {
                die "hash mismatch\nGot: $checksum\nReference:$$db_checksum\n";
            }
        }
        # delete hash entry if everything was okey
        delete $ic_files->{$root};

        # Unmount everything.
        $g->umount_all ()
    }

    #print __FILE__ . ":" . __LINE__ . " ic files after\n" . Dumper($ic_files);
    #print __FILE__ . ":" . __LINE__ . " db after check:\n" . Dumper($ic_db);
    if (scalar(keys %$ic_files) > 0) {
        die "Not succeded to check all files: remaining are\n" . Dumper($ic_files);
    }
    PVE::IntegrityControlDB::write_db($vmid, $ic_db);
}

1;
