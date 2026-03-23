use v5.36;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::UringXS;

my $ring = Linux::Event::UringXS->new(16);
ok($ring, 'created ring');

socketpair(my $left_a, my $right_a, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
  or die "socketpair A failed: $!";
socketpair(my $left_b, my $right_b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
  or die "socketpair B failed: $!";

my $rc = $ring->register_files([ fileno($left_a) ]);
ok($rc >= 0, 'registered initial fixed-file slot');

my $buf_a = "\0" x 32;
syswrite($right_a, 'A') == 1 or die "write A failed: $!";

my $read_a = $ring->get_sqe;
ok($read_a, 'got first fixed-file read sqe');
$ring->prep_recv($read_a, 0, $buf_a, 1, 0);
$ring->sqe_set_flags($read_a, Linux::Event::UringXS::IOSQE_FIXED_FILE());
$ring->sqe_set_data64($read_a, 13_001);

my $submitted = $ring->submit;
ok($submitted >= 0, 'submitted first fixed-file read');

my ($data, $res, $flags) = $ring->wait_cqe;
is($data, 13_001, 'first fixed-file read completion has expected user_data');
is($res, 1, 'first fixed-file read completed with one byte');
is(substr($buf_a, 0, 1), 'A', 'slot 0 initially reads from socketpair A');
$ring->cqe_seen;

$rc = $ring->register_files_update(0, [ fileno($left_b) ]);
ok($rc >= 0, 'updated fixed-file slot 0 to socketpair B');

my $buf_b = "\0" x 32;
syswrite($right_b, 'B') == 1 or die "write B failed: $!";

my $read_b = $ring->get_sqe;
ok($read_b, 'got second fixed-file read sqe');
$ring->prep_recv($read_b, 0, $buf_b, 1, 0);
$ring->sqe_set_flags($read_b, Linux::Event::UringXS::IOSQE_FIXED_FILE());
$ring->sqe_set_data64($read_b, 13_002);

$submitted = $ring->submit;
ok($submitted >= 0, 'submitted second fixed-file read after update');

($data, $res, $flags) = $ring->wait_cqe;
is($data, 13_002, 'second fixed-file read completion has expected user_data');
is($res, 1, 'second fixed-file read completed with one byte');
is(substr($buf_b, 0, 1), 'B', 'slot 0 reads from socketpair B after update');
$ring->cqe_seen;

my $peek = $ring->peek_cqe;
ok(!defined($peek), 'no unexpected extra completion after slot update');

$rc = $ring->unregister_files;
ok($rc >= 0, 'unregistered fixed files');

close $left_a;
close $right_a;
close $left_b;
close $right_b;

done_testing;
