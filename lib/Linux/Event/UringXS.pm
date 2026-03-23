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

Linux::Event::UringXS - thin, explicit io_uring bindings for Linux::Event

=head1 SYNOPSIS

  use v5.36;
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
    my $sqe = $ring->get_sqe or die;
    $ring->prep_nop($sqe);
    $ring->sqe_set_data64($sqe, $id);
  }

  $ring->submit_and_wait_min(1);

  my @flat = $ring->reap_many(64);

  while (@flat) {
    my ($data, $res, $flags) = splice @flat, 0, 3;
    say "data=$data res=$res flags=$flags";
  }

=head1 DESCRIPTION

C<Linux::Event::UringXS> is a thin XS wrapper over Linux C<io_uring>.

It exposes a kernel-shaped interface with:

- explicit SQE acquisition
- explicit submission
- explicit CQE retrieval
- explicit CQE acknowledgment

No callbacks, no objects, and no runtime behavior are introduced.

This module is a mechanism layer only.


=head1 CONSTRUCTOR

=head2 new

  my $ring = Linux::Event::UringXS->new($entries);

Create a new ring with the specified queue depth.


=head1 SUBMISSION

=head2 get_sqe

  my $sqe = $ring->get_sqe;

Obtain a submission queue entry.

Returns undef if none are available.


=head2 submit

  my $n = $ring->submit;

Submit all prepared SQEs.


=head2 submit_and_wait_min

  $ring->submit_and_wait_min($want);

Submit pending SQEs and wait until at least C<$want> completions exist.


=head2 sqe_ready_count

  my $n = $ring->sqe_ready_count;

Return number of prepared-but-not-submitted SQEs.


=head1 COMPLETION

=head2 peek_cqe

  my ($data, $res, $flags) = $ring->peek_cqe;

Non-blocking completion retrieval.

Returns empty list if none available.


=head2 wait_cqe

  my ($data, $res, $flags) = $ring->wait_cqe;

Blocking completion retrieval.


=head2 cqe_seen

  $ring->cqe_seen;

Mark current CQE as consumed.


=head2 reap_one

  my ($data, $res, $flags) = $ring->reap_one;

Submit pending work, wait for one CQE, return it, and mark it seen.


=head2 reap_many

  my @flat = $ring->reap_many($max);

Submit pending work, wait for at least one CQE, then drain up to C<$max>.

Returns flat triples:

  ($data1, $res1, $flags1, ...)


=head2 cqe_buffer_id

  my $bid = $ring->cqe_buffer_id($flags);

Extract buffer ID from CQE flags.


=head1 SQE SETUP

=head2 sqe_set_data64

  $ring->sqe_set_data64($sqe, $u64);

Associate user_data with SQE.


=head2 sqe_set_flags

  $ring->sqe_set_flags($sqe, $flags);

Set SQE flags.


=head2 sqe_set_buf_group

  $ring->sqe_set_buf_group($sqe, $bgid);

Set buffer group for buffer selection.


=head1 PREP OPERATIONS

=head2 prep_nop

  $ring->prep_nop($sqe);


=head2 prep_timeout

  $ring->prep_timeout($sqe, $sec, $nsec, $count, $flags);


=head2 prep_link_timeout

  $ring->prep_link_timeout($sqe, $sec, $nsec, $flags);


=head2 prep_poll_add

  $ring->prep_poll_add($sqe, $fd, $mask);


=head2 prep_poll_multishot

  $ring->prep_poll_multishot($sqe, $fd, $mask);


=head2 prep_poll_remove

  $ring->prep_poll_remove($sqe, $user_data);


=head2 prep_cancel64

  $ring->prep_cancel64($sqe, $user_data, $flags);


=head2 prep_recv_multishot

  $ring->prep_recv_multishot($sqe, $fd, $flags);

Used with:

  IOSQE_BUFFER_SELECT
  sqe_set_buf_group

CQEs may contain:

  IORING_CQE_F_BUFFER
  IORING_CQE_F_MORE


=head2 prep_provide_buffers

  $ring->prep_provide_buffers($sqe, $base, $len, $count, $bgid, $bid);


=head2 prep_remove_buffers

  $ring->prep_remove_buffers($sqe, $count, $bgid);

Returns number of buffers removed.


=head1 REGISTRATION

=head2 register_files

  $ring->register_files(@fds);


=head2 register_files_update

  $ring->register_files_update($offset, @fds);


=head2 unregister_files

  $ring->unregister_files;


=head1 CQE RETURN FORMAT

All completion APIs return:

  ($user_data, $res, $flags)

No objects are created.


=head1 DESIGN

This module is:

- explicit
- kernel-shaped
- zero-policy

It does NOT:

- auto-submit
- manage lifetimes
- provide callbacks
- provide async abstractions

Helpers only reduce boilerplate.


=head1 SEE ALSO

L<io_uring(7)>


=head1 LICENSE

Same terms as Perl itself.
