use v5.36;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::UringXS;

my $ring = Linux::Event::UringXS->new(16);

my @none = $ring->reap_ready_many(8);
is(scalar(@none), 0, 'reap_ready_many returns empty list when no CQEs are ready');

for my $token (19_101, 19_102, 19_103) {
    my $sqe = $ring->get_sqe;
    ok($sqe, "got sqe for token $token");
    $ring->prep_nop($sqe);
    $ring->sqe_set_data64($sqe, $token);
}

my $submitted = $ring->submit;
ok($submitted >= 0, 'submit returned non-negative for nop batch');

my @ready = $ring->reap_ready_many(3);
is(scalar(@ready), 9, 'reap_ready_many reaped three ready nop completions');

my @seen;
while (@ready) {
    my ($data, $res, $flags) = splice @ready, 0, 3;
    push @seen, $data;
    is($res, 0, "completion $data has zero result");
    ok(defined $flags, "completion $data returned flags");
}

is_deeply(\@seen, [19_101, 19_102, 19_103], 'reap_ready_many preserves CQE order');

socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
or die "socketpair failed: $!";

my $buf = "\0" x 32;
my $sqe = $ring->get_sqe;
ok($sqe, 'got sqe for pending recv');
$ring->prep_recv($sqe, fileno($left), $buf, 32, 0);
$ring->sqe_set_data64($sqe, 19_201);

$submitted = $ring->submit;
ok($submitted >= 0, 'submit returned non-negative for pending recv');

@none = $ring->reap_ready_many(8);
is(scalar(@none), 0, 'reap_ready_many stays nonblocking with inflight but not-ready work');
is($buf, "\0" x 32, 'buffer is unchanged before recv completion');

my $payload = "hello from reap_ready_many";
my $bytes = syswrite($right, $payload);
is($bytes, length($payload), 'wrote payload to peer');

@ready = $ring->reap_ready_many(8);
is_deeply(\@ready, [19_201, length($payload), 0], 'reap_ready_many returns recv completion once ready');
is(substr($buf, 0, length($payload)), $payload, 'recv buffer updated before completion is returned');

close $left;
close $right;

done_testing;
