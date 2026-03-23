use v5.36;
use Test::More;
use IO::Poll qw(POLLIN);

use Linux::Event::UringXS;

pipe(my $r, my $w) or die "pipe failed: $!";
syswrite($w, "x") == 1 or die "pipe write failed: $!";

my $ring = Linux::Event::UringXS->new(16);

my $nop_sqe = $ring->get_sqe;
ok($nop_sqe, 'got nop sqe');
$ring->prep_nop($nop_sqe);
$ring->sqe_set_data64($nop_sqe, 17_001);

my $poll_sqe = $ring->get_sqe;
ok($poll_sqe, 'got poll_add sqe');
$ring->prep_poll_add($poll_sqe, fileno($r), POLLIN);
$ring->sqe_set_data64($poll_sqe, 17_002);

my $timeout_sqe = $ring->get_sqe;
ok($timeout_sqe, 'got timeout sqe');
$ring->prep_timeout($timeout_sqe, 0, 1_000_000, 0, 0);
$ring->sqe_set_data64($timeout_sqe, 17_003);

is($ring->sqe_ready_count, 3, 'three mixed SQEs queued before helper drain');

my %seen;
my $iterations = 0;
while (keys(%seen) < 3 && $iterations++ < 3) {
    my @triples = $ring->reap_many(3);
    ok(@triples % 3 == 0, 'reap_many returned flat triples');

    while (@triples) {
        my ($data, $res, $flags) = splice @triples, 0, 3;
        $seen{$data} = [$res, $flags];
    }
}

is(scalar(keys %seen), 3, 'saw all mixed-batch completions');

ok(exists $seen{17_001}, 'saw nop completion');
is($seen{17_001}[0], 0, 'nop completion returned success');
ok(defined $seen{17_001}[1], 'nop completion returned flags');

ok(exists $seen{17_002}, 'saw poll completion');
ok(($seen{17_002}[0] & POLLIN) == POLLIN, 'poll completion reports POLLIN');
ok(defined $seen{17_002}[1], 'poll completion returned flags');

ok(exists $seen{17_003}, 'saw timeout completion');
is($seen{17_003}[0], -62, 'timeout completion returned -ETIME');
ok(defined $seen{17_003}[1], 'timeout completion returned flags');

is($ring->sqe_ready_count, 0, 'no SQEs left queued after mixed helper drain');

done_testing;
