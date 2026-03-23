\
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <liburing.h>
#include <stdint.h>
#include <limits.h>
#include <string.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

typedef struct le_buf_group_entry_s {
    SV *buf_sv;
    unsigned short bgid;
    unsigned short bid;
    unsigned int count;
    STRLEN len;
    struct le_buf_group_entry_s *next;
} le_buf_group_entry_t;

typedef struct {
    SV   *buf_sv;
    int   op_type;
    STRLEN requested_len;
    unsigned short bgid;
    unsigned short bid;
    unsigned int count;
} le_slot_t;

typedef struct {
    struct io_uring ring;

    le_slot_t *slots;
    UV         slots_cap;
    le_buf_group_entry_t *buf_groups;

    struct io_uring_cqe *current_cqe;
    UV                   current_data64;
    IV                   current_res;
    UV                   current_flags;
    int                  has_current_cqe;
} le_ring_t;

typedef struct {
    le_ring_t *owner;
    struct io_uring_sqe *sqe;

    SV    *buf_sv;
    int    op_type;
    STRLEN requested_len;
    unsigned short bgid;
    unsigned short bid;
    unsigned int count;
} le_sqe_t;

enum {
    LE_OP_NONE    = 0,
    LE_OP_READ    = 1,
    LE_OP_WRITE   = 2,
    LE_OP_RECV    = 3,
    LE_OP_SEND    = 4,
    LE_OP_CONNECT = 5,
    LE_OP_TIMEOUT = 6,
    LE_OP_LINK_TIMEOUT = 7,
    LE_OP_PROVIDE_BUFFERS = 8,
    LE_OP_REMOVE_BUFFERS = 9,
};

#ifndef IORING_CQE_F_MORE
#define IORING_CQE_F_MORE (1U << 1)
#endif

#ifndef IOSQE_IO_LINK
#define IOSQE_IO_LINK (1U << 0)
#endif

#ifndef IOSQE_FIXED_FILE
#define IOSQE_FIXED_FILE (1U << 0)
#endif

#ifndef IOSQE_BUFFER_SELECT
#define IOSQE_BUFFER_SELECT (1U << 5)
#endif

#ifndef IORING_CQE_F_BUFFER
#define IORING_CQE_F_BUFFER (1U << 0)
#endif

#ifndef IORING_CQE_BUFFER_SHIFT
#define IORING_CQE_BUFFER_SHIFT 16
#endif

static void
le_croak_errno(const char *what, int rc)
{
    croak("%s failed: %s", what, strerror(-rc));
}

static le_ring_t *
le_ring_from_sv(SV *sv)
{
    if (!sv_isobject(sv) || !sv_derived_from(sv, "Linux::Event::UringXS")) {
        croak("invocant is not a Linux::Event::UringXS object");
    }

    return INT2PTR(le_ring_t *, SvIV((SV *)SvRV(sv)));
}

static le_sqe_t *
le_sqe_from_sv(SV *sv)
{
    if (!sv_isobject(sv) || !sv_derived_from(sv, "Linux::Event::UringXS::SQE")) {
        croak("argument is not a Linux::Event::UringXS::SQE object");
    }

    return INT2PTR(le_sqe_t *, SvIV((SV *)SvRV(sv)));
}

static void
le_buf_group_release_all(le_ring_t *ring)
{
    le_buf_group_entry_t *cur = ring->buf_groups;
    while (cur) {
        le_buf_group_entry_t *next = cur->next;
        if (cur->buf_sv) {
            SvREFCNT_dec(cur->buf_sv);
        }
        Safefree(cur);
        cur = next;
    }
    ring->buf_groups = NULL;
}

static void
le_buf_group_add(le_ring_t *ring, SV *buf_sv, unsigned short bgid, unsigned short bid, unsigned int count, STRLEN len)
{
    le_buf_group_entry_t *entry;

    Newxz(entry, 1, le_buf_group_entry_t);
    SvREFCNT_inc(buf_sv);
    entry->buf_sv = buf_sv;
    entry->bgid = bgid;
    entry->bid = bid;
    entry->count = count;
    entry->len = len;
    entry->next = ring->buf_groups;
    ring->buf_groups = entry;
}

static void
le_buf_group_remove(le_ring_t *ring, unsigned short bgid, unsigned int count)
{
    le_buf_group_entry_t **curp = &ring->buf_groups;

    while (*curp && count > 0) {
        le_buf_group_entry_t *cur = *curp;
        if (cur->bgid != bgid) {
            curp = &cur->next;
            continue;
        }

        if (cur->count <= count) {
            count -= cur->count;
            *curp = cur->next;
            if (cur->buf_sv) {
                SvREFCNT_dec(cur->buf_sv);
            }
            Safefree(cur);
            continue;
        }

        cur->bid += (unsigned short)count;
        cur->count -= count;
        count = 0;
    }
}

static void
le_slot_release(le_ring_t *ring, UV token)
{
    if (token >= ring->slots_cap) {
        return;
    }

    if (ring->slots[token].buf_sv) {
        SvREFCNT_dec(ring->slots[token].buf_sv);
        ring->slots[token].buf_sv = NULL;
    }

    ring->slots[token].op_type = LE_OP_NONE;
    ring->slots[token].requested_len = 0;
    ring->slots[token].bgid = 0;
    ring->slots[token].bid = 0;
    ring->slots[token].count = 0;
}

static void
le_slots_ensure(le_ring_t *ring, UV token)
{
    UV new_cap;
    le_slot_t *new_slots;
    UV i;

    if (token < ring->slots_cap) {
        return;
    }

    new_cap = ring->slots_cap ? ring->slots_cap : 64;
    while (new_cap <= token) {
        if (new_cap > (UV_MAX / 2)) {
            croak("user_data token too large");
        }
        new_cap *= 2;
    }

    Newxz(new_slots, new_cap, le_slot_t);

    for (i = 0; i < ring->slots_cap; i++) {
        new_slots[i] = ring->slots[i];
    }

    if (ring->slots) {
        Safefree(ring->slots);
    }

    ring->slots = new_slots;
    ring->slots_cap = new_cap;
}

static void
le_slot_take_buffer(le_ring_t *ring, UV token, SV *buf_sv, int op_type, STRLEN requested_len, unsigned short bgid, unsigned short bid, unsigned int count)
{
    le_slots_ensure(ring, token);
    le_slot_release(ring, token);

    ring->slots[token].buf_sv = buf_sv;
    ring->slots[token].op_type = op_type;
    ring->slots[token].requested_len = requested_len;
    ring->slots[token].bgid = bgid;
    ring->slots[token].bid = bid;
    ring->slots[token].count = count;
}

static void
le_sqe_clear_buffer_meta(le_sqe_t *sqe)
{
    if (sqe->buf_sv) {
        SvREFCNT_dec(sqe->buf_sv);
        sqe->buf_sv = NULL;
    }

    sqe->op_type = LE_OP_NONE;
    sqe->requested_len = 0;
    sqe->bgid = 0;
    sqe->bid = 0;
    sqe->count = 0;
}

static void
le_sqe_store_buffer_meta(le_sqe_t *sqe, SV *buf_sv, int op_type, STRLEN requested_len, unsigned short bgid, unsigned short bid, unsigned int count)
{
    le_sqe_clear_buffer_meta(sqe);

    SvREFCNT_inc(buf_sv);
    sqe->buf_sv = buf_sv;
    sqe->op_type = op_type;
    sqe->requested_len = requested_len;
    sqe->bgid = bgid;
    sqe->bid = bid;
    sqe->count = count;
}

static void
le_prepare_read_buffer(SV *buf_sv, STRLEN len, char **ptr_out)
{
    if (!SvPOK(buf_sv) && !SvOK(buf_sv)) {
        sv_setpvn(buf_sv, "", 0);
    }

    SvGROW(buf_sv, len + 1);
    *ptr_out = SvPVX(buf_sv);
}

static char *
le_prepare_write_buffer(SV *buf_sv, STRLEN *cur_len_out)
{
    STRLEN cur_len;
    char *ptr = SvPVbyte(buf_sv, cur_len);
    *cur_len_out = cur_len;
    return ptr;
}

static SV *
le_make_timespec_sv(UV sec, UV nsec)
{
    struct __kernel_timespec ts;

    if (nsec >= 1000000000UL) {
        croak("timeout nsec must be less than 1_000_000_000");
    }

    memset(&ts, 0, sizeof(ts));
    ts.tv_sec = (__s64) sec;
    ts.tv_nsec = (__s64) nsec;

    return newSVpvn((const char *)&ts, sizeof(ts));
}

static void
le_update_read_buffer(le_ring_t *ring, UV token, IV res)
{
    le_slot_t *slot;
    SV *buf_sv;

    if (token >= ring->slots_cap) {
        return;
    }

    slot = &ring->slots[token];
    buf_sv = slot->buf_sv;

    if (!buf_sv) {
        return;
    }

    if (!(slot->op_type == LE_OP_READ || slot->op_type == LE_OP_RECV)) {
        return;
    }

    if (res >= 0) {
        STRLEN got = (STRLEN) res;
        if (got > slot->requested_len) {
            got = slot->requested_len;
        }

        SvCUR_set(buf_sv, got);
        *SvEND(buf_sv) = '\0';
        SvPOK_only(buf_sv);
    }
}

static void
le_slot_complete(le_ring_t *ring, UV token, IV res)
{
    if (token < ring->slots_cap) {
        le_slot_t *slot = &ring->slots[token];
        if (slot->op_type == LE_OP_PROVIDE_BUFFERS && slot->buf_sv && res >= 0) {
            le_buf_group_add(ring, slot->buf_sv, slot->bgid, slot->bid, slot->count, slot->requested_len);
        } else if (slot->op_type == LE_OP_REMOVE_BUFFERS && res >= 0) {
            le_buf_group_remove(ring, slot->bgid, slot->count);
        }
    }

    le_slot_release(ring, token);
}

static void
le_capture_cqe(le_ring_t *ring, struct io_uring_cqe *cqe)
{
    ring->current_cqe = cqe;
    ring->current_data64 = (UV)cqe->user_data;
    ring->current_res = (IV)cqe->res;
    ring->current_flags = (UV)cqe->flags;
    ring->has_current_cqe = 1;

    le_update_read_buffer(ring, ring->current_data64, ring->current_res);
}

MODULE = Linux::Event::UringXS    PACKAGE = Linux::Event::UringXS

SV *
new(class, entries)
    const char *class
    UV entries
PREINIT:
    le_ring_t *ring;
    int rc;
    SV *obj;
CODE:
    if (entries == 0)
    croak("entries must be greater than zero");

    Newxz(ring, 1, le_ring_t);

    rc = io_uring_queue_init(entries, &ring->ring, 0);
    if (rc < 0) {
    Safefree(ring);
    le_croak_errno("io_uring_queue_init", rc);
    }

    obj = newSViv(PTR2IV(ring));
    RETVAL = sv_bless(newRV_noinc(obj), gv_stashpv(class, GV_ADD));
OUTPUT:
    RETVAL

void
DESTROY(self)
    SV *self
PREINIT:
    le_ring_t *ring;
    UV i;
CODE:
    ring = le_ring_from_sv(self);

    if (ring->has_current_cqe && ring->current_cqe) {
    io_uring_cqe_seen(&ring->ring, ring->current_cqe);
    ring->current_cqe = NULL;
    ring->has_current_cqe = 0;
    }

    if (ring->slots) {
    for (i = 0; i < ring->slots_cap; i++) {
    if (ring->slots[i].buf_sv) {
    SvREFCNT_dec(ring->slots[i].buf_sv);
    ring->slots[i].buf_sv = NULL;
    }
    }
    Safefree(ring->slots);
    ring->slots = NULL;
    ring->slots_cap = 0;
    }

    le_buf_group_release_all(ring);

    io_uring_queue_exit(&ring->ring);
    Safefree(ring);

int
register_files(self, fds_avref)
    SV *self
    SV *fds_avref
PREINIT:
    le_ring_t *ring;
    AV *av;
    SSize_t n;
    int *fds;
    SSize_t i;
CODE:
    ring = le_ring_from_sv(self);

    if (!SvROK(fds_avref) || SvTYPE(SvRV(fds_avref)) != SVt_PVAV) {
    croak("register_files expects an array reference of file descriptors");
    }

    av = (AV *)SvRV(fds_avref);
    n = av_len(av) + 1;
    if (n <= 0) {
    croak("register_files requires at least one file descriptor");
    }

    Newxz(fds, n, int);
    for (i = 0; i < n; i++) {
        SV **svp = av_fetch(av, i, 0);
        if (!svp || !SvOK(*svp)) {
            Safefree(fds);
            croak("register_files array contains undef at index %ld", (long)i);
        }
        fds[i] = (int)SvIV(*svp);
    }

    RETVAL = io_uring_register_files(&ring->ring, fds, (unsigned)n);
    Safefree(fds);
OUTPUT:
    RETVAL

int
unregister_files(self)
    SV *self
PREINIT:
    le_ring_t *ring;
CODE:
    ring = le_ring_from_sv(self);
    RETVAL = io_uring_unregister_files(&ring->ring);
OUTPUT:
    RETVAL

int
register_files_update(self, offset, fds_avref)
    SV *self
    UV offset
    SV *fds_avref
PREINIT:
    le_ring_t *ring;
    AV *av;
    SSize_t n;
    int *fds;
    SSize_t i;
CODE:
    ring = le_ring_from_sv(self);

    if (!SvROK(fds_avref) || SvTYPE(SvRV(fds_avref)) != SVt_PVAV) {
    croak("register_files_update expects an array reference of file descriptors");
    }

    av = (AV *)SvRV(fds_avref);
    n = av_len(av) + 1;
    if (n <= 0) {
    croak("register_files_update requires at least one file descriptor");
    }

    Newxz(fds, n, int);
    for (i = 0; i < n; i++) {
        SV **svp = av_fetch(av, i, 0);
        if (!svp || !SvOK(*svp)) {
            Safefree(fds);
            croak("register_files_update array contains undef at index %ld", (long)i);
        }
        fds[i] = (int)SvIV(*svp);
    }

    RETVAL = io_uring_register_files_update(&ring->ring, (unsigned)offset, fds, (unsigned)n);
    Safefree(fds);
OUTPUT:
    RETVAL

SV *
get_sqe(self)
    SV *self
PREINIT:
    le_ring_t *ring;
    struct io_uring_sqe *sqe;
    le_sqe_t *wrap;
    SV *obj;
CODE:
    ring = le_ring_from_sv(self);
    sqe = io_uring_get_sqe(&ring->ring);

    if (!sqe) {
    XSRETURN_UNDEF;
    }

    Newxz(wrap, 1, le_sqe_t);
    wrap->owner = ring;
    wrap->sqe = sqe;

    obj = newSViv(PTR2IV(wrap));
    RETVAL = sv_bless(newRV_noinc(obj), gv_stashpv("Linux::Event::UringXS::SQE", GV_ADD));
OUTPUT:
    RETVAL

void
prep_nop(self, sqe_sv)
    SV *self
    SV *sqe_sv
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    le_sqe_clear_buffer_meta(sqe);
    io_uring_prep_nop(sqe->sqe);

void
prep_read(self, sqe_sv, fd, buf_sv, len, offset = 0)
    SV *self
    SV *sqe_sv
    int fd
    SV *buf_sv
    UV len
    UV offset
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
    char *buf;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    le_prepare_read_buffer(buf_sv, (STRLEN) len, &buf);
    le_sqe_store_buffer_meta(sqe, buf_sv, LE_OP_READ, (STRLEN) len, 0, 0, 0);
    io_uring_prep_read(sqe->sqe, fd, buf, (unsigned) len, (off_t) offset);

void
prep_write(self, sqe_sv, fd, buf_sv, len, offset = 0)
    SV *self
    SV *sqe_sv
    int fd
    SV *buf_sv
    UV len
    UV offset
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
    STRLEN cur_len;
    char *buf;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    buf = le_prepare_write_buffer(buf_sv, &cur_len);
    if ((STRLEN) len > cur_len) croak("write length exceeds scalar length");

    le_sqe_store_buffer_meta(sqe, buf_sv, LE_OP_WRITE, (STRLEN) len, 0, 0, 0);
    io_uring_prep_write(sqe->sqe, fd, buf, (unsigned) len, (off_t) offset);

void
prep_recv_multishot(self, sqe_sv, fd, len, flags = 0)
    SV *self
    SV *sqe_sv
    int fd
    UV len
    int flags
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");
    if (len > UINT_MAX) croak("recv_multishot len too large");

    PERL_UNUSED_VAR(len);

    le_sqe_clear_buffer_meta(sqe);

    /* Multishot recv with provided-buffer selection requires NULL + len 0. */
    io_uring_prep_recv_multishot(sqe->sqe, fd, NULL, 0, flags);

void
prep_recv(self, sqe_sv, fd, buf_sv, len, flags = 0)
    SV *self
    SV *sqe_sv
    int fd
    SV *buf_sv
    UV len
    int flags
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
    char *buf;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    le_prepare_read_buffer(buf_sv, (STRLEN) len, &buf);
    le_sqe_store_buffer_meta(sqe, buf_sv, LE_OP_RECV, (STRLEN) len, 0, 0, 0);
    io_uring_prep_recv(sqe->sqe, fd, buf, (unsigned) len, flags);

void
prep_send(self, sqe_sv, fd, buf_sv, len, flags = 0)
    SV *self
    SV *sqe_sv
    int fd
    SV *buf_sv
    UV len
    int flags
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
    STRLEN cur_len;
    char *buf;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    buf = le_prepare_write_buffer(buf_sv, &cur_len);
    if ((STRLEN) len > cur_len) croak("send length exceeds scalar length");

    le_sqe_store_buffer_meta(sqe, buf_sv, LE_OP_SEND, (STRLEN) len, 0, 0, 0);
    io_uring_prep_send(sqe->sqe, fd, buf, (unsigned) len, flags);

void
prep_timeout(self, sqe_sv, sec, nsec = 0, count = 0, flags = 0)
    SV *self
    SV *sqe_sv
    UV sec
    UV nsec
    UV count
    UV flags
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
    SV *ts_sv;
    STRLEN ts_len;
    char *ts_ptr;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    ts_sv = le_make_timespec_sv(sec, nsec);
    ts_ptr = SvPVbyte(ts_sv, ts_len);
    if (ts_len != sizeof(struct __kernel_timespec)) {
    SvREFCNT_dec(ts_sv);
    croak("internal error creating timespec scalar");
    }

    le_sqe_store_buffer_meta(sqe, ts_sv, LE_OP_TIMEOUT, ts_len, 0, 0, 0);
    SvREFCNT_dec(ts_sv);
    io_uring_prep_timeout(sqe->sqe, (struct __kernel_timespec *)ts_ptr, (unsigned)count, (unsigned)flags);

void
prep_link_timeout(self, sqe_sv, sec, nsec = 0, flags = 0)
    SV *self
    SV *sqe_sv
    UV sec
    UV nsec
    UV flags
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
    SV *ts_sv;
    STRLEN ts_len;
    char *ts_ptr;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    ts_sv = le_make_timespec_sv(sec, nsec);
    ts_ptr = SvPVbyte(ts_sv, ts_len);
    if (ts_len != sizeof(struct __kernel_timespec)) {
    SvREFCNT_dec(ts_sv);
    croak("internal error creating timespec scalar");
    }

    le_sqe_store_buffer_meta(sqe, ts_sv, LE_OP_LINK_TIMEOUT, ts_len, 0, 0, 0);
    SvREFCNT_dec(ts_sv);
    io_uring_prep_link_timeout(sqe->sqe, (struct __kernel_timespec *)ts_ptr, (unsigned)flags);

void
prep_poll_add(self, sqe_sv, fd, mask)
    SV *self
    SV *sqe_sv
    int fd
    UV mask
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    le_sqe_clear_buffer_meta(sqe);
    io_uring_prep_poll_add(sqe->sqe, fd, (unsigned)mask);

void
prep_poll_multishot(self, sqe_sv, fd, mask)
    SV *self
    SV *sqe_sv
    int fd
    UV mask
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    le_sqe_clear_buffer_meta(sqe);
    io_uring_prep_poll_multishot(sqe->sqe, fd, (unsigned)mask);

void
prep_poll_remove(self, sqe_sv, target_data64)
    SV *self
    SV *sqe_sv
    UV target_data64
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    le_sqe_clear_buffer_meta(sqe);
    io_uring_prep_poll_remove(sqe->sqe, (uint64_t)target_data64);

void
prep_provide_buffers(self, sqe_sv, buf_sv, len, count, bgid, bid = 0)
    SV *self
    SV *sqe_sv
    SV *buf_sv
    UV len
    UV count
    UV bgid
    UV bid
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
    STRLEN cur_len;
    char *buf;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");
    if (len == 0) croak("provide_buffers len must be greater than zero");
    if (count == 0) croak("provide_buffers count must be greater than zero");
    if (bgid > 0xffff) croak("bgid must fit in 16 bits");
    if (bid > 0xffff) croak("bid must fit in 16 bits");
    if (count > UINT_MAX) croak("provide_buffers count too large");
    if (len > INT_MAX) croak("provide_buffers len too large");

    buf = le_prepare_write_buffer(buf_sv, &cur_len);
    if (count > UV_MAX / len) croak("provide_buffers len * count overflow");
    if ((STRLEN)(len * count) > cur_len) croak("provide_buffers scalar shorter than len * count");

    le_sqe_store_buffer_meta(sqe, buf_sv, LE_OP_PROVIDE_BUFFERS, (STRLEN) len, (unsigned short)bgid, (unsigned short)bid, (unsigned int)count);
    io_uring_prep_provide_buffers(sqe->sqe, buf, (int)len, (int)count, (int)bgid, (int)bid);

void
prep_remove_buffers(self, sqe_sv, count, bgid)
    SV *self
    SV *sqe_sv
    UV count
    UV bgid
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");
    if (count == 0) croak("remove_buffers count must be greater than zero");
    if (count > UINT_MAX) croak("remove_buffers count too large");
    if (bgid > 0xffff) croak("bgid must fit in 16 bits");

    le_sqe_clear_buffer_meta(sqe);
    sqe->op_type = LE_OP_REMOVE_BUFFERS;
    sqe->bgid = (unsigned short)bgid;
    sqe->count = (unsigned int)count;
    io_uring_prep_remove_buffers(sqe->sqe, (int)count, (int)bgid);

void
prep_accept(self, sqe_sv, fd, flags = 0)
    SV *self
    SV *sqe_sv
    int fd
    int flags
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    le_sqe_clear_buffer_meta(sqe);
    io_uring_prep_accept(sqe->sqe, fd, NULL, NULL, flags);

void
prep_connect(self, sqe_sv, fd, sockaddr_sv)
    SV *self
    SV *sqe_sv
    int fd
    SV *sockaddr_sv
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
    STRLEN len;
    char *ptr;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    ptr = SvPVbyte(sockaddr_sv, len);
    if (len == 0) croak("sockaddr scalar must not be empty");

    le_sqe_store_buffer_meta(sqe, sockaddr_sv, LE_OP_CONNECT, len, 0, 0, 0);
    io_uring_prep_connect(sqe->sqe, fd, (const struct sockaddr *)ptr, (socklen_t)len);

void
prep_close(self, sqe_sv, fd)
    SV *self
    SV *sqe_sv
    int fd
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    le_sqe_clear_buffer_meta(sqe);
    io_uring_prep_close(sqe->sqe, fd);

void
prep_cancel64(self, sqe_sv, target_data64, flags = 0)
    SV *self
    SV *sqe_sv
    UV target_data64
    int flags
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    le_sqe_clear_buffer_meta(sqe);
    io_uring_prep_cancel64(sqe->sqe, (uint64_t)target_data64, flags);

void
sqe_set_data64(self, sqe_sv, data64)
    SV *self
    SV *sqe_sv
    UV data64
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    io_uring_sqe_set_data64(sqe->sqe, (uint64_t) data64);

    if (sqe->buf_sv || sqe->op_type == LE_OP_REMOVE_BUFFERS) {
    le_slot_take_buffer(ring, data64, sqe->buf_sv, sqe->op_type, sqe->requested_len, sqe->bgid, sqe->bid, sqe->count);
    sqe->buf_sv = NULL;
    sqe->op_type = LE_OP_NONE;
    sqe->requested_len = 0;
    sqe->bgid = 0;
    sqe->bid = 0;
    sqe->count = 0;
    }

void
sqe_set_flags(self, sqe_sv, flags)
    SV *self
    SV *sqe_sv
    UV flags
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");

    sqe->sqe->flags = (unsigned char) flags;

void
sqe_set_buf_group(self, sqe_sv, bgid)
    SV *self
    SV *sqe_sv
    UV bgid
PREINIT:
    le_ring_t *ring;
    le_sqe_t *sqe;
CODE:
    ring = le_ring_from_sv(self);
    sqe = le_sqe_from_sv(sqe_sv);

    if (sqe->owner != ring) croak("SQE does not belong to this ring");
    if (!sqe->sqe) croak("SQE is no longer valid");
    if (bgid > 0xffff) croak("bgid must fit in 16 bits");

    sqe->sqe->buf_group = (unsigned short)bgid;

IV
submit(self)
    SV *self
PREINIT:
    le_ring_t *ring;
CODE:
    ring = le_ring_from_sv(self);
    RETVAL = (IV) io_uring_submit(&ring->ring);
OUTPUT:
    RETVAL

IV
submit_and_wait(self, want)
    SV *self
    UV want
PREINIT:
    le_ring_t *ring;
CODE:
    ring = le_ring_from_sv(self);
    RETVAL = (IV) io_uring_submit_and_wait(&ring->ring, (unsigned) want);
OUTPUT:
    RETVAL

void
peek_cqe(self)
    SV *self
PREINIT:
    le_ring_t *ring;
    struct io_uring_cqe *cqe = NULL;
    int rc;
PPCODE:
    ring = le_ring_from_sv(self);

    if (ring->has_current_cqe) {
    croak("current CQE has not been marked seen");
    }

    rc = io_uring_peek_cqe(&ring->ring, &cqe);
    if (rc == -EAGAIN) {
    XSRETURN_EMPTY;
    }
    if (rc < 0) {
    le_croak_errno("io_uring_peek_cqe", rc);
    }
    if (!cqe) {
    XSRETURN_EMPTY;
    }

    le_capture_cqe(ring, cqe);

    EXTEND(SP, 3);
    PUSHs(sv_2mortal(newSVuv(ring->current_data64)));
    PUSHs(sv_2mortal(newSViv(ring->current_res)));
    PUSHs(sv_2mortal(newSVuv(ring->current_flags)));

void
wait_cqe(self)
    SV *self
PREINIT:
    le_ring_t *ring;
    struct io_uring_cqe *cqe = NULL;
    int rc;
PPCODE:
    ring = le_ring_from_sv(self);

    if (ring->has_current_cqe) {
    croak("current CQE has not been marked seen");
    }

    rc = io_uring_wait_cqe(&ring->ring, &cqe);
    if (rc < 0) {
    le_croak_errno("io_uring_wait_cqe", rc);
    }

    le_capture_cqe(ring, cqe);

    EXTEND(SP, 3);
    PUSHs(sv_2mortal(newSVuv(ring->current_data64)));
    PUSHs(sv_2mortal(newSViv(ring->current_res)));
    PUSHs(sv_2mortal(newSVuv(ring->current_flags)));

void
cqe_seen(self)
    SV *self
PREINIT:
    le_ring_t *ring;
    UV token;
CODE:
    ring = le_ring_from_sv(self);

    if (!ring->has_current_cqe || !ring->current_cqe) {
    croak("no current CQE to mark seen");
    }

    token = ring->current_data64;
    le_slot_complete(ring, token, ring->current_res);

    io_uring_cqe_seen(&ring->ring, ring->current_cqe);

    ring->current_cqe = NULL;
    ring->current_data64 = 0;
    ring->current_res = 0;
    ring->current_flags = 0;
    ring->has_current_cqe = 0;

IV
submit_and_wait_min(self, want)
    SV *self
    UV want
PREINIT:
    le_ring_t *ring;
CODE:
    ring = le_ring_from_sv(self);
    RETVAL = (IV) io_uring_submit_and_wait(&ring->ring, (unsigned) want);
OUTPUT:
    RETVAL

void
reap_one(self)
    SV *self
PREINIT:
    le_ring_t *ring;
    struct io_uring_cqe *cqe = NULL;
    UV data64;
    IV res;
    UV flags;
    int rc;
PPCODE:
    ring = le_ring_from_sv(self);

    if (ring->has_current_cqe) {
    croak("current CQE has not been marked seen");
    }

    rc = io_uring_submit_and_wait(&ring->ring, 1);
    if (rc < 0) {
    le_croak_errno("io_uring_submit_and_wait", rc);
    }

    rc = io_uring_peek_cqe(&ring->ring, &cqe);
    if (rc < 0) {
    le_croak_errno("io_uring_peek_cqe", rc);
    }
    if (!cqe) {
    croak("io_uring_submit_and_wait returned without a CQE");
    }

    data64 = (UV)cqe->user_data;
    res = (IV)cqe->res;
    flags = (UV)cqe->flags;

    le_update_read_buffer(ring, data64, res);
    le_slot_complete(ring, data64, res);
    io_uring_cqe_seen(&ring->ring, cqe);

    EXTEND(SP, 3);
    PUSHs(sv_2mortal(newSVuv(data64)));
    PUSHs(sv_2mortal(newSViv(res)));
    PUSHs(sv_2mortal(newSVuv(flags)));

void
reap_many(self, max)
    SV *self
    UV max
PREINIT:
    le_ring_t *ring;
    struct io_uring_cqe *cqe = NULL;
    UV count = 0;
    int rc;
PPCODE:
    ring = le_ring_from_sv(self);

    if (ring->has_current_cqe) {
    croak("current CQE has not been marked seen");
    }
    if (max == 0) {
    XSRETURN_EMPTY;
    }
    if (max > (UV_MAX / 3)) {
    croak("reap_many max too large");
    }

    rc = io_uring_submit_and_wait(&ring->ring, 1);
    if (rc < 0) {
    le_croak_errno("io_uring_submit_and_wait", rc);
    }

    EXTEND(SP, (I32)(max * 3));

    while (count < max) {
        UV data64;
        IV res;
        UV flags;

        rc = io_uring_peek_cqe(&ring->ring, &cqe);
        if (rc == -EAGAIN || !cqe) {
            break;
        }
        if (rc < 0) {
        le_croak_errno("io_uring_peek_cqe", rc);
        }

        data64 = (UV)cqe->user_data;
        res = (IV)cqe->res;
        flags = (UV)cqe->flags;

        le_update_read_buffer(ring, data64, res);
        le_slot_complete(ring, data64, res);
        io_uring_cqe_seen(&ring->ring, cqe);

        PUSHs(sv_2mortal(newSVuv(data64)));
        PUSHs(sv_2mortal(newSViv(res)));
        PUSHs(sv_2mortal(newSVuv(flags)));
        count++;
    }

UV
sqe_ready_count(self)
    SV *self
PREINIT:
    le_ring_t *ring;
CODE:
    ring = le_ring_from_sv(self);
    RETVAL = (UV) io_uring_sq_ready(&ring->ring);
OUTPUT:
    RETVAL

UV
sq_ready(self)
    SV *self
PREINIT:
    le_ring_t *ring;
CODE:
    ring = le_ring_from_sv(self);
    RETVAL = (UV) io_uring_sq_ready(&ring->ring);
OUTPUT:
    RETVAL

UV
sq_space_left(self)
    SV *self
PREINIT:
    le_ring_t *ring;
CODE:
    ring = le_ring_from_sv(self);
    RETVAL = (UV) io_uring_sq_space_left(&ring->ring);
OUTPUT:
    RETVAL

UV
cq_ready(self)
    SV *self
PREINIT:
    le_ring_t *ring;
CODE:
    ring = le_ring_from_sv(self);
    RETVAL = (UV) io_uring_cq_ready(&ring->ring);
OUTPUT:
    RETVAL

UV
IOSQE_IO_LINK(self = NULL)
    SV *self
CODE:
    RETVAL = (UV) IOSQE_IO_LINK;
OUTPUT:
    RETVAL

UV
IOSQE_FIXED_FILE(self = NULL)
    SV *self
CODE:
    RETVAL = (UV) IOSQE_FIXED_FILE;
OUTPUT:
    RETVAL

UV
IOSQE_BUFFER_SELECT(self = NULL)
    SV *self
CODE:
    RETVAL = (UV) IOSQE_BUFFER_SELECT;
OUTPUT:
    RETVAL

UV
IORING_CQE_F_MORE(self = NULL)
    SV *self
CODE:
    RETVAL = (UV) IORING_CQE_F_MORE;
OUTPUT:
    RETVAL

UV
IORING_CQE_F_BUFFER(self = NULL)
    SV *self
CODE:
    RETVAL = (UV) IORING_CQE_F_BUFFER;
OUTPUT:
    RETVAL

UV
cqe_buffer_id(self, flags)
    SV *self
    UV flags
CODE:
    RETVAL = (UV)(flags >> IORING_CQE_BUFFER_SHIFT);
OUTPUT:
    RETVAL

MODULE = Linux::Event::UringXS    PACKAGE = Linux::Event::UringXS::SQE

void
DESTROY(self)
    SV *self
PREINIT:
    le_sqe_t *sqe;
CODE:
    sqe = le_sqe_from_sv(self);

    if (sqe) {
    le_sqe_clear_buffer_meta(sqe);
    sqe->sqe = NULL;
    sqe->owner = NULL;
    Safefree(sqe);
    }

=head1 BATCHING AND CQE HELPERS

These helpers provide minimal ergonomics for submission and completion
handling. They do not introduce policy or implicit behavior.

All semantics remain explicit and kernel-shaped.


=head2 sqe_ready_count

  my $n = $ring->sqe_ready_count;

Returns the number of SQEs currently prepared but not yet submitted.

This is useful for batching decisions.


=head2 submit_and_wait_min

  $ring->submit_and_wait_min($want);

Submits all pending SQEs and blocks until at least C<$want> CQEs
are available.

This maps directly to the underlying kernel behavior.


=head2 reap_one

  my ($data, $res, $flags) = $ring->reap_one;

Convenience wrapper for:

  submit_and_wait_min(1)
  peek_cqe
  cqe_seen

Returns a single completion triple:

  ($user_data, $res, $flags)

No objects are created.


=head2 reap_many

  my @flat = $ring->reap_many($max);

Submits pending SQEs, waits for at least one completion,
then drains up to C<$max> CQEs.

Returns a flat list of triples:

  ($data1, $res1, $flags1,
   $data2, $res2, $flags2, ...)

This format avoids allocation overhead and is suitable for
high-performance loops.


=head2 EXAMPLE

  # prepare multiple SQEs
  for (1..N) {
    my $sqe = $ring->get_sqe;
    $ring->prep_nop($sqe);
    $ring->sqe_set_data64($sqe, $_);
  }

  # submit once
  $ring->submit_and_wait_min(1);

  # drain completions
  my @cqe = $ring->reap_many(64);

  while (@cqe) {
    my ($data, $res, $flags) = splice(@cqe, 0, 3);

    # handle completion
  }


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

  my $ring = Linux::Event::UringXS->new(256);

  for my $id (1 .. 4) {
    my $sqe = $ring->get_sqe
      or die "no SQE available";
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

C<Linux::Event::UringXS> is a thin XS wrapper around Linux C<io_uring>.

This module is intentionally low-level and explicit. It exposes a
kernel-shaped interface for:

- SQE acquisition
- SQE preparation
- explicit submission
- CQE retrieval
- CQE acknowledgment
- registration operations
- multishot and buffer-selection features

This module does not implement a proactor, reactor, callback system,
future/promise layer, or connection abstraction. Those belong in higher
layers.

The design goal is:

  UringXS = mechanism
  everything else = policy

=head1 CONSTRUCTOR

=head2 new

  my $ring = Linux::Event::UringXS->new($entries);

Creates a new io_uring instance with the requested queue depth.

Returns a ring object on success.

=head1 SUBMISSION QUEUE METHODS

=head2 get_sqe

  my $sqe = $ring->get_sqe;

Returns the next available submission queue entry.

Returns undef if no SQE is currently available.

The caller prepares the SQE explicitly using one of the C<prep_*>
methods below.

=head2 submit

  my $count = $ring->submit;

Submits all currently prepared SQEs to the kernel.

Returns the result from the underlying submit operation.

No submission is performed implicitly anywhere else in the API unless you
call a helper documented as doing so.

=head2 submit_and_wait_min

  my $count = $ring->submit_and_wait_min($want);

Submits pending SQEs and blocks until at least C<$want> completion queue
entries are available.

This is a thin helper for explicit batching and completion waiting. It
does not change ownership, lifecycle, or dispatch semantics.

=head2 sqe_ready_count

  my $n = $ring->sqe_ready_count;

Returns the number of SQEs currently prepared but not yet submitted.

This is useful when building explicit batching logic.

=head1 COMPLETION QUEUE METHODS

=head2 peek_cqe

  my ($data, $res, $flags) = $ring->peek_cqe;

Attempts to retrieve one completion queue entry without blocking.

Returns an empty list if no CQE is available.

On success, returns:

  ($user_data, $res, $flags)

The completion remains outstanding until C<cqe_seen> is called.

=head2 wait_cqe

  my ($data, $res, $flags) = $ring->wait_cqe;

Waits until one completion queue entry is available and returns:

  ($user_data, $res, $flags)

The completion remains outstanding until C<cqe_seen> is called.

=head2 cqe_seen

  $ring->cqe_seen;

Marks the current completion queue entry as seen.

This must be called after a successful C<peek_cqe> or C<wait_cqe> once
the caller is finished with that CQE.

=head2 reap_one

  my ($data, $res, $flags) = $ring->reap_one;

Convenience helper that performs the equivalent of:

  $ring->submit_and_wait_min(1);
  my ($data, $res, $flags) = $ring->peek_cqe;
  $ring->cqe_seen;

Returns one completion triple:

  ($user_data, $res, $flags)

No objects are created.

=head2 reap_many

  my @flat = $ring->reap_many($max);

Submits pending SQEs, waits for at least one CQE, then drains up to
C<$max> completions.

Returns a flat list of triples:

  ($data1, $res1, $flags1,
   $data2, $res2, $flags2, ...)

This format is intentional. It avoids additional allocation and fits
hot-path batching code better than returning nested arrayrefs or objects.

=head2 cqe_buffer_id

  my $bid = $ring->cqe_buffer_id($flags);

Extracts the selected buffer ID from CQE flags when
C<IORING_CQE_F_BUFFER> is present.

This is primarily used with buffer selection and multishot receive
operations.

=head1 SQE DATA METHODS

=head2 sqe_set_data64

  $ring->sqe_set_data64($sqe, $u64);

Associates a 64-bit user value with an SQE.

That value is returned later as the first element of the completion
triple:

  ($user_data, $res, $flags)

This is the primary correlation mechanism between submitted work and
completion handling.

=head2 sqe_set_flags

  $ring->sqe_set_flags($sqe, $flags);

Sets SQE flags such as C<IOSQE_IO_LINK> or C<IOSQE_BUFFER_SELECT>.

=head2 sqe_set_buf_group

  $ring->sqe_set_buf_group($sqe, $bgid);

Sets the buffer group ID on an SQE for buffer-selection operations.

This is typically used together with C<IOSQE_BUFFER_SELECT> and
C<prep_recv_multishot>.

=head1 PREPARATION METHODS

=head2 prep_nop

  $ring->prep_nop($sqe);

Prepares a no-op request.

Useful for smoke tests, ordering tests, and batching tests.

=head2 prep_timeout

  $ring->prep_timeout($sqe, $sec, $nsec, $count, $flags);

Prepares a timeout request.

The exact interpretation of C<$count> and C<$flags> follows the kernel
io_uring timeout operation.

=head2 prep_link_timeout

  $ring->prep_link_timeout($sqe, $sec, $nsec, $flags);

Prepares a linked timeout request.

This is normally used together with C<IOSQE_IO_LINK> on a preceding SQE.

=head2 prep_poll_add

  $ring->prep_poll_add($sqe, fileno($fh), $mask);

Prepares a poll-add request for the given file descriptor and poll mask.

=head2 prep_poll_multishot

  $ring->prep_poll_multishot($sqe, fileno($fh), $mask);

Prepares a multishot poll request.

This produces multiple CQEs over time until cancelled or otherwise
terminated by kernel semantics.

=head2 prep_poll_remove

  $ring->prep_poll_remove($sqe, $user_data);

Prepares removal of an existing poll request identified by its
C<user_data> value.

=head2 prep_cancel64

  $ring->prep_cancel64($sqe, $user_data, $flags);

Prepares cancellation of an in-flight request identified by its
C<user_data> value.

Validated cancel semantics include:

- the cancel request completion reporting success with C<res = 0>
- the cancelled target request completing with C<res = -ECANCELED>

=head2 prep_read

  $ring->prep_read($sqe, fileno($fh), $len, $offset);

Prepares a read request.

=head2 prep_write

  $ring->prep_write($sqe, fileno($fh), $buffer, $offset);

Prepares a write request.

=head2 prep_read_fixed

  $ring->prep_read_fixed($sqe, $fd, $len, $offset, $buf_index);

Prepares a fixed-file/fixed-buffer style read request, where applicable
to the current API shape.

Use with registered resources as supported by the module.

=head2 prep_write_fixed

  $ring->prep_write_fixed($sqe, $fd, $buffer, $offset, $buf_index);

Prepares a fixed-file/fixed-buffer style write request, where applicable
to the current API shape.

Use with registered resources as supported by the module.

=head2 prep_recv

  $ring->prep_recv($sqe, fileno($fh), $len, $flags);

Prepares a receive request.

=head2 prep_send

  $ring->prep_send($sqe, fileno($fh), $buffer, $flags);

Prepares a send request.

=head2 prep_recv_multishot

  $ring->prep_recv_multishot($sqe, fileno($fh), $flags);

Prepares a multishot receive request.

For correct kernel semantics, this operation is issued without a direct
buffer pointer and with zero length. When used with buffer selection, the
kernel chooses a buffer from the configured buffer group and reports the
selected buffer through CQE flags.

Typical usage:

  my $sqe = $ring->get_sqe or die;
  $ring->prep_recv_multishot($sqe, fileno($sock), 0);
  $ring->sqe_set_flags($sqe, Linux::Event::UringXS::IOSQE_BUFFER_SELECT());
  $ring->sqe_set_buf_group($sqe, $bgid);
  $ring->sqe_set_data64($sqe, 2001);

Multishot receive completions may carry:

- C<IORING_CQE_F_BUFFER>
- C<IORING_CQE_F_MORE>

Use C<cqe_buffer_id($flags)> to determine which provided buffer was used.

=head2 prep_provide_buffers

  $ring->prep_provide_buffers($sqe, $base, $len, $count, $bgid, $bid);

Prepares a provide-buffers request.

This registers a group of buffers with the ring so later operations using
buffer selection may consume them.

Provided-buffer lifetime is governed by kernel contract plus the module's
ring-side slab management.

=head2 prep_remove_buffers

  $ring->prep_remove_buffers($sqe, $count, $bgid);

Prepares removal of buffers from a provided-buffer group.

The completion result is the number of buffers removed.

This is not a boolean success/failure API.

Buffers already consumed by the kernel are not removable unless they are
first re-provided.

=head1 REGISTRATION METHODS

=head2 register_files

  $ring->register_files(@fds);

Registers fixed files.

=head2 register_files_update

  $ring->register_files_update($offset, @fds);

Updates fixed-file registrations beginning at the given offset.

=head2 unregister_files

  $ring->unregister_files;

Removes all fixed-file registrations.

=head1 CONSTANTS

The module exposes constants corresponding to kernel io_uring flags used
by the test suite and documented API, including values such as:

- C<IOSQE_IO_LINK>
- C<IOSQE_BUFFER_SELECT>
- C<IORING_CQE_F_BUFFER>
- C<IORING_CQE_F_MORE>

Refer to your installed module exports for exact availability.

=head1 RETURN VALUES AND CQE SEMANTICS

Completion-returning methods use the kernel-shaped triple:

  ($user_data, $res, $flags)

Where:

=over 4

=item * C<$user_data>

The 64-bit value previously associated with the SQE via
C<sqe_set_data64>.

=item * C<$res>

The kernel result code for the operation. Non-negative values are
operation-specific success results. Negative values represent negated
errno values from the kernel.

=item * C<$flags>

Raw CQE flags from the kernel.

=back

This module does not wrap completions in objects.

=head1 DESIGN NOTES

This module intentionally preserves explicit io_uring semantics.

It does not provide:

- callbacks
- futures/promises
- automatic submission
- automatic rearming
- connection/socket lifecycle management
- policy-driven buffer recycling

That higher-level behavior should be implemented above this layer.

Helpers such as C<submit_and_wait_min>, C<reap_one>, and C<reap_many>
exist only to reduce boilerplate while preserving explicit control.

=head1 VALIDATED BEHAVIOR

The current implementation has validated support for:

- explicit SQE/CQE workflow
- user_data correlation
- timeout operations
- linked timeouts
- poll add/remove
- poll multishot
- cancellation by user_data
- fixed-file registration and update
- provided buffers
- multishot receive with buffer selection
- CQE buffer ID extraction
- explicit batching helpers
- incremental CQE draining with flat triples

=head1 SEE ALSO

L<io_uring(7)>

L<https://man7.org/linux/man-pages/man7/io_uring.7.html>

=head1 AUTHOR

Linux::Event authors and contributors.

=head1 LICENSE

Same terms as Perl itself.

=cut
