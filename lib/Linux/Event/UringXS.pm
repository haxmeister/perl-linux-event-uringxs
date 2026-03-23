package Linux::Event::UringXS;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.002';

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

1;

__END__

=head1 NAME

Linux::Event::UringXS - Thin, low-level liburing XS binding for Perl

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event::UringXS;
  use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC pack_sockaddr_in inet_aton);
  use IO::Poll qw(POLLIN);

  my $ring = Linux::Event::UringXS->new(256);

  my $buf = "\0" x 4096;

  my $sqe = $ring->get_sqe or die "no sqe";
  $ring->prep_recv($sqe, $fd, $buf, 4096, 0);
  $ring->sqe_set_data64($sqe, 123);
  $ring->submit;

  my ($data64, $res, $flags) = $ring->wait_cqe;
  $ring->cqe_seen;

  my $ts = $ring->get_sqe or die "no sqe";
  $ring->prep_timeout($ts, 0, 50_000_000);
  $ring->sqe_set_data64($ts, 124);
  $ring->submit;

=head1 DESCRIPTION

L<Linux::Event::UringXS> is a low-level XS binding to liburing.

It exposes io_uring ring mechanics with minimal policy and minimal
Perl-side overhead. It is intended as a foundation for higher-level
runtimes, not as a callback wrapper or operation framework.

=head1 METHODS

=head2 new

  my $ring = Linux::Event::UringXS->new($entries);
  my $ring = Linux::Event::UringXS->new($entries, { flags => 0 });

Create a ring.

=head2 get_sqe

  my $sqe = $ring->get_sqe;

Get an SQE handle or undef if none is currently available.

=head2 register_files

  my $rc = $ring->register_files([ $fd0, $fd1, ... ]);

Register a fixed-file table for the ring. Subsequent SQEs may address those
registered file slots by index when the SQE flags include
C<IOSQE_FIXED_FILE>.

=head2 register_files_update

  my $rc = $ring->register_files_update($offset, [ $fd0, $fd1, ... ]);

Replace a range of previously registered fixed-file slots beginning at
C<$offset>.

=head2 unregister_files

  my $rc = $ring->unregister_files;

Unregister the current fixed-file table.

=head2 prep_nop

  $ring->prep_nop($sqe);

=head2 prep_read

  $ring->prep_read($sqe, $fd, $buf, $len, $offset = 0);

=head2 prep_write

  $ring->prep_write($sqe, $fd, $buf, $len, $offset = 0);

=head2 prep_recv_multishot

  $ring->prep_recv_multishot($sqe, $fd, $len, $flags = 0);

Prepare a multishot recv request. This is intended to be used with
provided buffers and C<IOSQE_BUFFER_SELECT>. One submitted SQE may
produce multiple CQEs while the request remains active. Active multishot
recv CQEs include C<IORING_CQE_F_MORE>. When a CQE arrives without
C<IORING_CQE_F_MORE>, the multishot recv has terminated and must be
reissued if more receives are desired.

=head2 prep_recv

  $ring->prep_recv($sqe, $fd, $buf, $len, $flags = 0);

=head2 prep_send

  $ring->prep_send($sqe, $fd, $buf, $len, $flags = 0);

=head2 prep_timeout

  $ring->prep_timeout($sqe, $sec, $nsec = 0, $count = 0, $flags = 0);

Prepare a timeout request using a C<__kernel_timespec> built from whole
seconds and nanoseconds. A normal timeout completion returns C<-ETIME>.

=head2 prep_poll_add

  $ring->prep_poll_add($sqe, $fd, $mask);

Prepare a poll request for the given file descriptor and mask such as
C<POLLIN> or C<POLLOUT>.

=head2 prep_poll_multishot

  $ring->prep_poll_multishot($sqe, $fd, $mask);

Prepare a persistent multishot poll request for the given file descriptor
and mask such as C<POLLIN> or C<POLLOUT>.

Each readiness notification produces a CQE. While the request remains
active, the CQE flags include C<IORING_CQE_F_MORE>. When a CQE arrives
without C<IORING_CQE_F_MORE>, the multishot poll has terminated and must
be reissued if further notifications are desired.

=head2 prep_poll_remove

  $ring->prep_poll_remove($sqe, $target_data64);

Prepare a poll removal request targeting a previously submitted poll
request by its C<user_data> value.

=head2 prep_provide_buffers

  $ring->prep_provide_buffers($sqe, $slab, $len, $count, $bgid, $bid = 0);

Prepare an asynchronous C<IORING_OP_PROVIDE_BUFFERS> request. C<$slab> must
contain at least C<$len * $count> bytes of contiguous storage. The slab is
retained by the ring after a successful completion so that the provided
buffers remain valid until they are removed or the ring is destroyed.

=head2 prep_remove_buffers

  $ring->prep_remove_buffers($sqe, $count, $bgid);

Prepare an asynchronous C<IORING_OP_REMOVE_BUFFERS> request for a buffer
group. On successful completion, the XS layer releases the corresponding
retained provided-buffer slabs.

=head2 prep_accept

  $ring->prep_accept($sqe, $fd, $flags = 0);

Prepare an accept operation. The completion result is the accepted file
descriptor or a negative errno.

=head2 prep_connect

  $ring->prep_connect($sqe, $fd, $sockaddr);

Prepare a connect operation using a packed sockaddr scalar. The sockaddr
scalar is retained until completion.

=head2 prep_close

  $ring->prep_close($sqe, $fd);

Prepare a close operation.

=head2 prep_cancel64

  $ring->prep_cancel64($sqe, $target_data64, $flags = 0);

Prepare a cancellation request targeting a previously submitted user_data
value.

=head2 sqe_set_data64

  $ring->sqe_set_data64($sqe, $u64);

=head2 sqe_set_flags

  $ring->sqe_set_flags($sqe, $flags);

Set raw SQE flags such as C<IOSQE_IO_LINK>, C<IOSQE_FIXED_FILE>, or
C<IOSQE_BUFFER_SELECT>.

=head2 sqe_set_buf_group

  $ring->sqe_set_buf_group($sqe, $bgid);

Set the SQE buffer-group field used together with C<IOSQE_BUFFER_SELECT>.

=head2 submit

  my $n = $ring->submit;

=head2 submit_and_wait

  my $n = $ring->submit_and_wait($want);

=head2 submit_and_wait_min

  my $n = $ring->submit_and_wait_min($want);

Thin alias for C<submit_and_wait>, named to emphasize the minimum-completions
intent at the call site. This helper does not add policy or implicit flushing
beyond the underlying liburing call.

=head2 peek_cqe

  my ($data64, $res, $flags) = $ring->peek_cqe;

Returns an empty list when no completion is ready.

=head2 wait_cqe

  my ($data64, $res, $flags) = $ring->wait_cqe;

=head2 cqe_seen

  $ring->cqe_seen;

=head2 reap_one

  my ($data64, $res, $flags) = $ring->reap_one;

Submit pending SQEs, wait for at least one completion, return one completion
as a flat triple, and mark it seen before returning.

=head2 reap_many

  my @triples = $ring->reap_many($max);

Submit pending SQEs, wait for at least one completion, then drain up to
C<$max> completions. The return value is a flat list in repeating
C<($data64, $res, $flags)> order.

=head2 sqe_ready_count

  my $n = $ring->sqe_ready_count;

Return the number of SQEs currently prepared and awaiting submission.

=head2 sq_ready

  my $n = $ring->sq_ready;

=head2 sq_space_left

  my $n = $ring->sq_space_left;

=head2 cq_ready

  my $n = $ring->cq_ready;

=head2 IOSQE_FIXED_FILE

  my $mask = Linux::Event::UringXS::IOSQE_FIXED_FILE();

Return the SQE flag bit used to interpret the descriptor field as a fixed
file-table index rather than a normal file descriptor.

=head2 IOSQE_BUFFER_SELECT

  my $mask = Linux::Event::UringXS::IOSQE_BUFFER_SELECT();

Return the SQE flag bit used for kernel-selected provided buffers.

=head2 IORING_CQE_F_MORE

  my $mask = Linux::Event::UringXS::IORING_CQE_F_MORE();

Return the CQE flag bit used to indicate that a multishot request remains
active and more completions may follow.

=head2 IORING_CQE_F_BUFFER

  my $mask = Linux::Event::UringXS::IORING_CQE_F_BUFFER();

Return the CQE flag bit indicating that the completion used a kernel-selected
provided buffer.

=head2 cqe_buffer_id

  my $bid = Linux::Event::UringXS->cqe_buffer_id($flags);

Decode the selected buffer identifier from CQE flags when
C<IORING_CQE_F_BUFFER> is present.

=head1 AUTHOR

Joshua Day

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
