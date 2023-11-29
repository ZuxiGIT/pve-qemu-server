package PVE::IntegrityControlConfig;

use strict;
use warnings;
use PVE::IntegrityControlDB;
use Data::Dumper;

sub parse_ic_files_locations {
    my ($files, $noerr) = @_;

    my $res = {};
    foreach my $file (PVE::Tools::split_list($files)) {
        if ($file =~ m/^\/dev\/([a-z][a-zA-Z0-9\-\_\.]*[a-zA-Z0-9]):(.+)$/i) {

            $res->{"/dev/$1"} = [] if undef($res->{"/dev/$1"});
            push @{$res->{"/dev/$1"}}, "$2";
        } else {
            die "unable to parse ic file ID '$file'\n" . "return params: " . Dumper(@_);
        }
    }
    return $res;
}

sub parse_ic_config_str {
    my $raw = shift;
    return PVE::JSONSchema::parse_property_string('pve-qm-integrity-control', $raw);
}

sub update_ic_config {
    my ($vmid, $old_conf, $new_conf) = @_;

    my @old_files = PVE::Tools::split_list($old_conf->{files});
    my @new_files = PVE::Tools::split_list($new_conf->{files});

    # converting old ic files' array into hash
    my %conf = map { $_ => $old_conf->{enable} } @old_files;

    # when '--integrity_control 0' is passed to turn off ic for all files
    if (scalar(@new_files) == 0 && $new_conf->{enable} == 0) {
        PVE::IntegrityControlDB::update_file_database($vmid, undef, \@old_files);
        return PVE::JSONSchema::print_property_string({ enable => 0 }, 'pve-qm-integrity-control');
    } else {
        # filling the conf with all files from both configs with tag equal 'enable' option
        foreach my $new_file (@new_files) {
            $conf{$new_file} = $new_conf->{enable};
        }
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

    PVE::IntegrityControlDB::update_file_database($vmid, $leave, $delete);

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
