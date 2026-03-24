use v5.36;
use Test::More;
use Errno qw(EPIPE);
use Socket qw(AF_UNIX SOCK_STREAM SHUT_WR);

use Linux::Event::UringXS;

socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, 0)
    or die "socketpair failed: $!";

my $ring = Linux::Event::UringXS->new(8);

my $sqe = $ring->get_sqe;
ok($sqe, 'got shutdown sqe');

$ring->prep_shutdown($sqe, fileno($left), SHUT_WR);
$ring->sqe_set_data64($sqe, 9101);

my $submitted = $ring->submit;
ok($submitted >= 0, 'submitted shutdown');

my ($data, $res, $flags) = $ring->wait_cqe;
is($data, 9101, 'shutdown completion has expected user_data');
is($res, 0, 'shutdown completed successfully');
is($flags, 0, 'shutdown completion flags are zero');
$ring->cqe_seen;

local $SIG{PIPE} = 'IGNORE';
my $n = syswrite($left, "x");
ok(!defined($n), 'write fails after SHUT_WR');
ok($! != 0, 'write failure set errno');

close $left or die "close left failed: $!";
close $right or die "close right failed: $!";

done_testing;
