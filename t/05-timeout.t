use v5.36;
use Test::More;

use Linux::Event::UringXS;

my $ring = Linux::Event::UringXS->new(8);

my $sqe = $ring->get_sqe;
ok($sqe, 'got timeout sqe');

$ring->prep_timeout($sqe, 0, 10_000_000, 0, 0);
$ring->sqe_set_data64($sqe, 3001);

my $submitted = $ring->submit;
ok($submitted >= 0, 'submit returned non-negative');

my ($data, $res, $flags) = $ring->wait_cqe;
is($data, 3001, 'timeout data64 round-tripped');
is($res, -62, 'timeout completed with -ETIME');
ok(defined $flags, 'got timeout flags');

$ring->cqe_seen;
pass('timeout cqe_seen succeeded');

done_testing;
