use v5.36;
use Test::More;
use IO::Poll qw(POLLIN);

use Linux::Event::UringXS;

pipe(my $r, my $w) or die "pipe failed: $!";

my $ring = Linux::Event::UringXS->new(16);

my $poll_sqe = $ring->get_sqe;
ok($poll_sqe, 'got poll_add sqe');
$ring->prep_poll_add($poll_sqe, fileno($r), POLLIN);
$ring->sqe_set_data64($poll_sqe, 4001);

my $submitted = $ring->submit;
ok($submitted >= 0, 'poll_add submit returned non-negative');

my @none = $ring->peek_cqe;
is(scalar(@none), 0, 'no poll completion before fd becomes readable');

syswrite($w, "x") == 1 or die "pipe write failed: $!";

my ($data1, $res1, $flags1) = $ring->wait_cqe;
is($data1, 4001, 'poll_add completion has expected data64');
ok(($res1 & POLLIN) == POLLIN, 'poll_add completion reports POLLIN');
ok(defined $flags1, 'poll_add returned flags');
$ring->cqe_seen;

pipe(my $r2, my $w2) or die "pipe failed: $!";

my $armed_sqe = $ring->get_sqe;
ok($armed_sqe, 'got second poll_add sqe');
$ring->prep_poll_add($armed_sqe, fileno($r2), POLLIN);
$ring->sqe_set_data64($armed_sqe, 4002);

$submitted = $ring->submit;
ok($submitted >= 0, 'second poll_add submit returned non-negative');

my $remove_sqe = $ring->get_sqe;
ok($remove_sqe, 'got poll_remove sqe');
$ring->prep_poll_remove($remove_sqe, 4002);
$ring->sqe_set_data64($remove_sqe, 4003);

$submitted = $ring->submit;
ok($submitted >= 0, 'poll_remove submit returned non-negative');

my %seen;
for (1 .. 2) {
    my ($data, $res, $flags) = $ring->wait_cqe;
    $seen{$data} = [$res, $flags];
    $ring->cqe_seen;
}

ok(exists $seen{4003}, 'saw poll_remove completion');
is($seen{4003}[0], 0, 'poll_remove completion returned success');

ok(exists $seen{4002}, 'saw canceled poll_add completion');
ok($seen{4002}[0] < 0, 'canceled poll_add completion returned negative status');

done_testing;
