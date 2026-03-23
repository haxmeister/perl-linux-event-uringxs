use v5.36;
use Test::More;

use Linux::Event::UringXS;

my $ring = Linux::Event::UringXS->new(16);

for my $token (18_101, 18_102, 18_103) {
    my $sqe = $ring->get_sqe;
    ok($sqe, "got sqe for token $token");
    $ring->prep_nop($sqe);
    $ring->sqe_set_data64($sqe, $token);
}

is($ring->sqe_ready_count, 3, 'three SQEs queued before partial reap');

my @first = $ring->reap_many(1);
is_deeply(\@first, [18_101, 0, 0], 'first reap_many(1) returns first flat triple only');

my @second = $ring->reap_many(1);
is_deeply(\@second, [18_102, 0, 0], 'second reap_many(1) returns second flat triple only');

my @third = $ring->reap_many(1);
is_deeply(\@third, [18_103, 0, 0], 'third reap_many(1) returns third flat triple only');

is($ring->sqe_ready_count, 0, 'no SQEs left queued after repeated partial reap');

done_testing;
