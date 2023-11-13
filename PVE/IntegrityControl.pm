package PVE::IntegrityControl;

sub check {
    my ($conf, $vmid) = @_;


    print "conf of $vmid:\n";
    foreach $k (keys %$conf) {
        print "$k: $conf->{$k}\n";
    }
}
1;
