use v5.36;
use Test::More;

use Linux::Event::UringXS;

my $ring = Linux::Event::UringXS->new(16);

is($ring->sqe_ready_count, 0, 'sqe_ready_count starts at zero');

for my $token (101, 102, 103) {
    my $sqe = $ring->get_sqe;
    ok($sqe, "got sqe for token $token");
    $ring->prep_nop($sqe);
    $ring->sqe_set_data64($sqe, $token);
}

is($ring->sqe_ready_count, 3, 'sqe_ready_count reflects queued SQEs before submit');

my $submitted = $ring->submit_and_wait_min(1);
ok($submitted >= 0, 'submit_and_wait_min returned non-negative');

my @triples = $ring->reap_many(3);
is(scalar(@triples), 9, 'reap_many returned three flat triples');

my @seen;
while (@triples) {
    my ($data, $res, $flags) = splice @triples, 0, 3;
    push @seen, $data;
    is($res, 0, "completion $data has zero result");
    ok(defined $flags, "completion $data returned flags");
}

is_deeply(\@seen, [101, 102, 103], 'reap_many preserves CQE order for simple batch');

my $sqe = $ring->get_sqe;
ok($sqe, 'got sqe for reap_one');
$ring->prep_nop($sqe);
$ring->sqe_set_data64($sqe, 201);

my @one = $ring->reap_one;
is_deeply(\@one, [201, 0, 0], 'reap_one returns a single flat triple');

is($ring->sqe_ready_count, 0, 'sqe_ready_count returns to zero after submit/reap');

done_testing;
