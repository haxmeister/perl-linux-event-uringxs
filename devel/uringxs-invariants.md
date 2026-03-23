# UringXS Invariants

Context: Linux::Event::UringXS (io_uring XS layer)

------------------------------------------------------------
Current Status (VALIDATED)
------------------------------------------------------------

Linux::Event::UringXS is a validated low-level io_uring wrapper.

All primitives are implemented and verified against real kernel behavior.

Test suite:
- Files = 19
- Tests = 257
- Result = PASS


------------------------------------------------------------
Implemented and Validated Primitives
------------------------------------------------------------

Core:
- explicit SQE/CQE model
- user_data (u64) correlation via sqe_set_data64
- peek_cqe / wait_cqe → ($data, $res, $flags)
- cqe_seen()

Timeouts:
- prep_timeout
- prep_link_timeout
- IOSQE_IO_LINK

Polling:
- prep_poll_add
- prep_poll_remove (u64 user_data based)
- prep_poll_multishot

Cancellation:
- prep_cancel64
- validated cancel semantics:
  - cancel CQE → res = 0
  - target CQE → res = -ECANCELED

Registration:
- fixed files:
  - register_files
  - register_files_update
  - unregister_files

- provided buffers:
  - prep_provide_buffers
  - prep_remove_buffers
  - ring-side slab lifetime handling


------------------------------------------------------------
Multishot + Buffer Selection (VALIDATED)
------------------------------------------------------------

- prep_recv_multishot (buf=NULL, len=0)
- IOSQE_BUFFER_SELECT
- sqe_set_buf_group
- IORING_CQE_F_BUFFER
- IORING_CQE_F_MORE
- cqe_buffer_id

Validated behaviors:
- multishot CQE streams with F_MORE
- buffer selection via CQE flags
- cancel terminates multishot correctly
- remove_buffers returns count removed (not boolean)
- consumed buffers are not removable unless re-provided


------------------------------------------------------------
Batching + CQE Ergonomics (NEW, VALIDATED)
------------------------------------------------------------

The following helpers exist to reduce boilerplate and enable batching
WITHOUT introducing runtime behavior.

Submission:

- sqe_ready_count()
  → number of SQEs currently prepared but not submitted

- submit_and_wait_min($n)
  → submit pending SQEs and block until at least $n CQEs are available


CQE draining:

- reap_one()
  → equivalent to:
     submit_and_wait_min(1)
     peek_cqe
     cqe_seen
  → returns:
     ($data, $res, $flags)

- reap_many($max)
  → submit pending SQEs
  → wait for at least one CQE
  → drain up to $max CQEs

  → returns a **flat list of triples**:

     ($data1, $res1, $flags1,
      $data2, $res2, $flags2, ...)


Validated behaviors:
- multiple SQEs can be submitted before a single submit()
- mixed operation batches (poll + timeout + nop) behave correctly
- CQEs can be drained incrementally across multiple reap_many() calls
- user_data correlation remains exact under batching
- no hidden submission occurs


------------------------------------------------------------
Design Constraints (CRITICAL)
------------------------------------------------------------

UringXS is intentionally:

- thin
- explicit
- kernel-shaped
- zero policy

It MUST NOT:

- introduce callbacks
- introduce objects
- introduce futures/promises
- perform implicit submission
- perform implicit rearming
- manage request lifetimes beyond kernel semantics


------------------------------------------------------------
Design Rule
------------------------------------------------------------

UringXS = mechanism

Everything else = policy


------------------------------------------------------------
Mental Model
------------------------------------------------------------

Correct usage is always explicit:

  get_sqe → prep → set_data → submit → reap → seen

Helpers do NOT change this model.
They only reduce boilerplate.


------------------------------------------------------------
Non-Goals (IMPORTANT)
------------------------------------------------------------

Do NOT implement at this layer:

- proactor or reactor
- callback dispatch
- futures/async/await
- connection abstractions
- buffer recycling policy
- automatic request persistence


------------------------------------------------------------
What This Means
------------------------------------------------------------

UringXS is now a **complete and correct substrate**.

The difficult kernel-level work is finished.

The current API supports:

- explicit batching
- explicit completion draining
- multishot + buffer selection
- cancellation correctness

without introducing abstraction.


------------------------------------------------------------
Future Direction (ABOVE THIS LAYER)
------------------------------------------------------------

Future layers may implement:

- proactor runtime
- operation lifecycle
- connection/socket abstractions
- scheduling and batching policy

These MUST be built **on top of** UringXS,
not inside it.


------------------------------------------------------------
Final Rule
------------------------------------------------------------

If something feels like:

  "this would be easier if XS handled it"

it probably belongs in the next layer, not here.
