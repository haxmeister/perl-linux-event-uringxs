use v5.36;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::UringXS;

my $ring = Linux::Event::UringXS->new(16);
ok($ring, 'created ring');

socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
  or die "socketpair failed: $!";

my $rc = $ring->register_files([ fileno($left), fileno($right) ]);
ok($rc >= 0, 'registered fixed files for socketpair');

my $recv_buf = "\0" x 128;
my $send_buf = 'fixed-file hello';

my $recv_sqe = $ring->get_sqe;
ok($recv_sqe, 'got fixed-file recv sqe');
$ring->prep_recv($recv_sqe, 0, $recv_buf, length($send_buf), 0);
$ring->sqe_set_flags($recv_sqe, Linux::Event::UringXS::IOSQE_FIXED_FILE());
$ring->sqe_set_data64($recv_sqe, 12_001);

my $send_sqe = $ring->get_sqe;
ok($send_sqe, 'got fixed-file send sqe');
$ring->prep_send($send_sqe, 1, $send_buf, length($send_buf), 0);
$ring->sqe_set_flags($send_sqe, Linux::Event::UringXS::IOSQE_FIXED_FILE());
$ring->sqe_set_data64($send_sqe, 12_002);

my $submitted = $ring->submit;
ok($submitted >= 0, 'submitted fixed-file recv/send pair');

my %seen;
for (1 .. 2) {
    my ($data, $res, $flags) = $ring->wait_cqe;
    $seen{$data} = [$res, $flags];
    $ring->cqe_seen;
}

ok(exists $seen{12_001}, 'saw fixed-file recv completion');
ok(exists $seen{12_002}, 'saw fixed-file send completion');
is($seen{12_002}[0], length($send_buf), 'fixed-file send completion length matches');
is($seen{12_001}[0], length($send_buf), 'fixed-file recv completion length matches');
is(substr($recv_buf, 0, $seen{12_001}[0]), $send_buf, 'fixed-file recv buffer contains sent payload');

$rc = $ring->unregister_files;
ok($rc >= 0, 'unregistered fixed files');

close $left;
close $right;

done_testing;
