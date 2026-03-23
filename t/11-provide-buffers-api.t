use v5.36;
use Test::More;

use Linux::Event::UringXS;

my $ring = Linux::Event::UringXS->new(16);
ok($ring, 'created ring');

my $slab = "\0" x 16;
my $provide = $ring->get_sqe;
ok($provide, 'got provide_buffers sqe');

$ring->prep_provide_buffers($provide, $slab, 8, 2, 7, 0);
$ring->sqe_set_data64($provide, 11_001);

my $submitted = $ring->submit;
ok($submitted >= 0, 'submitted provide_buffers');

my ($data, $res, $flags) = $ring->wait_cqe;
is($data, 11_001, 'provide_buffers completion has expected user_data');
ok($res >= 0, 'provide_buffers completed successfully');
$ring->cqe_seen;

my $remove = $ring->get_sqe;
ok($remove, 'got remove_buffers sqe');

$ring->prep_remove_buffers($remove, 2, 7);
$ring->sqe_set_data64($remove, 11_002);

$submitted = $ring->submit;
ok($submitted >= 0, 'submitted remove_buffers');

($data, $res, $flags) = $ring->wait_cqe;
is($data, 11_002, 'remove_buffers completion has expected user_data');
ok($res >= 0, 'remove_buffers completed successfully');
$ring->cqe_seen;

ok(Linux::Event::UringXS::IOSQE_FIXED_FILE() >= 0, 'IOSQE_FIXED_FILE constant is exposed');
ok(Linux::Event::UringXS::IOSQE_BUFFER_SELECT() >= 0, 'IOSQE_BUFFER_SELECT constant is exposed');
ok(Linux::Event::UringXS::IORING_CQE_F_BUFFER() >= 0, 'IORING_CQE_F_BUFFER constant is exposed');
is(Linux::Event::UringXS->cqe_buffer_id(5 << 16), 5, 'buffer id decoder works');

done_testing;
