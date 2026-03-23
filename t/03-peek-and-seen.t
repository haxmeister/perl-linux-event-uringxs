use v5.36;
use Test::More;

use Linux::Event::UringXS;

my $ring = Linux::Event::UringXS->new(8);

my @none = $ring->peek_cqe;
is(scalar(@none), 0, 'peek_cqe returns empty list when no completion is ready');

my $sqe = $ring->get_sqe;
ok($sqe, 'got sqe');

$ring->prep_nop($sqe);
$ring->sqe_set_data64($sqe, 77);

my $submitted = $ring->submit;
ok($submitted >= 0, 'submit returned non-negative');

my ($data, $res, $flags) = $ring->peek_cqe;
is($data, 77, 'peek_cqe got expected data64');
is($res, 0, 'peek_cqe got expected res');
ok(defined $flags, 'peek_cqe got flags');

my $err;
{
    local $@;
    eval { $ring->peek_cqe };
    $err = $@;
}
like($err, qr/current CQE has not been marked seen/, 'second peek without seen croaks');

$ring->cqe_seen;
pass('cqe_seen after peek succeeded');

$err = undef;
{
    local $@;
    eval { $ring->cqe_seen };
    $err = $@;
}
like($err, qr/no current CQE to mark seen/, 'double cqe_seen croaks');

done_testing;
