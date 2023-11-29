package PVE::IntegrityControlDB;

# it is a workaround to integrate a IntegrityControl database into PVE cluster fs
# a record in this db has format
# |disk:path hash|
#  ^          ^
#  |          +-- a file hash
#  +-- a file location, passed by user via command line

use strict;
use warnings;

use PVE::AbstractConfig;
use PVE::Tools;
use PVE::Cluster;
use Data::Dumper;
use base qw(PVE::AbstractConfig);

my $nodename = PVE::INotify::nodename();
mkdir "/etc/pve/nodes/$nodename/qemu-server/integrity-control/";

PVE::Cluster::cfs_register_file(
    '/qemu-server/integrity-control/',
    \&parse_ic_filedb,
    \&write_ic_filedb
);

# path where to store files' hashes
sub cfs_config_path {
    my ($class, $vmid, $node) = @_;

    $node = $nodename if !$node;
    return "nodes/$node/qemu-server/integrity-control/$vmid.conf";
}

sub parse_ic_filedb {
    my ($filename, $raw, $strict) = @_;

    return if !defined($raw);

    my $res = {};

    $filename =~ m|/qemu-server/integrity-control/(\d+)\.conf$|
	|| die "got strange filename '$filename'";

    my $vmid = $1;

    my @lines = split(/\n/, $raw);
    foreach my $line (@lines) {
	    next if $line =~ m/^\s*$/;
        my ($file, $hash) = split(/ /, $line);
        $res->{$file} = $hash;
    }
    return $res;
}

sub write_ic_filedb {
    my ($filename, $db) = @_;

    my $raw = '';
    foreach my $file (sort keys %$db) {
       my $hash = $db->{$file};
       $raw .= "$file $hash\n";
    }

    return $raw;
}

sub create_db {
    my ($class, $vmid, $node) = @_;

    my $cfspath = $class->cfs_config_path($vmid);

	$class->write_config($vmid, {});
}

sub load_db {
    my $vmid = shift;

    return PVE::IntegrityControlDB->load_config($vmid);
}

sub write_db {
    my ($vmid, $db) = @_;

    PVE::IntegrityControlDB->write_config($vmid, $db);
}

sub update_file_database {
    my ($vmid, $leave, $delete) = @_;

    my $files_hashes = load_db($vmid);

    foreach my $file (@$delete) {
        delete $files_hashes->{$file};
    }

    foreach my $file (@$leave) {
        $files_hashes->{$file} = $files_hashes->{$file} || '';
    }

    write_db($vmid, $files_hashes);
}

1;
