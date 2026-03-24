use v5.36;
use Test::More;
use POSIX ();
use Socket qw(AF_UNIX SOCK_STREAM pack_sockaddr_un PF_UNSPEC);

use Linux::Event::UringXS;

my $path = sprintf "/tmp/uringxs-accept-multishot-%d-%d.sock", $$, int(rand(1_000_000));
unlink $path;

socket(my $listen, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "listen socket failed: $!";
bind($listen, pack_sockaddr_un($path))
    or die "bind failed: $!";
listen($listen, 16)
    or die "listen failed: $!";

my $ring = Linux::Event::UringXS->new(16);

my $sqe = $ring->get_sqe;
ok($sqe, 'got multishot accept sqe');

$ring->prep_accept_multishot($sqe, fileno($listen), 0);
$ring->sqe_set_data64($sqe, 9001);

my $submitted = $ring->submit;
ok($submitted >= 0, 'submitted multishot accept');

socket(my $client1, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "client1 socket failed: $!";
connect($client1, pack_sockaddr_un($path))
    or die "client1 connect failed: $!";

socket(my $client2, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "client2 socket failed: $!";
connect($client2, pack_sockaddr_un($path))
    or die "client2 connect failed: $!";

my ($d1, $r1, $f1) = $ring->wait_cqe;
is($d1, 9001, 'first completion has expected user_data');
ok($r1 >= 0, 'first completion returned accepted fd');
ok(($f1 & Linux::Event::UringXS::IORING_CQE_F_MORE()) != 0, 'first completion has MORE');
$ring->cqe_seen;

my ($d2, $r2, $f2) = $ring->wait_cqe;
is($d2, 9001, 'second completion has expected user_data');
ok($r2 >= 0, 'second completion returned accepted fd');
ok($r2 != $r1, 'accepted fds are distinct');
$ring->cqe_seen;

POSIX::close($r1) or die "close accepted fd 1 failed: $!";
POSIX::close($r2) or die "close accepted fd 2 failed: $!";

my $cancel = $ring->get_sqe;
ok($cancel, 'got cancel sqe');
$ring->prep_cancel64($cancel, 9001);
$ring->sqe_set_data64($cancel, 9002);

$submitted = $ring->submit;
ok($submitted >= 0, 'submitted cancel for multishot accept');

my %seen;
for (1 .. 2) {
    my ($data, $res, $flags) = $ring->wait_cqe;
    $seen{$data} = [$res, $flags];
    $ring->cqe_seen;
}

ok(exists $seen{9002}, 'saw cancel completion');
is($seen{9002}[0], 0, 'cancel request succeeded');

ok(exists $seen{9001}, 'saw final multishot accept completion');
ok($seen{9001}[0] < 0, 'final multishot accept completion is negative after cancel');
ok(($seen{9001}[1] & Linux::Event::UringXS::IORING_CQE_F_MORE()) == 0, 'final multishot accept completion has no MORE');

close $client1 or die "close client1 failed: $!";
close $client2 or die "close client2 failed: $!";
close $listen or die "close listen failed: $!";
unlink $path;

done_testing;
