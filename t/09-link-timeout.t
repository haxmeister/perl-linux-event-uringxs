use v5.36;
use strict;
use warnings;

use Test::More;
use Fcntl qw(O_NONBLOCK F_GETFL F_SETFL);

use Linux::Event::UringXS;

sub set_nonblocking ($fh) {
    my $flags = fcntl($fh, F_GETFL, 0);
    ok(defined $flags, 'got file status flags');
    my $ok = fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
    ok($ok, 'set nonblocking');
}

sub wait_one ($ring) {
    my ($data, $res, $flags) = $ring->wait_cqe;
    $ring->cqe_seen;
    return ($data, $res, $flags);
}

sub pipe_pair () {
    pipe(my $r, my $w) or die "pipe failed: $!";
    return ($r, $w);
}

sub POLLIN () { 0x0001 }

{
    my $ring = Linux::Event::UringXS->new(16);
    ok($ring, 'created ring for timeout-fires case');

    my ($r, $w) = pipe_pair();
    ok($r && $w, 'created pipe');

    set_nonblocking($r);
    set_nonblocking($w);

    my $poll = $ring->get_sqe;
    ok($poll, 'got poll sqe');

    $ring->prep_poll_add($poll, fileno($r), POLLIN);
    $ring->sqe_set_data64($poll, 9001);
    $ring->sqe_set_flags($poll, Linux::Event::UringXS::IOSQE_IO_LINK());

    my $timeout = $ring->get_sqe;
    ok($timeout, 'got link-timeout sqe');

    $ring->prep_link_timeout($timeout, 0, 100_000_000, 0);
    $ring->sqe_set_data64($timeout, 9002);

    my $submitted = $ring->submit;
    ok($submitted >= 0, 'submitted poll + linked timeout');

    my %seen;
    for (1 .. 2) {
        my ($data, $res, $flags) = wait_one($ring);
        $seen{$data} = [$res, $flags];
    }

    ok(exists $seen{9002}, 'saw link-timeout CQE');
    is($seen{9002}[0], -62, 'link-timeout completed with -ETIME');

    ok(exists $seen{9001}, 'saw poll CQE after timeout');
    ok($seen{9001}[0] < 0, 'poll completed unsuccessfully after timeout');

    close $r;
    close $w;
}

{
    my $ring = Linux::Event::UringXS->new(16);
    ok($ring, 'created ring for primary-completes-first case');

    my ($r, $w) = pipe_pair();
    ok($r && $w, 'created pipe');

    set_nonblocking($r);
    set_nonblocking($w);

    my $poll = $ring->get_sqe;
    ok($poll, 'got poll sqe');

    $ring->prep_poll_add($poll, fileno($r), POLLIN);
    $ring->sqe_set_data64($poll, 9011);
    $ring->sqe_set_flags($poll, Linux::Event::UringXS::IOSQE_IO_LINK());

    my $timeout = $ring->get_sqe;
    ok($timeout, 'got link-timeout sqe');

    $ring->prep_link_timeout($timeout, 1, 0, 0);
    $ring->sqe_set_data64($timeout, 9012);

    my $submitted = $ring->submit;
    ok($submitted >= 0, 'submitted poll + linked timeout');

    my $written = syswrite($w, "x");
    is($written, 1, 'made pipe readable');

    my %seen;
    for (1 .. 2) {
        my ($data, $res, $flags) = wait_one($ring);
        $seen{$data} = [$res, $flags];
    }

    ok(exists $seen{9011}, 'saw poll CQE');
    is($seen{9011}[0], POLLIN, 'poll completed with readable event');

    ok(exists $seen{9012}, 'saw link-timeout CQE');
    is($seen{9012}[0], -125, 'link-timeout was canceled with -ECANCELED');

    my $buf = '';
    my $n = sysread($r, $buf, 1);
    is($n, 1, 'drained one byte from pipe');
    is($buf, 'x', 'read expected byte');

    close $r;
    close $w;
}

done_testing;
