use v5.36;
use Test::More;

use Linux::Event::UringXS;

my $ring = Linux::Event::UringXS->new(16);

sub drain_two ($ring) {
    my %seen;
    for (1 .. 2) {
        my ($data, $res, $flags) = $ring->wait_cqe;
        $seen{$data} = [$res, $flags];
        $ring->cqe_seen;
    }
    return \%seen;
}

# cancel a pending timeout by user_data
{
    my $timeout = $ring->get_sqe;
    ok($timeout, 'got timeout sqe');

    $ring->prep_timeout($timeout, 5, 0, 0, 0);
    $ring->sqe_set_data64($timeout, 8001);

    my $cancel = $ring->get_sqe;
    ok($cancel, 'got cancel sqe');

    $ring->prep_cancel64($cancel, 8001);
    $ring->sqe_set_data64($cancel, 8002);

    my $submitted = $ring->submit;
    ok($submitted >= 0, 'submitted timeout + cancel');

    my $seen = drain_two($ring);

    ok(exists $seen->{8002}, 'saw cancel request completion');
    is($seen->{8002}[0], 0, 'cancel request succeeded');

    ok(exists $seen->{8001}, 'saw canceled target completion');
    is($seen->{8001}[0], -125, 'target completed with -ECANCELED');
}

# cancel a user_data that does not exist
{
    my $cancel = $ring->get_sqe;
    ok($cancel, 'got cancel sqe for missing target');

    $ring->prep_cancel64($cancel, 8999);
    $ring->sqe_set_data64($cancel, 8003);

    my $submitted = $ring->submit;
    ok($submitted >= 0, 'submitted missing-target cancel');

    my ($data, $res, $flags) = $ring->wait_cqe;
    is($data, 8003, 'missing-target cancel completion has expected user_data');
    is($res, -2, 'missing-target cancel returned -ENOENT');
    ok(defined $flags, 'missing-target cancel returned flags');
    $ring->cqe_seen;
}

done_testing;
