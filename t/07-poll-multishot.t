use v5.36;
use Test::More;
use IO::Poll qw(POLLIN);

use Linux::Event::UringXS;

pipe(my $r, my $w) or die "pipe failed: $!";

my $ring = Linux::Event::UringXS->new(16);

my $sqe = $ring->get_sqe;
ok($sqe, 'got multishot poll sqe');

$ring->prep_poll_multishot($sqe, fileno($r), POLLIN);
$ring->sqe_set_data64($sqe, 7001);

my $submitted = $ring->submit;
ok($submitted >= 0, 'submitted multishot poll');

syswrite($w, "a") == 1 or die "write 1 failed: $!";
my ($d1, $r1, $f1) = $ring->wait_cqe;
is($d1, 7001, 'first completion has expected user_data');
ok(($r1 & POLLIN) == POLLIN, 'first completion reports POLLIN');
ok(($f1 & Linux::Event::UringXS::IORING_CQE_F_MORE()) != 0, 'first completion has MORE');
$ring->cqe_seen;

sysread($r, my $tmp1, 1) == 1 or die "read 1 failed: $!";

syswrite($w, "b") == 1 or die "write 2 failed: $!";
my ($d2, $r2, $f2) = $ring->wait_cqe;
is($d2, 7001, 'second completion has expected user_data');
ok(($r2 & POLLIN) == POLLIN, 'second completion reports POLLIN');
ok(($f2 & Linux::Event::UringXS::IORING_CQE_F_MORE()) != 0, 'second completion has MORE');
$ring->cqe_seen;

sysread($r, my $tmp2, 1) == 1 or die "read 2 failed: $!";

my $cancel = $ring->get_sqe;
ok($cancel, 'got cancel sqe');
$ring->prep_cancel64($cancel, 7001);
$ring->sqe_set_data64($cancel, 7002);

$submitted = $ring->submit;
ok($submitted >= 0, 'submitted cancel');

my %seen;
for (1 .. 2) {
    my ($data, $res, $flags) = $ring->wait_cqe;
    $seen{$data} = [$res, $flags];
    $ring->cqe_seen;
}

ok(exists $seen{7002}, 'saw cancel completion');
is($seen{7002}[0], 0, 'cancel request succeeded');

ok(exists $seen{7001}, 'saw final multishot completion');
ok($seen{7001}[0] < 0, 'final multishot completion is negative after cancel');
ok(($seen{7001}[1] & Linux::Event::UringXS::IORING_CQE_F_MORE()) == 0, 'final multishot completion has no MORE');

done_testing;
