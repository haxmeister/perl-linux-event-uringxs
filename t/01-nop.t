use v5.36;
use Test::More;

use Linux::Event::UringXS;

my $ring = Linux::Event::UringXS->new(8);
ok($ring, 'created ring');

my $sqe = $ring->get_sqe;
ok($sqe, 'got sqe');

$ring->prep_nop($sqe);
$ring->sqe_set_data64($sqe, 12345);

my $submitted = $ring->submit;
ok($submitted >= 0, 'submit returned non-negative');

my ($data, $res, $flags) = $ring->wait_cqe;

is($data, 12345, 'user_data round-tripped');
is($res, 0, 'nop completed successfully');
ok(defined $flags, 'got flags');

$ring->cqe_seen;

pass('cqe_seen succeeded');

done_testing;
