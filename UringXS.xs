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

