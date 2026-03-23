use v5.36;
use strict;
use warnings;

use Test::More;
use Socket qw(AF_UNIX SOCK_DGRAM);

use Linux::Event::UringXS;

sub reap_one ($ring, $tries = 50) {
    for (1 .. $tries) {
        $ring->submit_and_wait(1);
        my ($data, $res, $flags) = $ring->peek_cqe;
        if (defined $data) {
            $ring->cqe_seen;
            return ($data, $res, $flags);
        }
    }
    return;
}

my $ring = Linux::Event::UringXS->new(256);

socketpair(my $a, my $b, AF_UNIX, SOCK_DGRAM, 0)
or die "socketpair: $!";

my $buflen    = 256;
my $nr        = 4;
my $bgid      = 7;
my $bid_start = 100;

my $slab = "\0" x ($buflen * $nr);

# provide buffers
my $sqe = $ring->get_sqe or die "no sqe";
$ring->prep_provide_buffers($sqe, $slab, $buflen, $nr, $bgid, $bid_start);
$ring->sqe_set_data64($sqe, 1001);

my $submitted = $ring->submit;
ok($submitted >= 0, 'submitted provide_buffers');

my @pb = reap_one($ring, 50);
ok(@pb, 'got provide_buffers CQE') or BAIL_OUT('provide_buffers CQE never arrived');
my ($data, $res, $flags) = @pb;
diag("provide_buffers cqe: data=$data res=$res flags=$flags");
is($data, 1001, 'provide_buffers completion has expected user_data');
is($res, 0, 'provide_buffers succeeded');

# arm recv multishot
$sqe = $ring->get_sqe or die "no sqe";
$ring->prep_recv_multishot($sqe, fileno($a), $buflen, 0);
$ring->sqe_set_buf_group($sqe, $bgid);
$ring->sqe_set_flags($sqe, Linux::Event::UringXS::IOSQE_BUFFER_SELECT());
$ring->sqe_set_data64($sqe, 2001);

$submitted = $ring->submit;
ok($submitted >= 0, 'submitted recv_multishot');

# generate traffic
my @msgs = ('one', 'two', 'three');
for my $m (@msgs) {
    my $written = syswrite($b, $m);
    die "write failed: $!" unless defined $written && $written == length($m);
}

# reap exactly three data CQEs
my @recv;
for my $i (0 .. $#msgs) {
    my @triple = reap_one($ring, 50);
    ok(@triple, 'got recv CQE') or BAIL_OUT("recv CQE never arrived for message index $i");

    my ($d, $r, $f) = @triple;
    diag("recv cqe[$i]: data=$d res=$r flags=$f");

    is($d, 2001, 'recv completion has expected user_data');
    ok($r > 0, 'recv_multishot data completion is positive');
    ok(
        ($f & Linux::Event::UringXS::IORING_CQE_F_BUFFER()) != 0,
       'completion has BUFFER flag'
    );

    ok(
        ($f & Linux::Event::UringXS::IORING_CQE_F_MORE()) != 0,
       'data completion has MORE'
    );

    my $bid = $ring->cqe_buffer_id($f);
    ok(defined $bid, 'buffer id present');

    push @recv, {
        data  => $d,
        res   => $r,
        flags => $f,
        bid   => $bid,
    };
}

# explicitly cancel the multishot receive
$sqe = $ring->get_sqe or die "no sqe";
$ring->prep_cancel64($sqe, 2001, 0);
$ring->sqe_set_data64($sqe, 4001);

$submitted = $ring->submit;
ok($submitted >= 0, 'submitted cancel64 for recv_multishot');

my $got_cancel_cqe = 0;
my $got_target_cqe = 0;

for (1 .. 10) {
    my @triple = reap_one($ring, 50);
    ok(@triple, 'got CQE after cancel') or BAIL_OUT('cancel/target CQE never arrived');

    my ($d, $r, $f) = @triple;
    diag("post-cancel cqe: data=$d res=$r flags=$f");

    if ($d == 4001) {
        is($r, 0, 'cancel request completed successfully');
        $got_cancel_cqe = 1;
    }
    elsif ($d == 2001) {
        is($r, -125, 'target recv_multishot completed with ECANCELED');
        ok(
            ($f & Linux::Event::UringXS::IORING_CQE_F_MORE()) == 0,
           'canceled target CQE has no MORE flag'
        );
        $got_target_cqe = 1;
    }

    last if $got_cancel_cqe && $got_target_cqe;
}

ok($got_cancel_cqe, 'saw cancel CQE');
ok($got_target_cqe, 'saw canceled target CQE');

# cleanup
close $b;
close $a;

$sqe = $ring->get_sqe or die "no sqe";
$ring->prep_remove_buffers($sqe, $nr, $bgid);
$ring->sqe_set_data64($sqe, 3001);

$submitted = $ring->submit;
ok($submitted >= 0, 'submitted remove_buffers');

my @rb = reap_one($ring, 50);
ok(@rb, 'got remove_buffers CQE') or BAIL_OUT('remove_buffers CQE never arrived');
my ($rd, $rr, $rf) = @rb;
diag("remove_buffers cqe: data=$rd res=$rr flags=$rf");

is($rd, 3001, 'remove_buffers completion has expected user_data');
ok($rr >= 0, 'remove_buffers succeeded');
is($rr, 1, 'remove_buffers removed the remaining available buffer');

done_testing;
