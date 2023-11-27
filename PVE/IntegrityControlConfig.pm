package PVE::IntegrityControlConfig;

use strict;
use warnings;

use PVE::AbstractConfig;
use PVE::Tools;
use PVE::Cluster;
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
    my ($filename, $conf) = @_;

    my $raw = '';
    foreach my $file (sort keys %$conf) {
       my $hash = $conf->{$file};
       $raw .= "$file $hash\n";
    }

    return $raw;
}

sub create_config {
    my ($class, $vmid, $node) = @_;

    my $cfspath = $class->cfs_config_path($vmid);

	$class->write_config($vmid, {});
}

sub update_file_database {
    my ($vmid, $leave, $delete) = @_;

    my $files_hashes = PVE::IntegrityControlConfig->load_config($vmid);

    foreach my $file (@$delete) {
        delete $files_hashes->{$file};
    }

    foreach my $file (@$leave) {
        $files_hashes->{$file} = '';
    }

    PVE::IntegrityControlConfig->write_config($vmid, $files_hashes);
}

sub update_ic_config {
    my ($vmid, $old_conf, $new_conf) = @_;

    my @old_files = PVE::Tools::split_list($old_conf->{files});
    my @new_files = PVE::Tools::split_list($new_conf->{files});

    # converting old ic files' array into hash
    my %conf = map { $_ => $old_conf->{enable} } @old_files;

    # filling the conf with all files from both configs with tag equal 'enable' option
    foreach my $new_file (@new_files) {
        $conf{$new_file} = $new_conf->{enable};
    }

    # files to leave (with '1' tag)
    my $leave = [];
    foreach my $file (keys %conf) {
        push @$leave, $file if $conf{$file};
    }

    # files to delete (with '0' tag)
    my $delete = [];
    foreach my $file (keys %conf) {
        push @$delete, $file unless $conf{$file};
    }

    update_file_database($vmid, $leave, $delete);

    my $res = scalar(@$leave) > 0 ?
        PVE::JSONSchema::print_property_string(
        {
            enable => 1,
            files => join(';', @$leave)
        }, 'pve-qm-integrity-control')
        :
        PVE::JSONSchema::print_property_string(
        {
            enable => 0,
        }, 'pve-qm-integrity-control');

    return $res;
}

1;
