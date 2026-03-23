#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;
use Time::HiRes qw(time);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::UringXS;

my $iters = shift(@ARGV) // 100_000;
my $entries = shift(@ARGV) // 256;

sub now () { time() }

sub run_nop_bench ($iters, $entries) {
    my $ring = Linux::Event::UringXS->new($entries);

    my $submitted = 0;
    my $completed = 0;
    my $start = now();

    while ($completed < $iters) {
        while ($submitted < $iters) {
            my $sqe = $ring->get_sqe or last;
            $ring->prep_nop($sqe);
            $ring->sqe_set_data64($sqe, $submitted + 1);
            $submitted++;
        }

        my $rc = $ring->submit;
        die "submit failed: $rc" if $rc < 0;

        while (1) {
            my @cqe = $ring->peek_cqe;
            last unless @cqe;
            $completed++;
            $ring->cqe_seen;
        }

        if ($completed < $submitted) {
            my @cqe = $ring->wait_cqe;
            $completed++;
            $ring->cqe_seen;
        }
    }

    my $elapsed = now() - $start;
    return ($elapsed, $iters / ($elapsed || 1e-9));
}


sub run_pipe_bench ($iters, $entries) {
    pipe(my $r, my $w) or die "pipe failed: $!";

    my $ring = Linux::Event::UringXS->new($entries);
    my $msg = "ping";
    my $len = length($msg);

    my $write_posted = 0;
    my $read_done    = 0;
    my $inflight     = 0;

    my $start = now();

    while ($read_done < $iters) {
        my $queued = 0;

        while (
            $write_posted < $iters
            && $inflight < ($entries / 2)
            && $ring->sq_space_left >= 2
        ) {
            my $read_buf = "\0" x $len;
            my $id = $write_posted + 1;

            my $rsqe = $ring->get_sqe
                or die "expected read sqe";
            my $wsqe = $ring->get_sqe
                or die "expected write sqe";

            $ring->prep_read($rsqe, fileno($r), $read_buf, $len, 0);
            $ring->sqe_set_data64($rsqe, ($id << 1) | 1);

            $ring->prep_write($wsqe, fileno($w), $msg, $len, 0);
            $ring->sqe_set_data64($wsqe, ($id << 1));

            $write_posted++;
            $inflight++;
            $queued += 2;
        }

        if ($queued) {
            my $rc = $ring->submit;
            die "submit failed: $rc" if $rc < 0;
        }

        my $made_progress = 0;

        while (1) {
            my @cqe = $ring->peek_cqe;
            last unless @cqe;

            my ($data, $res, $flags) = @cqe;

            die "completion error: $res" if $res < 0;
            die "short completion: $res" if $res != $len;

            if ($data & 1) {
                $read_done++;
                $inflight--;
            }

            $ring->cqe_seen;
            $made_progress = 1;
        }

        last if $read_done >= $iters;

        next if $made_progress;

        die "deadlock: no inflight operations and no completions"
            if $inflight <= 0;

        my ($data, $res, $flags) = $ring->wait_cqe;
        die "completion error: $res" if $res < 0;
        die "short completion: $res" if $res != $len;

        if ($data & 1) {
            $read_done++;
            $inflight--;
        }

        $ring->cqe_seen;
    }

    my $elapsed = now() - $start;
    return ($elapsed, $iters / ($elapsed || 1e-9));
}

sub run_socketpair_bench ($iters, $entries) {
    socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair failed: $!";

    my $ring = Linux::Event::UringXS->new($entries);
    my $msg = "ping";
    my $len = length($msg);

    my $send_posted  = 0;
    my $recv_done    = 0;
    my $inflight     = 0;

    my $start = now();

    while ($recv_done < $iters) {

        my $queued = 0;

        while (
            $send_posted < $iters
            && $inflight < ($entries / 2)
            && $ring->sq_space_left >= 2
        ) {
            my $recv_buf = "\0" x $len;

            my $rsqe = $ring->get_sqe
                or die "expected recv sqe";
            my $ssqe = $ring->get_sqe
                or die "expected send sqe";

            my $id = $send_posted + 1;

            $ring->prep_recv($rsqe, fileno($left), $recv_buf, $len, 0);
            $ring->sqe_set_data64($rsqe, ($id << 1) | 1);

            $ring->prep_send($ssqe, fileno($right), $msg, $len, 0);
            $ring->sqe_set_data64($ssqe, ($id << 1));

            $send_posted++;
            $inflight++;
            $queued += 2;
        }

        if ($queued) {
            my $rc = $ring->submit;
            die "submit failed: $rc" if $rc < 0;
        }

        my $made_progress = 0;

        while (1) {
            my @cqe = $ring->peek_cqe;
            last unless @cqe;

            my ($data, $res, $flags) = @cqe;

            die "completion error: $res" if $res < 0;
            die "short completion: $res" if $res != $len;

            if ($data & 1) {
                $recv_done++;
                $inflight--;
            }

            $ring->cqe_seen;
            $made_progress = 1;
        }

        last if $recv_done >= $iters;

        next if $made_progress;

        die "deadlock: no inflight operations and no completions"
            if $inflight <= 0;

        my ($data, $res, $flags) = $ring->wait_cqe;
        die "completion error: $res" if $res < 0;
        die "short completion: $res" if $res != $len;

        if ($data & 1) {
            $recv_done++;
            $inflight--;
        }

        $ring->cqe_seen;
    }

    my $elapsed = now() - $start;
    return ($elapsed, $iters / ($elapsed || 1e-9));
}

my ($nop_elapsed, $nop_ops_sec) = run_nop_bench($iters, $entries);
printf "nop:        iters=%d entries=%d elapsed=%.6f ops/sec=%.2f\n",
    $iters, $entries, $nop_elapsed, $nop_ops_sec;

my ($sock_elapsed, $sock_msgs_sec) = run_socketpair_bench($iters, $entries);
printf "socketpair: iters=%d entries=%d elapsed=%.6f roundtrips/sec=%.2f\n",
    $iters, $entries, $sock_elapsed, $sock_msgs_sec;

my ($pipe_elapsed, $pipe_ops_sec) = run_pipe_bench($iters, $entries);
printf "pipe:       iters=%d entries=%d elapsed=%.6f roundtrips/sec=%.2f\n",
    $iters, $entries, $pipe_elapsed, $pipe_ops_sec;
