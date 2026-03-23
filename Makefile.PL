use v5.36;
use ExtUtils::MakeMaker;
use Alien::liburing ();

my $alien_inc  = Alien::liburing->cflags;
my $alien_libs = Alien::liburing->libs;

WriteMakefile(
  NAME            => 'Linux::Event::UringXS',
  VERSION_FROM    => 'lib/Linux/Event/UringXS.pm',
  ABSTRACT_FROM   => 'lib/Linux/Event/UringXS.pm',
  AUTHOR          => 'Joshua Day',
  LICENSE         => 'perl',

  CONFIGURE_REQUIRES => {
    'ExtUtils::MakeMaker' => 0,
    'Alien::liburing'     => '0.100',
  },

  PREREQ_PM => {
    'Alien::liburing' => '0.100',
  },

  XS => {
    'UringXS.xs' => 'UringXS.c',
  },

  clean => {
    FILES => 'UringXS.c UringXS$(OBJ_EXT)',
  },

  INC  => $alien_inc,
  LIBS => [ $alien_libs ],

  META_MERGE => {
    resources => {
      repository => 'https://github.com/haxmeister/perl-linux-event-uringxs',
    },
  },
);
