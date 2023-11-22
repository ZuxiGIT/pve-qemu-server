package PVE::IntegrityControlConfig;

use strict;
use warnings;

use PVE::AbstractConfig;
use base qw(PVE::AbstractConfig);

my $nodename = PVE::INotify::nodename();
mkdir "/etc/pve/nodes/$nodename/qemu-server/integrity-control/";

sub cfs_config_path {
    my ($class, $vmid, $node) = @_;

    $node = $nodename if !$node;
    return "nodes/$node/qemu-server/integrity-control/$vmid.conf";
}

1;
