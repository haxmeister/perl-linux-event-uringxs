use v5.36;
use Test::More;

use Linux::Event::UringXS;

my $ring = Linux::Event::UringXS->new(16);
ok($ring, 'created ring');

my $bgid = 23;
my $count = 3;
my $len   = 8;
my $slab  = "\0" x ($count * $len);

sub submit_and_reap ($ring, $sqe, $data64) {
    $ring->sqe_set_data64($sqe, $data64);
    my $submitted = $ring->submit;
    ok($submitted >= 0, "submitted request $data64");

    my ($data, $res, $flags) = $ring->wait_cqe;
    is($data, $data64, "completion $data64 has expected user_data");
    $ring->cqe_seen;
    return ($res, $flags);
}

my $provide1 = $ring->get_sqe;
ok($provide1, 'got first provide_buffers sqe');
$ring->prep_provide_buffers($provide1, $slab, $len, $count, $bgid, 100);
my ($res1, $flags1) = submit_and_reap($ring, $provide1, 14_001);
ok($res1 >= 0, 'first provide_buffers completed successfully');

my $remove1 = $ring->get_sqe;
ok($remove1, 'got first remove_buffers sqe');
$ring->prep_remove_buffers($remove1, $count, $bgid);
my ($res2, $flags2) = submit_and_reap($ring, $remove1, 14_002);
ok($res2 >= 0, 'first remove_buffers completed successfully');

my $provide2 = $ring->get_sqe;
ok($provide2, 'got second provide_buffers sqe');
$ring->prep_provide_buffers($provide2, $slab, $len, $count, $bgid, 200);
my ($res3, $flags3) = submit_and_reap($ring, $provide2, 14_003);
ok($res3 >= 0, 'second provide_buffers completed successfully after remove');

my $remove2 = $ring->get_sqe;
ok($remove2, 'got second remove_buffers sqe');
$ring->prep_remove_buffers($remove2, $count, $bgid);
my ($res4, $flags4) = submit_and_reap($ring, $remove2, 14_004);
ok($res4 >= 0, 'second remove_buffers completed successfully');

ok(Linux::Event::UringXS::IOSQE_BUFFER_SELECT() >= 0, 'IOSQE_BUFFER_SELECT constant remains exposed');
ok(Linux::Event::UringXS::IORING_CQE_F_BUFFER() >= 0, 'IORING_CQE_F_BUFFER constant remains exposed');
is(Linux::Event::UringXS->cqe_buffer_id(123 << 16), 123, 'cqe_buffer_id decodes upper 16-bit buffer id');

done_testing;
