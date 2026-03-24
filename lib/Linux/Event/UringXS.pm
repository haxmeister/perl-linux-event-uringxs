package Linux::Event::UringXS;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.004';

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

1;

__END__

=head1 NAME

Linux::Event::UringXS - thin, explicit io_uring bindings for Linux::Event

=head1 SYNOPSIS

  use v5.36;
  use Socket qw(
    AF_UNIX SOCK_STREAM SOCK_NONBLOCK
    pack_sockaddr_un
  );
  use Linux::Event::UringXS;

  my $ring = Linux::Event::UringXS->new(256);

  my $sqe = $ring->get_sqe
    or die "no SQE available";

  $ring->prep_nop($sqe);
  $ring->sqe_set_data64($sqe, 1001);

  $ring->submit;

  my ($data, $res, $flags) = $ring->wait_cqe;
  $ring->cqe_seen;

  say "data=$data res=$res flags=$flags";

Batching example:

  for my $id (1 .. 4) {
    my $sqe = $ring->get_sqe or die "no SQE available";
    $ring->prep_nop($sqe);
    $ring->sqe_set_data64($sqe, $id);
  }

  $ring->submit_and_wait_min(1);

  my @flat = $ring->reap_ready_many(64);

  while (@flat) {
    my ($data, $res, $flags) = splice @flat, 0, 3;
    say "data=$data res=$res flags=$flags";
  }

Provided-buffer multishot receive example:

  my $buf = "\0" x (4096 * 8);

  my $sqe_pb = $ring->get_sqe or die "no SQE available";
  $ring->prep_provide_buffers($sqe_pb, $buf, 4096, 8, 7, 0);
  $ring->sqe_set_data64($sqe_pb, 1001);

  my $sqe_rx = $ring->get_sqe or die "no SQE available";
  $ring->prep_recv_multishot($sqe_rx, fileno($sock), 0, 0);
  $ring->sqe_set_flags($sqe_rx, Linux::Event::UringXS::IOSQE_BUFFER_SELECT());
  $ring->sqe_set_buf_group($sqe_rx, 7);
  $ring->sqe_set_data64($sqe_rx, 2001);

  $ring->submit;

  while (1) {
    my ($data, $res, $flags) = $ring->wait_cqe;
    $ring->cqe_seen;

    last if $res < 0;

    if ($flags & Linux::Event::UringXS::IORING_CQE_F_BUFFER()) {
      my $bid = $ring->cqe_buffer_id($flags);
      say "buffer id=$bid res=$res";
    }

    last unless $flags & Linux::Event::UringXS::IORING_CQE_F_MORE();
  }

=head1 DESCRIPTION

C<Linux::Event::UringXS> is a thin XS wrapper over Linux C<io_uring>.

It exposes a kernel-shaped interface for:

- explicit SQE acquisition
- explicit operation preparation
- explicit submission
- explicit CQE retrieval
- explicit CQE acknowledgment
- registration operations
- multishot and buffer-selection features

This module is intentionally low-level. It does not implement a proactor,
reactor, callback system, futures/promises, or connection abstraction.

The design goal is simple:

  UringXS = mechanism
  everything else = policy

=head1 CONSTRUCTOR

=head2 new

  my $ring = Linux::Event::UringXS->new($entries);

Create a new ring with the specified queue depth.

Returns a ring object on success.

=head1 SUBMISSION QUEUE

=head2 get_sqe

  my $sqe = $ring->get_sqe;

Return the next available submission queue entry as a
C<Linux::Event::UringXS::SQE> object.

Returns undef if no SQE is currently available.

=head2 submit

  my $count = $ring->submit;

Submit all currently prepared SQEs to the kernel.

Returns the result from the underlying submit operation.

=head2 submit_and_wait

  my $count = $ring->submit_and_wait($want);

Submit all currently prepared SQEs and wait until at least C<$want>
completion queue entries are available.

Returns the result from the underlying submit-and-wait operation.

=head2 submit_and_wait_min

  my $count = $ring->submit_and_wait_min($want);

Thin batching helper.

Submits pending SQEs and waits until at least C<$want> completions are
available.

Returns the result from the underlying submit-and-wait operation.

=head2 sqe_ready_count

  my $n = $ring->sqe_ready_count;

Return the number of SQEs currently prepared but not yet submitted.

Useful when making explicit batching decisions.

=head2 sq_ready

  my $n = $ring->sq_ready;

Return the number of SQEs currently ready for submission.

=head2 sq_space_left

  my $n = $ring->sq_space_left;

Return the number of remaining SQE slots available for new submissions.

=head2 cq_ready

  my $n = $ring->cq_ready;

Return the number of CQEs currently ready to be consumed.

=head1 COMPLETION QUEUE

All completion-returning APIs use the kernel-shaped triple:

  ($user_data, $res, $flags)

Where:

=over 4

=item * C<$user_data>

The 64-bit value previously associated with the SQE via
C<sqe_set_data64>.

=item * C<$res>

The kernel result value for the operation. Negative values represent
negated errno values.

=item * C<$flags>

Raw CQE flags from the kernel.

=back

=head2 peek_cqe

  my ($data, $res, $flags) = $ring->peek_cqe;

Attempt to retrieve one completion queue entry without blocking.

Returns an empty list if no CQE is available.

The CQE remains outstanding until C<cqe_seen> is called.

=head2 wait_cqe

  my ($data, $res, $flags) = $ring->wait_cqe;

Wait until one completion queue entry is available, then return:

  ($data, $res, $flags)

The CQE remains outstanding until C<cqe_seen> is called.

=head2 cqe_seen

  $ring->cqe_seen;

Mark the current CQE as consumed.

This must be called after a successful C<peek_cqe> or C<wait_cqe> when
you are done with that CQE.

=head2 reap_one

  my ($data, $res, $flags) = $ring->reap_one;

Blocking batch helper.

Submits pending SQEs, waits until at least one CQE is available, then
reaps exactly one completion and returns:

  ($data, $res, $flags)

This helper consumes the CQE before returning.

=head2 reap_many

  my @flat = $ring->reap_many($max);

Blocking batch helper.

Submits pending SQEs, waits until at least one CQE is available, then
reaps up to C<$max> ready completions.

Returns a flat list of triples:

  ($data1, $res1, $flags1, $data2, $res2, $flags2, ...)

This helper consumes each returned CQE before returning.

=head2 reap_ready_many

  my @flat = $ring->reap_ready_many($max);

Nonblocking batch helper.

Reaps up to C<$max> completions that are already ready in the CQ without
submitting and without waiting.

Returns an empty list if no CQEs are ready.

Returns a flat list of triples:

  ($data1, $res1, $flags1, $data2, $res2, $flags2, ...)

This helper consumes each returned CQE before returning.

=head2 reap_one

  my ($data, $res, $flags) = $ring->reap_one;

Convenience helper that performs the equivalent of:

  $ring->submit_and_wait_min(1);
  my ($data, $res, $flags) = $ring->peek_cqe;
  $ring->cqe_seen;

Returns one completion triple.

=head2 reap_many

  my @flat = $ring->reap_many($max);

Convenience helper for explicit batch draining.

It submits pending SQEs, waits for at least one completion, then drains
up to C<$max> CQEs.

Returns a flat list of triples:

  ($data1, $res1, $flags1,
   $data2, $res2, $flags2, ...)

This flat format is intentional and avoids extra wrapper allocation in
hot paths.

=head2 cqe_buffer_id

  my $bid = $ring->cqe_buffer_id($flags);

Extract the selected buffer ID from CQE flags when
C<IORING_CQE_F_BUFFER> is present.

This is primarily used with provided buffers and multishot receive.

=head1 SQE SETUP

=head2 sqe_set_data64

  $ring->sqe_set_data64($sqe, $u64);

Associate a 64-bit user value with an SQE.

This value is later returned as the first element of the completion
triple and is the primary correlation mechanism between submission and
completion.

=head2 sqe_set_flags

  $ring->sqe_set_flags($sqe, $flags);

Set SQE flags such as C<IOSQE_IO_LINK>, C<IOSQE_FIXED_FILE>, or
C<IOSQE_BUFFER_SELECT>.

=head2 sqe_set_buf_group

  $ring->sqe_set_buf_group($sqe, $bgid);

Set the buffer group ID for buffer-selection operations.

This is typically used together with C<IOSQE_BUFFER_SELECT> and
C<prep_recv_multishot>.

=head1 PREPARATION METHODS

=head2 prep_nop

  $ring->prep_nop($sqe);

Prepare a no-op request.

Useful for smoke tests, ordering tests, and batching tests.

=head2 prep_read

  $ring->prep_read($sqe, $fd, $buffer, $len, $offset = 0);

Prepare a read request into the supplied Perl scalar buffer.

The scalar is retained until completion so the kernel has stable storage
for the I/O.

=head2 prep_write

  $ring->prep_write($sqe, $fd, $buffer, $len, $offset = 0);

Prepare a write request from the supplied Perl scalar buffer.

The scalar is retained until completion.

=head2 prep_recv

  $ring->prep_recv($sqe, $fd, $buffer, $len, $flags = 0);

Prepare a receive request into the supplied Perl scalar buffer.

The scalar is retained until completion.

=head2 prep_send

  $ring->prep_send($sqe, $fd, $buffer, $len, $flags = 0);

Prepare a send request from the supplied Perl scalar buffer.

The scalar is retained until completion.

=head2 prep_recv_multishot

  $ring->prep_recv_multishot($sqe, $fd, $len, $flags = 0);

Prepare a multishot receive request.

When used with buffer selection, the normal kernel pattern is to set
C<$len> to 0, enable C<IOSQE_BUFFER_SELECT>, and select a buffer group
with C<sqe_set_buf_group>.

Typical usage:

  my $sqe = $ring->get_sqe or die "no SQE available";
  $ring->prep_recv_multishot($sqe, fileno($sock), 0, 0);
  $ring->sqe_set_flags($sqe, Linux::Event::UringXS::IOSQE_BUFFER_SELECT());
  $ring->sqe_set_buf_group($sqe, $bgid);
  $ring->sqe_set_data64($sqe, 2001);

Multishot receive completions may carry:

- C<IORING_CQE_F_BUFFER>
- C<IORING_CQE_F_MORE>

Use C<cqe_buffer_id($flags)> to extract the buffer ID.

=head2 prep_timeout

  $ring->prep_timeout($sqe, $sec, $nsec = 0, $count = 0, $flags = 0);

Prepare a timeout request.

The meaning of C<$count> and C<$flags> follows the kernel timeout
operation.

=head2 prep_link_timeout

  $ring->prep_link_timeout($sqe, $sec, $nsec = 0, $flags = 0);

Prepare a linked timeout request.

This is normally used with C<IOSQE_IO_LINK> on a preceding SQE.

=head2 prep_poll_add

  $ring->prep_poll_add($sqe, $fd, $mask);

Prepare a poll-add request for the given file descriptor and poll mask.

=head2 prep_poll_multishot

  $ring->prep_poll_multishot($sqe, $fd, $mask);

Prepare a multishot poll request.

This may produce multiple CQEs over time until cancelled or otherwise
terminated by kernel semantics.

=head2 prep_poll_remove

  $ring->prep_poll_remove($sqe, $target_data64);

Prepare removal of an existing poll request identified by its
C<user_data> value.

=head2 prep_cancel64

  $ring->prep_cancel64($sqe, $target_data64, $flags = 0);

Prepare cancellation of an in-flight request identified by its
C<user_data> value.

Validated cancel behavior includes:

- the cancel request CQE completing with C<res = 0>
- the cancelled target request CQE completing with C<res = -ECANCELED>

=head2 prep_provide_buffers

  $ring->prep_provide_buffers($sqe, $buffer, $len, $count, $bgid, $bid = 0);

Prepare a provide-buffers request.

C<$buffer> is a Perl scalar containing the backing storage for the buffer
group. The module retains the scalar so the storage remains valid while
the kernel may use it.

=head2 prep_remove_buffers

  $ring->prep_remove_buffers($sqe, $count, $bgid);

Prepare removal of buffers from a provided-buffer group.

The completion result is the number of buffers removed.

This is not a boolean success/failure API.

=head2 prep_accept

  $ring->prep_accept($sqe, $fd, $flags = 0);

Prepare a single-shot accept request on a listening socket.

=head2 prep_accept_multishot

  $ring->prep_accept_multishot($sqe, $fd, $flags = 0);

Prepare a multishot accept request on a listening socket.

Each successful completion returns the newly accepted file descriptor in
C<res>. The request remains active while CQEs continue to carry
C<IORING_CQE_F_MORE>; when a completion arrives without that flag, the
multishot accept is terminal.

This binding uses C<NULL> for C<addr> and C<addrlen>, so it does not
return peer socket addresses.

=head2 prep_connect

  $ring->prep_connect($sqe, $fd, $sockaddr);

Prepare a connect request.

C<$sockaddr> must be a packed socket address suitable for the address
family of C<$fd>, such as one created by C<pack_sockaddr_in> or
C<pack_sockaddr_un>.

=head2 prep_close

  $ring->prep_close($sqe, $fd);

Prepare a close request for the given file descriptor.

=head2 prep_shutdown

  $ring->prep_shutdown($sqe, $fd, $how);

Prepare a shutdown request for the given socket file descriptor.

C<$how> is passed through unchanged and should usually be one of
C<SHUT_RD>, C<SHUT_WR>, or C<SHUT_RDWR>.

=head1 REGISTRATION METHODS

=head2 register_files

  $ring->register_files(\@fds);

Register fixed files from an array reference of file descriptors.

=head2 register_files_update

  $ring->register_files_update($offset, \@fds);

Update fixed-file registrations beginning at the given offset using an
array reference of file descriptors.

=head2 unregister_files

  $ring->unregister_files;

Remove all fixed-file registrations.

=head1 CONSTANTS

The module exposes constants corresponding to kernel io_uring flags used
by the current API, including:

=over 4

=item * C<IOSQE_IO_LINK>

=item * C<IOSQE_FIXED_FILE>

=item * C<IOSQE_BUFFER_SELECT>

=item * C<IORING_CQE_F_MORE>

=item * C<IORING_CQE_F_BUFFER>

=back

=head1 DESIGN NOTES

This module intentionally preserves explicit io_uring semantics.

It does not provide:

- callbacks
- futures/promises
- automatic submission at arbitrary points
- automatic rearming
- connection lifecycle management
- higher-level runtime policy

Helpers such as C<submit_and_wait_min>, C<reap_one>, and C<reap_many>
exist only to reduce boilerplate while preserving explicit control.

=head1 SEE ALSO

L<io_uring(7)>

=head1 LICENSE

Same terms as Perl itself.
