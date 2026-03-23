use v5.36;
use Test::More;

use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::UringXS;

socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
or die "socketpair failed: $!";

my $ring = Linux::Event::UringXS->new(16);

my $send_buf = "hello over uring";
my $recv_buf = "\0" x 1024;

my $recv_sqe = $ring->get_sqe;
ok($recv_sqe, 'got recv sqe');
$ring->prep_recv($recv_sqe, fileno($left), $recv_buf, 1024, 0);
$ring->sqe_set_data64($recv_sqe, 1001);

my $send_sqe = $ring->get_sqe;
ok($send_sqe, 'got send sqe');
$ring->prep_send($send_sqe, fileno($right), $send_buf, length($send_buf), 0);
$ring->sqe_set_data64($send_sqe, 1002);

my $submitted = $ring->submit;
ok($submitted >= 0, 'submit returned non-negative');

my %seen;
for (1 .. 2) {
    my ($data, $res, $flags) = $ring->wait_cqe;
    $seen{$data} = [$res, $flags];
    $ring->cqe_seen;
}

ok(exists $seen{1001}, 'saw recv completion');
ok(exists $seen{1002}, 'saw send completion');

is($seen{1002}[0], length($send_buf), 'send completion length matches');
is($seen{1001}[0], length($send_buf), 'recv completion length matches');
is(substr($recv_buf, 0, $seen{1001}[0]), $send_buf, 'recv buffer contains sent payload');

done_testing;
