use v5.36;
use Test::More;
use Fcntl qw(F_GETFL);

use Linux::Event::UringXS;

my $ring = Linux::Event::UringXS->new(16);
ok($ring, 'created ring');

pipe(my $r, my $w) or die "pipe failed: $!";

my $rc = $ring->register_files([ fileno($r), fileno($w) ]);
ok($rc >= 0, 'registered fixed files');

my $sqe = $ring->get_sqe;
ok($sqe, 'got read sqe');

my $buf = "\0" x 1;
$ring->prep_read($sqe, 0, $buf, 1, 0);
$ring->sqe_set_flags($sqe, Linux::Event::UringXS::IOSQE_FIXED_FILE());
$ring->sqe_set_data64($sqe, 10_001);

my $written = syswrite($w, 'z');
is($written, 1, 'wrote one byte to pipe');

my $submitted = $ring->submit;
ok($submitted >= 0, 'submitted fixed-file read');

my ($data, $res, $flags) = $ring->wait_cqe;
is($data, 10_001, 'fixed-file read completion has expected user_data');
is($res, 1, 'fixed-file read completed with one byte');
is($buf, 'z', 'fixed-file read filled expected byte');
$ring->cqe_seen;

$rc = $ring->register_files_update(1, [ fileno($r) ]);
ok($rc >= 0, 'updated fixed-file table slot');

$rc = $ring->unregister_files;
ok($rc >= 0, 'unregistered fixed files');

close $r;
close $w;

done_testing;
