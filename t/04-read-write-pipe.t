use v5.36;
use Test::More;

use Linux::Event::UringXS;

pipe(my $r, my $w) or die "pipe failed: $!";

my $ring = Linux::Event::UringXS->new(16);

my $payload = "pipe payload via prep_write/prep_read";
my $read_buf = "\0" x 256;

my $read_sqe = $ring->get_sqe;
ok($read_sqe, 'got read sqe');
$ring->prep_read($read_sqe, fileno($r), $read_buf, 256, 0);
$ring->sqe_set_data64($read_sqe, 2001);

my $write_sqe = $ring->get_sqe;
ok($write_sqe, 'got write sqe');
$ring->prep_write($write_sqe, fileno($w), $payload, length($payload), 0);
$ring->sqe_set_data64($write_sqe, 2002);

my $submitted = $ring->submit;
ok($submitted >= 0, 'submit returned non-negative');

my %seen;
for (1 .. 2) {
    my ($data, $res, $flags) = $ring->wait_cqe;
    $seen{$data} = [$res, $flags];
    $ring->cqe_seen;
}

ok(exists $seen{2001}, 'saw read completion');
ok(exists $seen{2002}, 'saw write completion');

is($seen{2002}[0], length($payload), 'write completion length matches');
is($seen{2001}[0], length($payload), 'read completion length matches');

is(length($read_buf), length($payload), 'read buffer logical length updated');
is($read_buf, $payload, 'read buffer contains exact payload');

done_testing;
