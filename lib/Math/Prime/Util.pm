package Math::Prime::Util;
use strict;
use warnings;
use Carp qw/croak confess carp/;

BEGIN {
  $Math::Prime::Util::AUTHORITY = 'cpan:DANAJ';
  $Math::Prime::Util::VERSION = '0.10';
}

# parent is cleaner, and in the Perl 5.10.1 / 5.12.0 core, but not earlier.
# use parent qw( Exporter );
use base qw( Exporter );
our @EXPORT_OK = qw(
                     prime_get_config
                     prime_precalc prime_memfree
                     is_prime is_prob_prime
                     is_strong_pseudoprime is_strong_lucas_pseudoprime
                     miller_rabin
                     primes
                     next_prime  prev_prime
                     prime_count prime_count_lower prime_count_upper prime_count_approx
                     nth_prime nth_prime_lower nth_prime_upper nth_prime_approx
                     random_prime random_ndigit_prime random_nbit_prime
                     factor all_factors moebius euler_phi
                     ExponentialIntegral LogarithmicIntegral RiemannR
                   );
our %EXPORT_TAGS = (all => [ @EXPORT_OK ]);

# Similar to how boolean handles its option
sub import {
    my @options = grep $_ ne '-nobigint', @_;
    $_[0]->_import_nobigint if @options != @_;
    @_ = @options;
    goto &Exporter::import;
}

sub _import_nobigint {
  undef *factor;        *factor          = \&_XS_factor;
  undef *is_prime;      *is_prime        = \&_XS_is_prime;
  undef *is_prob_prime; *is_prob_prime   = \&_XS_is_prob_prime;
  undef *next_prime;    *next_prime      = \&_XS_next_prime;
  undef *prev_prime;    *prev_prime      = \&_XS_prev_prime;
  undef *prime_count;   *prime_count     = \&_XS_prime_count;
  undef *nth_prime;     *nth_prime       = \&_XS_nth_prime;
  undef *is_strong_pseudoprime;  *is_strong_pseudoprime = \&_XS_miller_rabin;
  undef *miller_rabin;  *miller_rabin    = \&_XS_miller_rabin;
}

my %_Config;

BEGIN {

  # Load PP code.  Nothing exported.
  require Math::Prime::Util::PP;
  # There is no GMP module yet
  $_Config{'gmp'} = 0;

  eval {
    require XSLoader;
    XSLoader::load(__PACKAGE__, $Math::Prime::Util::VERSION);
    prime_precalc(0);
    $_Config{'xs'} = 1;
    $_Config{'maxbits'} = _XS_prime_maxbits();
    1;
  } or do {
    $_Config{'xs'} = 0;
    $_Config{'maxbits'} = Math::Prime::Util::PP::_PP_prime_maxbits();
    carp "Using Pure Perl implementation: $@";

    *_prime_memfreeall = \&Math::Prime::Util::PP::_prime_memfreeall;
    *prime_memfree  = \&Math::Prime::Util::PP::prime_memfree;
    *prime_precalc  = \&Math::Prime::Util::PP::prime_precalc;

    # These probably shouldn't even be exported
    *trial_factor   = \&Math::Prime::Util::PP::trial_factor;
    *fermat_factor  = \&Math::Prime::Util::PP::fermat_factor;
    *holf_factor    = \&Math::Prime::Util::PP::holf_factor;
    *squfof_factor  = \&Math::Prime::Util::PP::squfof_factor;
    *pbrent_factor  = \&Math::Prime::Util::PP::pbrent_factor;
    *prho_factor    = \&Math::Prime::Util::PP::prho_factor;
    *pminus1_factor = \&Math::Prime::Util::PP::pminus1_factor;
  }
}
END {
  _prime_memfreeall;
}

if ($_Config{'maxbits'} == 32) {
  $_Config{'maxparam'}    = 4294967295;
  $_Config{'maxdigits'}   = 10;
  $_Config{'maxprime'}    = 4294967291;
  $_Config{'maxprimeidx'} = 203280221;
} else {
  $_Config{'maxparam'}    = 18446744073709551615;
  $_Config{'maxdigits'}   = 20;
  $_Config{'maxprime'}    = 18446744073709551557;
  $_Config{'maxprimeidx'} = 425656284035217743;
}

# used for code like:
#    return _XS_foo($n)  if $n <= $_XS_MAXVAL
# which builds into one scalar whether XS is available and if we can call it.
my $_XS_MAXVAL = $_Config{'xs'}  ?  $_Config{'maxparam'}  :  -1;

# Notes on how we're dealing with big integers:
#
#  1) if (ref($n) eq 'Math::BigInt')
#     $n is a bigint, so do bigint stuff
#
#  2) if (defined $bigint::VERSION && $n > ~0)
#     make $n into a bigint.  This is debatable, but they *did* hand us a
#     string with a big integer in it.  The big gotcha here is that
#     is_strong_lucas_pseudoprime does bigint computations, so it will load
#     up bigint and there is no way to unload it.
#
#  3) if (ref($n) =~ /^Math::Big/)
#     $n is a big int, float, or rat.  We probably want this as an int.
#
#  $n = $n->numify if $n < ~0 && ref($n) =~ /^Math::Big/;
#     get us out of big math if we can
#
# Sadly, non-modern versions of bignum (5.12.4 and earlier) completely make a
# mess of things like BigInt::numify and int(BigFloat).  Using int($x->bstr)
# seems to work.
# E.g.:
#    $n = 33662485846146713;  $n->numify;   $n is now 3.36624858461467e+16


sub prime_get_config {
  my %config = %_Config;

  $config{'precalc_to'} = ($_Config{'xs'})
                        ? _get_prime_cache_size
                        : Math::Prime::Util::PP::_get_prime_cache_size;

  return \%config;

}

sub _validate_positive_integer {
  my($n, $min, $max) = @_;
  croak "Parameter must be defined" if !defined $n;
  croak "Parameter '$n' must be a positive integer" if $n =~ tr/0123456789//c;
  croak "Parameter '$n' must be >= $min" if defined $min && $n < $min;
  croak "Parameter '$n' must be <= $max" if defined $max && $n > $max;
  if ($n <= $_Config{'maxparam'}) {
    $_[0] = $n->as_number() if ref($n) eq 'Math::BigFloat';
    $_[0] = int($n->bstr) if ref($n) eq 'Math::BigInt';
  } elsif (ref($n) ne 'Math::BigInt') {
    croak "Parameter '$n' outside of integer range" if !defined $bigint::VERSION;
    $_[0] = Math::BigInt->new("$n"); # Make $n a proper bigint object
  }
  # One of these will be true:
  #     1) $n <= max and $n is not a bigint
  #     2) $n  > max and $n is a bigint
  1;
}

# It you use bigint then call one of the approx/bounds/math functions, you'll
# end up with full bignum turned on.  This seems non-optimal.  However, if I
# don't do this, then you'll get wrong results and end up with it turned on
# _anyway_.  As soon as anyone does something like log($n) where $n is a
# Math::BigInt, it auto-upgrade and loads up Math::BigFloat.
#
# Ideally we'd notice we were causing this, and turn off Math::BigFloat after
# we were done.
sub _upgrade_to_float {
  my($n) = @_;
  return $n unless defined $Math::BigInt::VERSION || defined $Math::BigFloat::VERSION;
  do { require Math::BigFloat; Math::BigFloat->import; } if defined $Math::BigInt::VERSION && !defined $Math::BigFloat::VERSION;
  return Math::BigFloat->new($n);
}

my @_primes_small = (
   0,2,3,5,7,11,13,17,19,23,29,31,37,41,43,47,53,59,61,67,71,73,79,83,89,97,
   101,103,107,109,113,127,131,137,139,149,151,157,163,167,173,179,181,191,
   193,197,199,211,223,227,229,233,239,241,251,257,263,269,271,277,281,283,
   293,307,311,313,317,331,337,347,349,353,359,367,373,379,383,389,397,401,
   409,419,421,431,433,439,443,449,457,461,463,467,479,487,491,499);
my @_prime_count_small = (
   0,0,1,2,2,3,3,4,4,4,4,5,5,6,6,6,6,7,7,8,8,8,8,9,9,9,9,9,9,10,10,
   11,11,11,11,11,11,12,12,12,12,13,13,14,14,14,14,15,15,15,15,15,15,
   16,16,16,16,16,16,17,17,18,18,18,18,18,18,19);
#my @_prime_next_small = (
#   2,2,3,5,5,7,7,11,11,11,11,13,13,17,17,17,17,19,19,23,23,23,23,
#   29,29,29,29,29,29,31,31,37,37,37,37,37,37,41,41,41,41,43,43,47,
#   47,47,47,53,53,53,53,53,53,59,59,59,59,59,59,61,61,67,67,67,67,67,67,71);





#############################################################################

sub primes {
  my $optref = (ref $_[0] eq 'HASH')  ?  shift  :  {};
  croak "no parameters to primes" unless scalar @_ > 0;
  croak "too many parameters to primes" unless scalar @_ <= 2;
  my $low = (@_ == 2)  ?  shift  :  2;
  my $high = shift;

  _validate_positive_integer($low);
  _validate_positive_integer($high);

  my $sref = [];
  return $sref if ($low > $high) || ($high < 2);

  if ( $high > $_XS_MAXVAL) {
    return Math::Prime::Util::PP::primes($low,$high);
  }

  my $method = $optref->{'method'};
  $method = 'Dynamic' unless defined $method;

  if ($method =~ /^(Dyn\w*|Default|Generate)$/i) {
    # Dynamic -- we should try to do something smart.

    # Tiny range?
    if (($low+1) >= $high) {
      $method = 'Trial';

    # Fast for cached sieve?
    } elsif (($high <= (65536*30)) || ($high <= _get_prime_cache_size)) {
      $method = 'Sieve';

    # More memory than we should reasonably use for base sieve?
    } elsif ($high > (32*1024*1024*30)) {
      $method = 'Segment';

    # Only want half or less of the range low-high ?
    } elsif ( int($high / ($high-$low)) >= 2 ) {
      $method = 'Segment';

    } else {
      $method = 'Sieve';
    }
  }

  if ($method =~ /^Simple\w*$/i) {
    carp "Method 'Simple' is deprecated.";
    $method = 'Erat';
  }

  if    ($method =~ /^Trial$/i)     { $sref = trial_primes($low, $high); }
  elsif ($method =~ /^Erat\w*$/i)   { $sref = erat_primes($low, $high); }
  elsif ($method =~ /^Seg\w*$/i)    { $sref = segment_primes($low, $high); }
  elsif ($method =~ /^Sieve$/i)     { $sref = sieve_primes($low, $high); }
  else { croak "Unknown prime method: $method"; }

  # Using this line:
  #   return (wantarray) ? @{$sref} : $sref;
  # would allow us to return an array ref in scalar context, and an array
  # in array context.  Handy for people who might write:
  #   @primes = primes(100);
  # but I think the dual interface could bite us later.
  return $sref;
}


# For random primes, there are two good papers that should be examined:
#
#  "Fast Generation of Prime Numbers and Secure Public-Key Cryptographic Parameters"
#  by Ueli M. Maurer, 1995
#  http://citeseerx.ist.psu.edu/viewdoc/summary?doi=10.1.1.26.2151
#  related discussions:
#      http://www.daimi.au.dk/~ivan/provableprimesproject.pdf
#      Handbook of Applied Cryptography by Menezes, et al.
#
#  "Close to Uniform Prime Number Generation With Fewer Random Bits"
#   by Pierre-Alain Fouque and Mehdi Tibouchi, 2011
#   http://eprint.iacr.org/2011/481
#
#
#  Some things to note:
#
#    1) Joye and Paillier have patents on their methods.  Never use them.
#
#    2) The easy-peasy method of next_prime(random number) is fast but gives
#       gives a terribly distribution, and not only in the obvious positive
#       bias.  The probability for a prime is proportional to its gap, which
#       is really a bad distribution.
#
# For standard random primes, the implementation is very similar to Fouque's
# Algorithm 1.  For ranges of 32-bits or less, the distribution is uniform.
# For larger ranges it is very close (See Foque/Tibouchi).
#
# The random_maurer_prime function uses Maurer's algorithm of course.
#
# The current code is pretty fast for native types, but very slow for bigints.
#      37uS for   24-bit
#     0.25s for   64-bit
#     0.2s  for  128-bit
#     1.3s  for  256-bit
#     9s    for  512-bit
#   3m      for 1024-bit
#  ~4m      for 2048-bit
# ~80m      for 4096-bit
#
# A lot of this is due to is_prime on bigints however.
#     
# To verify distribution:
#   perl -Iblib/lib -Iblib/arch -MMath::Prime::Util=:all -E 'my %freq; $n=1000000; $freq{random_nbit_prime(6)}++ for (1..$n); printf("%4d %6.3f%%\n", $_, 100.0*$freq{$_}/$n) for sort {$a<=>$b} keys %freq;'
#   perl -Iblib/lib -Iblib/arch -MMath::Prime::Util=:all -E 'my %freq; $n=1000000; $freq{random_prime(1260437,1260733)}++ for (1..$n); printf("%4d %6.3f%%\n", $_, 100.0*$freq{$_}/$n) for sort {$a<=>$b} keys %freq;'

{
  # Note:  I was using rand($range), but Math::Random::MT ignores the argument
  #        instead of following its documentation.
  my $irandf = (defined &::rand) ? sub { return int(::rand()*shift); }
                                 : sub { return int(rand()*shift); };
  # TODO: Look at RANDBITS if using system rand
  my $rand_max_bits = 31;
  my $rand_max_val  = 1 << $rand_max_bits;
  my $_rdata = 0;
  my $_rbits = 0;
  my $get_rand_bit = sub {
    if ($_rbits == 0) {
      $_rdata = $irandf->($rand_max_val);
      $_rbits = $rand_max_bits;
    }
    my $r = $_rdata & 1;
    $_rdata >>= 1;
    $_rbits--;
    $r;
  };

  # Returns a uniform number between [0,$range] inclusive.
  my $get_rand_range = sub {
    my($range) = @_;
    my $max = int($range) + 1;
    my $offset = 0;
    while ($max > 1) {
      if ($max <= $rand_max_val) { $offset += $irandf->($max); last; }
      my $part = $max >> 1;
      $part++ if ($max & 1) && $get_rand_bit->();
      $offset += $part if $get_rand_bit->();
      $max -= $part;
    }
    $offset;
  };
  # The above routine isn't perfect, but it works pretty well.  It's repeatedly
  # partitioning the space into two pieces selected at random.  For odd
  # ranges the two edges are selected with slightly higher priority because
  # we're approximating 1/r using powers of 2.  The error rapidly reduces
  # as r increases.  By calling out to irandf when max is small enough we can
  # make it basically go away.
  #
  # The other implementation choice I can think of is to call irandf a bunch
  # of times to get a random number R >= r.  Let m = int(R/r).  If R < m*r
  # then return R % m.  Repeat otherwise.  This description isn't quite right
  # in that we want to generate R with at least as many random bits as r, not
  # necessarily greater, and m is related to the bits in each.


  # Sub to call with low and high already primes and verified range.
  my $_random_prime = sub {
    my($low,$high) = @_;
    my $prime;

    # { my $bsize = 100; my @bins; my $counts = 10000000;
    #   for my $c (1..$counts) { $bins[ $get_rand_range->($bsize) ]++; }
    #   for my $b (0..$bsize) {printf("%4d %8.5f%%\n", $b, $bins[$b]/$counts);}

    # low and high are both primes, and low < high.

    if ($high < 30000) {
      # nice deterministic solution, but gets very costly with large values.
      my $li = prime_count($low);
      my $hi = prime_count($high);
      my $irange = $hi - $li + 1;
      my $rand = $irandf->($irange);
      return nth_prime($li + $rand);
    }

    $low-- if $low == 2;  # Low of 2 becomes 1 for our program.
    croak "Invalid _random_prime parameters" if ($low % 2) == 0 || ($high % 2) == 0;

    # We're going to look at the odd numbers only.
    #my $range = $high - $low + 1;
    my $oddrange = int(($high - $low) / 2) + 1;

    # If $low is large (e.g. >10 digits) and $range is small (say ~10k), it
    # would be fastest to call primes in the range and randomly pick one.  I'm
    # not implementing it now because it seems like a rare case.

    if ($oddrange <= $rand_max_val) {
      # Our range is small enough we can just call rand once and be happy.
      # Generate random numbers in the interval until one is prime.
      my $loop_limit = 2000 * 1000;  # To protect against broken rand
      while (1) {
        $prime = $low + 2 * $irandf->($oddrange);
        croak "Random function broken?" if $loop_limit-- < 0;
        next if $prime > 11 && (!($prime % 3) || !($prime % 5) || !($prime % 7) || !($prime % 11));
        return 2 if $prime == 1;  # Remember the special case for 2.
        last if is_prime($prime);
      }
      return $prime;
    }

    # We have an ocean of range, and a teaspoon to hold randomness.

    # Since we have an arbitrary range and not a power of two, I don't see how
    # Fouque's algorithm A1 could be used (where we generate lower bits and
    # generate random sets of upper).  What I'm doing is pulling out 2^31 lower
    # bits, then randomly select all the uppers.  We iterate adding in the lower
    # bits.

    my $srange = $oddrange - $rand_max_val - 1;
    my $offset = $get_rand_range->($srange);
    my $primelow = $low + 2 * $offset;

    # Generate random numbers in the interval until one is prime.
    my $loop_limit = 2000 * 1000;  # To protect against broken rand
    while (1) {
      $prime = $primelow + ( 2 * $irandf->($rand_max_val) );
      die "$prime > $high" if $prime > $high;
      croak "Random function broken?" if $loop_limit-- < 0;
      if (ref($prime) eq 'Math::BigInt') {
        next if $prime > 53 && Math::BigInt::bgcd($prime, "16294579238595022365") != 1;
      } else {
        next if $prime > 13 && (!($prime % 3) || !($prime % 5) || !($prime % 7) || !($prime % 11) || !($prime % 13));
      }
      do { $prime = 2; last; } if $prime == 1;   # special case for low = 2
      last if is_prime($prime);
    }
    return $prime;
  };
  # Cache of tight bounds for each digit.  Helps performance a lot.
  my @_random_ndigit_ranges = (undef, [2,7], [11,97] );
  my @_random_nbit_ranges   = (undef, undef, [2,3],[5,7] );

  sub random_prime {
    my $low = (@_ == 2)  ?  shift  :  2;
    my $high = shift;
    _validate_positive_integer($low);
    _validate_positive_integer($high);

    # Tighten the range to the nearest prime.
    $low = 2 if $low < 2;
    $low = next_prime($low - 1);
    $high = ($high < ~0)  ?  prev_prime($high + 1)  :  prev_prime($high);
    return $low if ($low == $high) && is_prime($low);
    return if $low >= $high;

    # At this point low and high are both primes, and low < high.
    return $_random_prime->($low, $high);
  }

  sub random_ndigit_prime {
    my($digits) = @_;
    _validate_positive_integer($digits, 1,
             (defined $bigint::VERSION) ? 10000 : $_Config{'maxdigits'});

    if (!defined $_random_ndigit_ranges[$digits]) {
      if ( defined $bigint::VERSION  &&  $digits >= $_Config{'maxdigits'} ) {
        my $low  = Math::BigInt->new('10')->bpow($digits-1);
        my $high = Math::BigInt->new('10')->bpow($digits);
        $_random_ndigit_ranges[$digits] = [next_prime($low), prev_prime($high)];
      } else {
        my $low  = int(10 ** ($digits-1));
        my $high = int(10 ** $digits);
        $high = ~0 if $high > ~0;
        $_random_ndigit_ranges[$digits] = [next_prime($low), prev_prime($high)];
      }
    }
    my ($low, $high) = @{$_random_ndigit_ranges[$digits]};
    return $_random_prime->($low, $high);
  }

  sub random_nbit_prime {
    my($bits) = @_;
    _validate_positive_integer($bits, 2,
             (defined $bigint::VERSION) ? 100000 : $_Config{'maxbits'});

    if (!defined $_random_nbit_ranges[$bits]) {
      if ( defined $bigint::VERSION  &&  $bits >= $_Config{'maxbits'} ) {
        my $low  = Math::BigInt->new('2')->bpow($bits-1);
        my $high = Math::BigInt->new('2')->bpow($bits);
        # Don't pull the range in to primes, just odds
        $_random_nbit_ranges[$bits] = [$low+1, $high-1];
      } else {
        #my $low  = int(2 ** ($bits-1));
        my $low  = 1 << ($bits-1);
        my $high = ~0 >> ($_Config{'maxbits'} - $bits);
        $_random_nbit_ranges[$bits] = [next_prime($low), prev_prime($high)];
      }
    }
    my ($low, $high) = @{$_random_nbit_ranges[$bits]};
    return $_random_prime->($low, $high);
  }

  sub random_maurer_prime {
    my($k) = @_;
    _validate_positive_integer($k, 2,
             (defined $bigint::VERSION) ? 100000 : $_Config{'maxbits'});

    my $p0 = 32;    # Use uniform random method for this many or less

    return random_nbit_prime($k) if $k <= $p0;

    use Math::BigInt;
    use Math::BigFloat;

    my $c = Math::BigFloat->new("0.09");  # higher = more trial divisions
    my $r = Math::BigFloat->new("0.5");
    my $m = 24;   # How much randomness we're trying to get at a time
    my $B = ($c * $k * $k)->bfloor;

    if ($k > 2*$m) {
      my $rbits = 0;
      while ($rbits <= $m) {
        my $s = Math::BigFloat->new( $irandf->($rand_max_val) )->bdiv($rand_max_val);
        my $r = Math::BigFloat->new(2)->bpow($s-1);
        $rbits = $k - ($r*$k);
      }
    }
    # I've seen +0, +1, and +2 here.  Menezes uses +1.
    my $q = random_maurer_prime( ($r * $k)->bfloor + 1 );
    #warn "B = $B  r = $r  k = $k  q = $q\n";
    my $I = Math::BigInt->new(2)->bpow($k-1)->bdiv(2 * $q)->bfloor;
    #warn "I = $I\n";

    my @primes = @{primes($B)};

    while (1) {
      # R is a random number between $I+1 and 2*$I
      my $R = $I + 1 + $get_rand_range->( int($I - 1) );
      my $n = 2 * $R * $q + 1;
      # We constructed a promising looking $n.  Now test it.

      # Trial divide up to $B
      my $looks_prime = 1;
      foreach my $p (@primes) {
        do { $looks_prime = 0; last; } if ($n % $p) == 0;
      }
      next unless $looks_prime;
      #warn "$n passes trial division\n";

      # a is a random number between 2 and $n-2
      my $a = 2 + $get_rand_range->( $n - 4 );
      my $b = $a->copy->bmodpow($n-1, $n);
      next unless $b == 1;
      #warn "$n passes a^n-1 == 1\n";

      # We now get to choose between Maurer's original proposal:
      #   check gcd(a^((n-1)/q)-1,n)==1 for each factor q of n-1
      # thusly:

      $b = $a->copy->bmodpow(2*$R, $n);
      next unless Math::BigInt::bgcd($b-1, $n) == 1;
      #warn "$n passes final gcd\n";

      # Or via a different method, where we check q >= n**1/3 and also do
      # some tests on x & y from 2R = xq+y.  Crypt::Primes does the q test
      # but doesn't seem to do the x/y and perfect square portions.
      #   next if ($q <= $n->copy->bpow(1/3));
      #   next if ....

      # Finally, verify with a BPSW test on the result.  This will either,
      #  1) save us from accidently outputing a non-prime due to some mistake
      #  2) make history by finding the first known BPSW pseudo-prime
      die "Maurer prime $n failed BPSW" unless is_prob_prime($n);
      #warn "     and passed BPSW.\n";

      return $n;
    }
    no Math::BigFloat;
    no Math::BigInt;
  }
}

sub all_factors {
  my $n = shift;
  my @factors = factor($n);
  my %all_factors;
  foreach my $f1 (@factors) {
    next if $f1 >= $n;
    # We're adding to %all_factors in the loop, so grab the keys now.
    my @all = keys %all_factors;;
    if (!defined $bigint::VERSION) {
      foreach my $f2 (@all) {
        $all_factors{$f1*$f2} = 1 if ($f1*$f2) < $n;
      }
    } else {
      # Many of the factors will be numified after coming back, so we need
      # to make sure we're using bigints when we calculate the product.
      foreach my $f2 (@all) {
        my $product = Math::BigInt->new("$f1") * Math::BigInt->new("$f2");
        $product = int($product->bstr) if $product <= ~0;
        $all_factors{$product} = 1 if $product < $n;
      }
    }
    $all_factors{$f1} = 1;
  }
  @factors = sort {$a<=>$b} keys %all_factors;
  return @factors;
}


# A008683 Moebius function mu(n)
# A030059, A013929, A030229, A002321, A005117, A013929 all relate.

# One can argue for the Omega function (A001221), Euler Phi (A000010), and
# Merten's functions also.

sub moebius {
  my($n) = @_;
  _validate_positive_integer($n, 1);
  return 1 if $n == 1;

  # Quick check for small replicated factors
  return 0 if ($n >= 25) && (($n % 4) == 0 || ($n % 9) == 0 || ($n % 25) == 0);

  my @factors = factor($n);
  my %all_factors;
  foreach my $factor (@factors) {
    return 0 if $all_factors{$factor}++;
  }
  return (((scalar @factors) % 2) == 0) ? 1 : -1;
}


# Euler Phi, aka Euler Totient.  A000010

sub euler_phi {
  my($n) = @_;
  # SAGE defines this to be 0 for all n <= 0.  Others choose differently.
  return 0 if defined $n && $n <= 0;  # Following SAGE's logic here.
  _validate_positive_integer($n);
  return 1 if $n <= 1;

  my %factor_mult;
  my @factors = grep { !$factor_mult{$_}++ } factor($n);

  # Direct from Euler's product formula.  Note division will be exact.
  #my $totient = $n;
  #foreach my $factor (@factors) {
  #  $totient = int($totient/$factor) * ($factor-1);
  #}

  # Alternate way doing multiplications only.
  my $totient = 1;
  foreach my $factor (@factors) {
    $totient *= ($factor - 1);
    $totient *= $factor for (2 .. $factor_mult{$factor});
  }

  $totient;
}

# Omega function A001221.  Don't export.
sub omega {
  my($n) = @_;
  return 0 if defined $n && $n <= 1;
  _validate_positive_integer($n);
  my %factor_mult;
  my @factors = grep { !$factor_mult{$_}++ } factor($n);
  return scalar @factors;
}


#############################################################################
# Front ends to functions.
#
# These will do input validation, then call the appropriate internal function
# based on the input (XS, GMP, PP).
#############################################################################

# Doing a sub here like:
#
#   sub foo {  my($n) = @_;  _validate_positive_integer($n);
#              return _XS_... if $_Config{'xs'} && $n <= $_Config{'maxparam'}; }
#
# takes about 0.7uS on my machine.  Operations like is_prime and factor run
# on small input (under 100_000) typically take a lot less time than this.  So
# the overhead for these is significantly more than just the XS call itself.
#
# The plan for some of these functions will be to invert the operation.  That
# is, the XS functions will look at the input and make a call here if the input
# is large.

sub is_prime {
  my($n) = @_;
  return 0 if $n <= 0;
  _validate_positive_integer($n);

  return _XS_is_prime($n) if $n <= $_XS_MAXVAL;
  return is_prob_prime($n);
}

sub next_prime {
  my($n) = @_;
  _validate_positive_integer($n);

  return _XS_next_prime($n) if $n <= $_XS_MAXVAL;
  return Math::Prime::Util::PP::next_prime($n);
}

sub prev_prime {
  my($n) = @_;
  _validate_positive_integer($n);

  return _XS_prev_prime($n) if $n <= $_XS_MAXVAL;
  return Math::Prime::Util::PP::prev_prime($n);
}

sub prime_count {
  my($low,$high) = @_;
  if (defined $high) {
    _validate_positive_integer($low);
    _validate_positive_integer($high);
  } else {
    ($low,$high) = (2, $low);
    _validate_positive_integer($high);
  }
  return 0 if $high < 2  ||  $low > $high;

  return _XS_prime_count($low,$high) if $high <= $_XS_MAXVAL;
  return Math::Prime::Util::PP::prime_count($low,$high);
}

sub nth_prime {
  my($n) = @_;
  _validate_positive_integer($n);

  return _XS_nth_prime($n) if $_Config{'xs'} && $n <= $_Config{'maxprimeidx'};
  return Math::Prime::Util::PP::nth_prime($n);
}

sub factor {
  my($n) = @_;
  _validate_positive_integer($n);

  return _XS_factor($n) if $n <= $_XS_MAXVAL;
  return Math::Prime::Util::PP::factor($n);
}

sub is_strong_pseudoprime {
  my($n) = shift;
  _validate_positive_integer($n);
  # validate bases?
  return _XS_miller_rabin($n, @_) if $n <= $_XS_MAXVAL;
  return Math::Prime::Util::PP::miller_rabin($n, @_);
}

sub is_strong_lucas_pseudoprime {
  return Math::Prime::Util::PP::is_strong_lucas_pseudoprime(@_);
}

sub miller_rabin {
  #warn "miller_rabin() is deprecated. Use is_strong_pseudoprime instead.";
  return is_strong_pseudoprime(@_);
}

#############################################################################

  # Timings for various combinations, given the current possibilities of:
  #    1) XS MR optimized (either x86-64, 32-bit on 64-bit mach, or half-word)
  #    2) XS MR non-optimized (big input not on 64-bit machine)
  #    3) PP MR with small input (non-bigint Perl)
  #    4) PP MR with large input (using functions for mulmod)
  #    5) PP MR with full bigints
  #    6) PP Lucas with small input
  #    7) PP Lucas with large input
  #    8) PP Lucas with full bigints
  #
  # Time for one test:
  #       0.5uS  XS MR with small input
  #       0.8uS  XS MR with large input
  #       7uS    PP MR with small input
  #     400uS    PP MR with large input
  #    5000uS    PP MR with bigint
  #    2700uS    PP LP with small input
  #    6100uS    PP LP with large input
  #    7400uS    PP LP with bigint

sub is_prob_prime {
  my($n) = @_;
  return 0 if defined $n && $n < 2;
  _validate_positive_integer($n);

  return _XS_is_prob_prime($n) if $n <= $_XS_MAXVAL;

  return 2 if $n == 2 || $n == 3 || $n == 5 || $n == 7;
  return 0 if $n < 11;
  return 0 if ($n % 2) == 0 || ($n % 3) == 0 || ($n % 5) == 0 || ($n % 7) == 0;
  foreach my $i (qw/11 13 17 19 23 29 31 37 41 43 47 53 59 61 67 71/) {
    return 2 if $i*$i > $n;   return 0 if ($n % $i) == 0;
  }

  if ($n < 105936894253) {   # BPSW seems to be faster after this
    # Deterministic set of Miller-Rabin tests.
    my @bases;
    if    ($n <          9080191) { @bases = (31, 73); }
    elsif ($n <       4759123141) { @bases = (2, 7, 61); }
    elsif ($n <     105936894253) { @bases = (2, 1005905886, 1340600841); }
    elsif ($n <   31858317218647) { @bases = (2, 642735, 553174392, 3046413974); }
    elsif ($n < 3071837692357849) { @bases = (2, 75088, 642735, 203659041, 3613982119); }
    else                          { @bases = (2, 325, 9375, 28178, 450775, 9780504, 1795265022); }
    return Math::Prime::Util::PP::miller_rabin($n, @bases)  ?  2  :  0;
  }

  # BPSW probable prime.  No composites are known to have passed this test
  # since it was published in 1980, though we know infinitely many exist.
  # It has also been verified that no 64-bit composite will return true.
  # Slow since it's all in PP, but it's the Right Thing To Do.

  return 0 unless Math::Prime::Util::PP::miller_rabin($n, 2);
  return 0 unless Math::Prime::Util::PP::is_strong_lucas_pseudoprime($n);
  return ($n <= 18446744073709551615)  ?  2  :  1;
}

#############################################################################

sub prime_count_approx {
  my($x) = @_;
  _validate_positive_integer($x);

  return $_prime_count_small[$x] if $x <= $#_prime_count_small;

  # Turn on high precision FP if they gave us a big number.
  $x = _upgrade_to_float($x) if ref($x) eq 'Math::BigInt';

  #    Method             10^10 %error  10^19 %error
  #    -----------------  ------------  ------------
  #    average bounds      .01%          .0002%
  #    li(n)               .0007%        .00000004%
  #    li(n)-li(n^.5)/2    .0004%        .00000001%
  #    R(n)                .0004%        .00000001%

  # return int( (prime_count_upper($x) + prime_count_lower($x)) / 2);

  # return int( LogarithmicIntegral($x) );

  # return int( LogarithmicIntegral($x) - LogarithmicIntegral(sqrt($x))/2 );

  my $result = RiemannR($x) + 0.5;

  return Math::BigInt->new($result->bfloor->bstr()) if ref($result) eq 'Math::BigFloat';
  return int($result);
}

sub prime_count_lower {
  my($x) = @_;
  _validate_positive_integer($x);

  return $_prime_count_small[$x] if $x <= $#_prime_count_small;

  $x = _upgrade_to_float($x) if ref($x) eq 'Math::BigInt';

  my $flogx = log($x);

  # Chebyshev:            1*x/logx       x >= 17
  # Rosser & Schoenfeld:  x/(logx-1/2)   x >= 67
  # Dusart 1999:          x/logx*(1+1/logx+1.8/logxlogx)  x >= 32299

  # For smaller numbers this works out well.
  return int( $x / ($flogx - 0.7) ) if $x < 599;

  my $a;
  # Hand tuned for small numbers (< 60_000M)
  if    ($x <       2700) { $a = 0.30; }
  elsif ($x <       5500) { $a = 0.90; }
  elsif ($x <      19400) { $a = 1.30; }
  elsif ($x <      32299) { $a = 1.60; }
  elsif ($x <     176000) { $a = 1.80; }
  elsif ($x <     315000) { $a = 2.10; }
  elsif ($x <    1100000) { $a = 2.20; }
  elsif ($x <    4500000) { $a = 2.31; }
  elsif ($x <  233000000) { $a = 2.36; }
  elsif ($x < 5433800000) { $a = 2.32; }
  elsif ($x <60000000000) { $a = 2.15; }
  else                    { $a = 1.80; } # Dusart 1999, page 14

  my $result = ($x/$flogx) * (1.0 + 1.0/$flogx + $a/($flogx*$flogx));
  $result = Math::BigInt->new($result->bfloor->bstr()) if ref($result) eq 'Math::BigFloat';
  return int($result);
}

sub prime_count_upper {
  my($x) = @_;
  _validate_positive_integer($x);

  return $_prime_count_small[$x] if $x <= $#_prime_count_small;

  $x = _upgrade_to_float($x) if ref($x) eq 'Math::BigInt';

  # Chebyshev:            1.25506*x/logx       x >= 17
  # Rosser & Schoenfeld:  x/(logx-3/2)         x >= 67
  # Dusart 1999:          x/logx*(1+1/logx+2.51/logxlogx)  x >= 355991

  my $flogx = log($x);

  # These work out well for small values
  return int( ($x / ($flogx - 1.048)) + 1.0 ) if $x <  1621;
  return int( ($x / ($flogx - 1.071)) + 1.0 ) if $x <  5000;
  return int( ($x / ($flogx - 1.098)) + 1.0 ) if $x < 15900;

  my $a;
  # Hand tuned for small numbers (< 60_000M)
  if    ($x <      24000) { $a = 2.30; }
  elsif ($x <      59000) { $a = 2.48; }
  elsif ($x <     350000) { $a = 2.52; }
  elsif ($x <     355991) { $a = 2.54; }
  elsif ($x <     356000) { $a = 2.51; }
  elsif ($x <    3550000) { $a = 2.50; }
  elsif ($x <    3560000) { $a = 2.49; }
  elsif ($x <    5000000) { $a = 2.48; }
  elsif ($x <    8000000) { $a = 2.47; }
  elsif ($x <   13000000) { $a = 2.46; }
  elsif ($x <   18000000) { $a = 2.45; }
  elsif ($x <   31000000) { $a = 2.44; }
  elsif ($x <   41000000) { $a = 2.43; }
  elsif ($x <   48000000) { $a = 2.42; }
  elsif ($x <  119000000) { $a = 2.41; }
  elsif ($x <  182000000) { $a = 2.40; }
  elsif ($x <  192000000) { $a = 2.395; }
  elsif ($x <  213000000) { $a = 2.390; }
  elsif ($x <  271000000) { $a = 2.385; }
  elsif ($x <  322000000) { $a = 2.380; }
  elsif ($x <  400000000) { $a = 2.375; }
  elsif ($x <  510000000) { $a = 2.370; }
  elsif ($x <  682000000) { $a = 2.367; }
  elsif ($x <60000000000) { $a = 2.362; }
  else                    { $a = 2.51; }

  # Old versions of Math::BigFloat will do the Wrong Thing with this.
  #return int( ($x/$flogx) * (1.0 + 1.0/$flogx + $a/($flogx*$flogx)) + 1.0 );
  my $result = ($x/$flogx) * (1.0 + 1.0/$flogx + $a/($flogx*$flogx)) + 1.0;
  return Math::BigInt->new($result->bfloor->bstr()) if ref($result) eq 'Math::BigFloat';
  return int($result);

}

#############################################################################

sub nth_prime_approx {
  my($n) = @_;
  _validate_positive_integer($n);

  return $_primes_small[$n] if $n <= $#_primes_small;

  $n = _upgrade_to_float($n) if ref($n) eq 'Math::BigInt';

  my $flogn  = log($n);
  my $flog2n = log($flogn);

  # Cipolla 1902:
  #    m=0   fn * ( flogn + flog2n - 1 );
  #    m=1   + ((flog2n - 2)/flogn) );
  #    m=2   - (((flog2n*flog2n) - 6*flog2n + 11) / (2*flogn*flogn))
  #    + O((flog2n/flogn)^3)
  #
  # Shown in Dusart 1999 page 12, as well as other sources such as:
  #   http://www.emis.de/journals/JIPAM/images/153_02_JIPAM/153_02.pdf
  # where the main issue you run into is that you're doing polynomial
  # interpolation, so it oscillates like crazy with many high-order terms.
  # Hence I'm leaving it at m=2.
  #

  my $approx = $n * ( $flogn + $flog2n - 1
                      + (($flog2n - 2)/$flogn)
                      - ((($flog2n*$flog2n) - 6*$flog2n + 11) / (2*$flogn*$flogn))
                    );

  # Apply a correction to help keep values close.
  my $order = $flog2n/$flogn;
  $order = $order*$order*$order * $n;

  if    ($n <        259) { $approx += 10.4 * $order; }
  elsif ($n <        775) { $approx +=  7.52* $order; }
  elsif ($n <       1271) { $approx +=  5.6 * $order; }
  elsif ($n <       2000) { $approx +=  5.2 * $order; }
  elsif ($n <       4000) { $approx +=  4.3 * $order; }
  elsif ($n <      12000) { $approx +=  3.0 * $order; }
  elsif ($n <     150000) { $approx +=  2.1 * $order; }
  elsif ($n <  200000000) { $approx +=  0.0 * $order; }
  else                    { $approx += -0.010 * $order; }

  if ( ($approx >= ~0) && (ref($approx) ne 'Math::BigFloat') ) {
    return $_Config{'maxprime'} if $n <= $_Config{'maxprimeidx'};
    croak "nth_prime_approx($n) overflow";
  }

  return int($approx + 0.5);
}

# The nth prime will be greater than or equal to this number
sub nth_prime_lower {
  my($n) = @_;
  _validate_positive_integer($n);

  return $_primes_small[$n] if $n <= $#_primes_small;

  $n = _upgrade_to_float($n) if ref($n) eq 'Math::BigInt';

  my $flogn  = log($n);
  my $flog2n = log($flogn);  # Note distinction between log_2(n) and log^2(n)

  # Dusart 1999 page 14, for all n >= 2
  my $lower = $n * ($flogn + $flog2n - 1.0 + (($flog2n-2.25)/$flogn));

  if ( ($lower >= ~0) && (ref($lower) ne 'Math::BigFloat') ) {
    return $_Config{'maxprime'} if $n <= $_Config{'maxprimeidx'};
    croak "nth_prime_lower($n) overflow";
  }

  return int($lower);
}

# The nth prime will be less or equal to this number
sub nth_prime_upper {
  my($n) = @_;
  _validate_positive_integer($n);

  return $_primes_small[$n] if $n <= $#_primes_small;

  $n = _upgrade_to_float($n) if ref($n) eq 'Math::BigInt';

  my $flogn  = log($n);
  my $flog2n = log($flogn);  # Note distinction between log_2(n) and log^2(n)

  my $upper;
  if ($n >= 39017) {        # Dusart 1999 page 14
    $upper = $n * ( $flogn  +  $flog2n - 0.9484 );
  } elsif ($n >= 27076) {   # Dusart 1999 page 14
    $upper = $n * ( $flogn  +  $flog2n - 1.0 + (($flog2n-1.80)/$flogn) );
  } elsif ($n >= 7022) {    # Robin 1983
    $upper = $n * ( $flogn  +  0.9385 * $flog2n );
  } else {
    $upper = $n * ( $flogn  +  $flog2n );
  }

  if ( ($upper >= ~0) && (ref($upper) ne 'Math::BigFloat') ) {
    return $_Config{'maxprime'} if $n <= $_Config{'maxprimeidx'};
    croak "nth_prime_upper($n) overflow";
  }

  return int($upper + 1.0);
}


#############################################################################


#############################################################################

sub RiemannR {
  my($n) = @_;
  croak("Invalid input to ReimannR:  x must be > 0") if $n <= 0;

  return Math::Prime::Util::PP::RiemannR($n, 1e-30) if defined $bignum::VERSION || ref($n) eq 'Math::BigFloat';
  return Math::Prime::Util::PP::RiemannR($n) if !$_Config{'xs'};
  return _XS_RiemannR($n);

  # We could make a new object, like:
  #    require Math::BigFloat;
  #    my $bign = new Math::BigFloat "$n";
  #    my $result = Math::Prime::Util::PP::RiemannR($bign);
  #    return $result;
}

sub ExponentialIntegral {
  my($n) = @_;
  croak "Invalid input to ExponentialIntegral:  x must be != 0" if $n == 0;

  return Math::Prime::Util::PP::ExponentialIntegral($n, 1e-30) if defined $bignum::VERSION || ref($n) eq 'Math::BigFloat';
  return Math::Prime::Util::PP::ExponentialIntegral($n) if !$_Config{'xs'};
  return _XS_ExponentialIntegral($n);
}

sub LogarithmicIntegral {
  my($n) = @_;
  return 0 if $n == 0;
  croak("Invalid input to LogarithmicIntegral:  x must be >= 0") if $n <= 0;

  if ( defined $bignum::VERSION || ref($n) eq 'Math::BigFloat' ) {
    return Math::BigFloat->binf('-') if $n == 1;
    return Math::BigFloat->new('1.045163780117492784844588889194613136522615578151201575832909144075013205210359530172717405626383356306') if $n == 2;
  } else {
    return 0+'-inf' if $n == 1;
    return 1.045163780117492784844588889194613136522615578151 if $n == 2;
  }
  ExponentialIntegral(log($n));
}

#############################################################################

use Math::Prime::Util::MemFree;

1;

__END__


# ABSTRACT: Utilities related to prime numbers, including fast generators / sievers

=pod

=encoding utf8


=head1 NAME

Math::Prime::Util - Utilities related to prime numbers, including fast sieves and factoring


=head1 VERSION

Version 0.10


=head1 SYNOPSIS

  # Normally you would just import the functions you are using.
  # Nothing is exported by default.
  use Math::Prime::Util ':all';


  # Get a big array reference of many primes
  my $aref = primes( 100_000_000 );

  # All the primes between 5k and 10k inclusive
  my $aref = primes( 5_000, 10_000 );

  # If you want them in an array instead
  my @primes = @{primes( 500 )};


  # is_prime returns 0 for composite, 2 for prime
  say "$n is prime"  if is_prime($n);

  # is_prob_prime returns 0 for composite, 2 for prime, and 1 for maybe prime
  say "$n is ", qw(composite maybe_prime? prime)[is_prob_prime($n)];


  # step to the next prime (returns 0 if the next one is more than ~0)
  $n = next_prime($n);

  # step back (returns 0 if given input less than 2)
  $n = prev_prime($n);


  # Return Pi(n) -- the number of primes E<lt>= n.
  $primepi = prime_count( 1_000_000 );
  $primepi = prime_count( 10**14, 10**14+1000 );  # also does ranges

  # Quickly return an approximation to Pi(n)
  my $approx_number_of_primes = prime_count_approx( 10**17 );

  # Lower and upper bounds.  lower <= Pi(n) <= upper for all n
  die unless prime_count_lower($n) <= prime_count($n);
  die unless prime_count_upper($n) >= prime_count($n);


  # Return p_n, the nth prime
  say "The ten thousandth prime is ", nth_prime(10_000);

  # Return a quick approximation to the nth prime
  say "The one trillionth prime is ~ ", nth_prime_approx(10**12);

  # Lower and upper bounds.   lower <= nth_prime(n) <= upper for all n
  die unless nth_prime_lower($n) <= nth_prime($n);
  die unless nth_prime_upper($n) >= nth_prime($n);


  # Get the prime factors of a number
  @prime_factors = factor( $n );


  # Precalculate a sieve, possibly speeding up later work.
  prime_precalc( 1_000_000_000 );

  # Free any memory used by the module.
  prime_memfree;

  # Alternate way to free.  When this leaves scope, memory is freed.
  my $mf = Math::Prime::Util::MemFree->new;


  # Random primes
  my $small_prime = random_prime(1000);      # random prime <= limit
  my $rand_prime = random_prime(100, 10000); # random prime within a range
  my $rand_prime = random_ndigit_prime(6);   # random 6-digit prime
  my $rand_prime = random_nbit_prime(128);   # random 128-bit prime
  my $rand_prime = random_maurer_prime(256); # random 256-bit prime

  # Euler phi on large number
  use bigint;  say euler_phi( 801294088771394680000412 );
  # returns 391329671260448564651280


=head1 DESCRIPTION

A set of utilities related to prime numbers.  These include multiple sieving
methods, is_prime, prime_count, nth_prime, approximations and bounds for
the prime_count and nth prime, next_prime and prev_prime, factoring utilities,
and more.

The default sieving and factoring are intended to be (and currently are)
the fastest on CPAN, including L<Math::Prime::XS>, L<Math::Prime::FastSieve>,
L<Math::Factor::XS>, and L<Math::Prime::TiedArray>.  For numbers in the 10-20
digit range, it is often orders of magnitude faster.  Typically it is faster
than L<Math::Pari> for 64-bit operations, with the exception of factoring
certain 16-20 digit numbers.

The main development of the module has been for working with Perl UVs, so
32-bit or 64-bit.  Bignum support is limited.  On advantage is that it requires
no external software (e.g. GMP or Pari).  If you need full bignum support for
these types of functions inside Perl now, I recommend L<Math::Pari>.
While this module contains all the functionality of L<Math::Primality> and is
much faster on 64-bit input, L<Math::Primality> is much faster than we are
for bigints.  This is being addressed.

The module is thread-safe and allows concurrency between Perl threads while
still sharing a prime cache.  It is not itself multithreaded.  See the
L<Limitations|/"LIMITATIONS"> section if you are using Win32 and threads in
your program.


=head1 BIGNUM SUPPORT

By default all functions support bigints.  Performance on bigints is not very
good however, as currently it is all using the core bigint / bignum routines.
Some of these performance concerns will be addressed in later versions, and
should all be hidden.

Some of the functions, notably:

  factor
  is_prime
  next_prime
  prev_prime
  prime_count
  nth_prime
  is_strong_pseudoprime

work very fast (under 1 microsecond) on small inputs, but the wrappers to do
input validation and bigint support take more time than the function itself.
Using the flag:

  use Math::Prime::Util qw(-bigint);

will turn off bigint support for those functions.  Those functions will then
go directly to the XS versions, which will speed up very small inputs a B<lot>.

Having run these functions on many versions of Perl, if you're using anything
older than Perl 5.14, I would recommend you upgrade if you want bigint support.
There are a lot of brittle behaviors on 5.12.4 and earlier.



=head1 FUNCTIONS

=head2 is_prime

  print "$n is prime" if is_prime($n);

Returns 2 if the number is prime, 0 if not.  Also note there are
probabilistic prime testing functions available.


=head2 primes

Returns all the primes between the lower and upper limits (inclusive), with
a lower limit of C<2> if none is given.

An array reference is returned (with large lists this is much faster and uses
less memory than returning an array directly).

  my $aref1 = primes( 1_000_000 );
  my $aref2 = primes( 1_000_000_000_000, 1_000_000_001_000 );

  my @primes = @{ primes( 500 ) };

  print "$_\n" for (@{primes( 20, 100 )});

Sieving will be done if required.  The algorithm used will depend on the range
and whether a sieve result already exists.  Possibilities include trial
division (for ranges with only one expected prime), a Sieve of Eratosthenes
using wheel factorization, or a segmented sieve.


=head2 next_prime

  $n = next_prime($n);

Returns the next prime greater than the input number.  0 is returned if the
next prime is larger than a native integer type (the last representable
primes being C<4,294,967,291> in 32-bit Perl and
C<18,446,744,073,709,551,557> in 64-bit).


=head2 prev_prime

  $n = prev_prime($n);

Returns the prime smaller than the input number.  0 is returned if the
input is C<2> or lower.


=head2 prime_count

  my $primepi = prime_count( 1_000 );
  my $pirange = prime_count( 1_000, 10_000 );

Returns the Prime Count function C<Pi(n)>, also called C<primepi> in some
math packages.  When given two arguments, it returns the inclusive
count of primes between the ranges (e.g. C<(13,17)> returns 2, C<14,17>
and C<13,16> return 1, and C<14,16> returns 0).

The current implementation relies on sieving to find the primes within the
interval, so will take some time and memory.  It uses a segmented sieve so
is very memory efficient, and also allows fast results even with large
base values.  The complexity for C<prime_count(a, b)> is approximately
C<O(sqrt(a) + (b-a))>, where the first term is typically negligible below
C<~ 10^11>.  Memory use is proportional only to C<sqrt(a)>, with total
memory use under 1MB for any base under C<10^14>.

A later implementation may work on improving performance for values, both
in reducing memory use (the current maximum is 140MB at C<2^64>) and improving
speed.  Possibilities include a hybrid table approach, using an explicit
formula with C<li(x)> or C<R(x)>, or one of the Meissel, Lehmer,
or Lagarias-Miller-Odlyzko-Deleglise-Rivat methods.


=head2 prime_count_upper

=head2 prime_count_lower

  my $lower_limit = prime_count_lower($n);
  die unless prime_count($n) >= $lower_limit;

  my $upper_limit = prime_count_upper($n);
  die unless prime_count($n) <= $upper_limit;

Returns an upper or lower bound on the number of primes below the input number.
These are analytical routines, so will take a fixed amount of time and no
memory.  The actual C<prime_count> will always be on or between these numbers.

A common place these would be used is sizing an array to hold the first C<$n>
primes.  It may be desirable to use a bit more memory than is necessary, to
avoid calling C<prime_count>.

These routines use hand-verified tight limits below a range at least C<2^35>,
and fall back to the Dusart bounds of

    x/logx * (1 + 1/logx + 1.80/log^2x) <= Pi(x)

    x/logx * (1 + 1/logx + 2.51/log^2x) >= Pi(x)

above that range.


=head2 prime_count_approx

  print "there are about ",
        prime_count_approx( 10 ** 18 ),
        " primes below one quintillion.\n";

Returns an approximation to the C<prime_count> function, without having to
generate any primes.  The current implementation uses the Riemann R function
which is quite accurate: an error of less than C<0.0005%> is typical for
input values over C<2^32>.  A slightly faster (0.1ms vs. 1ms), but much less
accurate, answer can be obtained by averaging the upper and lower bounds.


=head2 nth_prime

  say "The ten thousandth prime is ", nth_prime(10_000);

Returns the prime that lies in index C<n> in the array of prime numbers.  Put
another way, this returns the smallest C<p> such that C<Pi(p) E<gt>= n>.

This relies on generating primes, so can require a lot of time and space for
large inputs.  A segmented sieve is used for large inputs, so it is memory
efficient.  On my machine it will return the 203,280,221st prime (the largest
that fits in 32-bits) in 2.5 seconds.  The 10^9th prime takes 15 seconds to
find, while the 10^10th prime takes nearly four minutes.


=head2 nth_prime_upper

=head2 nth_prime_lower

  my $lower_limit = nth_prime_lower($n);
  die unless nth_prime($n) >= $lower_limit;

  my $upper_limit = nth_prime_upper($n);
  die unless nth_prime($n) <= $upper_limit;

Returns an analytical upper or lower bound on the Nth prime.  This will be
very fast.  The lower limit uses the Dusart 1999 bounds for all C<n>, while
the upper bound uses one of the two Dusart 1999 bounds for C<n E<gt>= 27076>,
the Robin 1983 bound for C<n E<gt>= 7022>, and the simple bound of
C<n * (logn + loglogn)> for C<n E<lt> 7022>.


=head2 nth_prime_approx

  say "The one trillionth prime is ~ ", nth_prime_approx(10**12);

Returns an approximation to the C<nth_prime> function, without having to
generate any primes.  Uses the Cipolla 1902 approximation with two
polynomials, plus a correction term for small values to reduce the error.


=head2 is_strong_pseudoprime

  my $maybe_prime = is_strong_pseudoprime($n, 2);
  my $probably_prime = is_strong_pseudoprime($n, 2, 3, 5, 7, 11, 13, 17);

Takes a positive number as input and one or more bases.  The bases must be
between C<2> and C<n - 2>.  Returns 1 is C<n> is a prime or a strong
pseudoprime to all of the bases, and 0 if not.

If 0 is returned, then the number really is a composite.  If 1 is returned,
then it is either a prime or a strong pseudoprime to all the given bases.
Given enough distinct bases, the chances become very, very strong that the
number is actually prime.

This is usually used in combination with other tests to make either stronger
tests (e.g. the strong BPSW test) or deterministic results for numbers less
than some verified limit (e.g. it has long been known that no more than three
selected bases are required to give correct primality test results for any
32-bit number).  Given the small chances of passing multiple bases, there
are some math packages that just use multiple MR tests for primality testing.

Even numbers other than 2 will always return 0 (composite).  While the
algorithm does run with even input, most sources define it only on odd input.
Returning composite for all non-2 even input makes the function match most
other implementations including L<Math::Primality>'s C<is_strong_pseudoprime>
function.

=head2 miller_rabin

An alias for C<is_strong_pseudoprime>.  This name is being deprecated.


=head2 is_strong_lucas_pseudoprime

Takes a positive number as input, and returns 1 if the input is a strong
Lucas pseudoprime using the Selfridge method of choosing D, P, and Q (some
sources call this a strong Lucas-Selfridge pseudoprime).  This is one half
of the BPSW primality test (the Miller-Rabin strong pseudoprime test with
base 2 being the other half).


=head2 is_prob_prime

  my $prob_prime = is_prob_prime($n);
  # Returns 0 (composite), 2 (prime), or 1 (probably prime)

Takes a positive number as input and returns back either 0 (composite),
2 (definitely prime), or 1 (probably prime).

For 64-bit input (native or bignum), this uses a tuned set of Miller-Rabin
tests such that the result will be deterministic.  Either 2, 3, 4, 5, or 7
Miller-Rabin tests are performed (no more than 3 for 32-bit input), and the
result will then always be 0 (composite) or 2 (prime).  A later implementation
may change the internals, but the results will be identical.

For inputs larger than C<2^64>, a strong Baillie-PSW primality test is
performed (aka BPSW or BSW).  This is a probabilistic test, so the only times
a 2 (definitely prime) are returned are when the small trial division succeeds.
Note that since the test was published in 1980, not a single BPSW pseudoprime
has been found, so it is extremely likely to be prime.  While we know there
an infinite number of counterexamples exist, there is a weak conjecture that
none exist under 10000 digits.


=head2 random_prime

  my $small_prime = random_prime(1000);      # random prime <= limit
  my $rand_prime = random_prime(100, 10000); # random prime within a range

Returns a psuedo-randomly selected prime that will be greater than or equal
to the lower limit and less than or equal to the upper limit.  If no lower
limit is given, 2 is implied.  Returns undef if no primes exist within the
range.  The L<rand> function is called one or more times for selection.

The goal is to return a uniform distribution of the primes in the range,
meaning for each prime in the range, the chances are equally likely that it
will be seen.

The current algorithm does a random index selection for small numbers, which
is deterministic.  For larger numbers, this slows down, so for 32-bit ranges,
the obvious Monte Carlo method is used, where random numbers in the range are
selected until one is prime.  For even larger ranges, a method similar to that
of Fouque and Tibouchi (2011) algorithm A1 is used.


Perl's L<rand> function is normally called, but if the sub C<main::rand>
exists, it will be used instead.  When called with no arguments it should
return a float value between 0 and 1-epsilon, with 31 bits of randomness.
Examples:

  # Use Mersenne Twister
  use Math::Random::MT::Auto qw/rand/;

  # Use a custom random function
  sub rand { ... }

If you want cryptographically secure primes, I suggest looking at
L<Crypt::Primes> for now.  At minimum you should use a better source of
random numbers, such as L<Crypt::Random>.


=head2 random_ndigit_prime

  say "My 4-digit prime number is: ", random_ndigit_prime(4);

Selects a random n-digit prime, where the input is an integer number of
digits between 1 and the maximum native type (10 for 32-bit, 20 for 64-bit,
10000 if bigint is active).  One of the primes within that range
(e.g. 1000 - 9999 for 4-digits) will be uniformly selected using the
L<rand> function as described above.


=head2 random_nbit_prime

  use bigint;  my $bigprime = random_nbit_prime(512);

Selects a random n-bit prime, where the input is an integer number of bits
between 2 and the maximum representable bits (32, 64, or 100000 for native
32-bit, native 64-bit, and bigint respectively).  A prime with the nth bit
set will be uniformly selected, with randomness supplied via calls to the
L<rand> function as described above.

This the trivial algorithm to select primes from a range.  This gives a uniform
distribution, however it is quite slow for bigints, where the C<is_prime>
function is a limiter.

The differences between this function and what is used by L<Crypt::Primes>
include: (1) this function generates probable primes (albeit using BPSW) while
the latter is provable primes; (2) this function is really fast for native
bit sizes, but ridiculously slow in its current implementation when run on
very large numbers of bits -- L<Crypt::Primes> is quite fast for large bits;
(3) this function requires no external libraries while the latter requires
L<Math::Pari>; (4) the latter has some useful options for cryptography.


=head2 moebius

  say "$n is square free" if moebius($n) != 0;
  $sum += moebius($_) for (1..200); say "Mertens(200) = $sum";

Returns the Möbius function (also called the Moebius, Mobius, or MoebiusMu
function) for a positive non-zero integer input.  This function is 1 if
C<n = 1>, 0 if C<n> is not square free (i.e. C<n> has a repeated factor),
and C<-1^t> if C<n> is a product of C<t> distinct primes.  This is an
important function in prime number theory.


=head2 euler_phi

  say "The Euler totient of $n is ", euler_phi($n);

Returns the Euler totient function (also called Euler's phi or phi function)
for an integer value.  This is an arithmetic function that counts the number
of positive integers less than or equal to C<n> that are relatively prime to
C<n>.  Given the definition used, C<euler_phi> will return 0 for all
C<n E<lt> 1>.  This follows the logic used by SAGE.  Mathematic/WolframAlpha
also returns 0 for input 0, but returns C<euler_phi(-n)> for C<n E<lt> 0>.




=head1 UTILITY FUNCTIONS

=head2 prime_precalc

  prime_precalc( 1_000_000_000 );

Let the module prepare for fast operation up to a specific number.  It is not
necessary to call this, but it gives you more control over when memory is
allocated and gives faster results for multiple calls in some cases.  In the
current implementation this will calculate a sieve for all numbers up to the
specified number.


=head2 prime_memfree

  prime_memfree;

Frees any extra memory the module may have allocated.  Like with
C<prime_precalc>, it is not necessary to call this, but if you're done
making calls, or want things cleanup up, you can use this.  The object method
might be a better choice for complicated uses.

=head2 Math::Prime::Util::MemFree->new

  my $mf = Math::Prime::Util::MemFree->new;
  # perform operations.  When $mf goes out of scope, memory will be recovered.

This is a more robust way of making sure any cached memory is freed, as it
will be handled by the last C<MemFree> object leaving scope.  This means if
your routines were inside an eval that died, things will still get cleaned up.
If you call another function that uses a MemFree object, the cache will stay
in place because you still have an object.

=head2 prime_get_config

  my $cached_up_to = prime_get_config->{'precalc_to'};

Returns a reference to a hash of the current settings.  The hash is copy of
the configuration, so changing it has no effect.  The settings include:

  precalc_to      primes up to this number are calculated
  maxbits         the maximum number of bits for native operations
  xs              0 or 1, indicating the XS code is running
  gmp             0 or 1, indicating GMP code is available
  maxparam        the largest value for most functions, without bigint
  maxdigits       the max digits in a number, without bigint
  maxprime        the largest representable prime, without bigint
  maxprimeidx     the index of maxprime, without bigint
  


=head1 FACTORING FUNCTIONS

=head2 factor

  my @factors = factor(3_369_738_766_071_892_021);
  # returns (204518747,16476429743)

Produces the prime factors of a positive number input, in numerical order.
The special cases of C<n = 0> and C<n = 1> will return C<n>, which
guarantees multiplying the factors together will always result in the
input value, though those are the only cases where the returned factors
are not prime.

The current algorithm is to use trial division for small numbers, while large
numbers go through a sequence of small trials, SQUFOF, Pollard's Rho, Hart's
one line factorization, and finally trial division for any survivors.  This
process is repeated for each non-prime factor.

While factoring works on bigints, the algorithms are currently set up for
smaller numbers, and bignum support is all in pure Perl.  Hence, it will be
somewhat slow for "easy" numbers and very, very slow for "hard" numbers.


=head2 all_factors

  my @divisors = all_factors(30);   # returns (2, 3, 5, 6, 10, 15)

Produces all the divisors of a positive number input.  1 and the input number
are excluded (which implies that an empty list is returned for any prime
number input).  The divisors are a power set of multiplications of the prime
factors, returned as a uniqued sorted list.


=head2 trial_factor

  my @factors = trial_factor($n);

Produces the prime factors of a positive number input.  The factors will be
in numerical order.  The special cases of C<n = 0> and C<n = 1> will return
C<n>, while with all other inputs the factors are guaranteed to be prime.
For large inputs this will be very slow.

=head2 fermat_factor

  my @factors = fermat_factor($n);

Produces factors, not necessarily prime, of the positive number input.  The
particular algorithm is Knuth's algorithm C.  For small inputs this will be
very fast, but it slows down quite rapidly as the number of digits increases.
It is very fast for inputs with a factor close to the midpoint
(e.g. a semiprime p*q where p and q are the same number of digits).

=head2 holf_factor

  my @factors = holf_factor($n);

Produces factors, not necessarily prime, of the positive number input.  An
optional number of rounds can be given as a second parameter.  It is possible
the function will be unable to find a factor, in which case a single element,
the input, is returned.  This uses Hart's One Line Factorization with no
premultiplier.  It is an interesting alternative to Fermat's algorithm,
and there are some inputs it can rapidly factor.  In the long run it has the
same advantages and disadvantages as Fermat's method.

=head2 squfof_factor

  my @factors = squfof_factor($n);

Produces factors, not necessarily prime, of the positive number input.  An
optional number of rounds can be given as a second parameter.  It is possible
the function will be unable to find a factor, in which case a single element,
the input, is returned.  This function typically runs very fast.

=head2 prho_factor

=head2 pbrent_factor

=head2 pminus1_factor

  my @factors = prho_factor($n);

  # Use a very small number of rounds
  my @factors = prho_factor($n, 1000);

Produces factors, not necessarily prime, of the positive number input.  An
optional number of rounds can be given as a second parameter.  These attempt
to find a single factor using one of the probabilistic algorigthms of
Pollard Rho, Brent's modification of Pollard Rho, or Pollard's C<p - 1>.
These are more specialized algorithms usually used for pre-factoring very
large inputs, or checking very large inputs for naive mistakes.  If the
input is prime or they run out of rounds, they will return the single
input value.  On some inputs they will take a very long time, while on
others they succeed in a remarkably short time.



=head1 MATHEMATICAL FUNCTIONS

=head2 ExponentialIntegral

  my $Ei = ExponentialIntegral($x);

Given a non-zero floating point input C<x>, this returns the real-valued
exponential integral of C<x>, defined as the integral of C<e^t/t dt>
from C<-infinity> to C<x>.
Depending on the input, the integral is calculated using
continued fractions (C<x E<lt> -1>),
rational Chebyshev approximation (C< -1 E<lt> x E<lt> 0>),
a convergent series (small positive C<x>),
or an asymptotic divergent series (large positive C<x>).

Accuracy should be at least 14 digits.


=head2 LogarithmicIntegral

  my $li = LogarithmicIntegral($x)

Given a positive floating point input, returns the floating point logarithmic
integral of C<x>, defined as the integral of C<dt/ln t> from C<0> to C<x>.
If given a negative input, the function will croak.  The function returns
0 at C<x = 0>, and C<-infinity> at C<x = 1>.

This is often known as C<li(x)>.  A related function is the offset logarithmic
integral, sometimes known as C<Li(x)> which avoids the singularity at 1.  It
may be defined as C<Li(x) = li(x) - li(2)>.

This function is implemented as C<li(x) = Ei(ln x)> after handling special
values.

Accuracy should be at least 14 digits.


=head2 RiemannR

  my $r = RiemannR($x);

Given a positive non-zero floating point input, returns the floating
point value of Riemann's R function.  Riemann's R function gives a very close
approximation to the prime counting function.

Accuracy should be at least 14 digits.


=head1 EXAMPLES

Print pseudoprimes base 17:

    perl -MMath::Prime::Util=:all -E 'my $n=$base|1; while(1) { print "$n " if is_strong_pseudoprime($n,$base) && !is_prime($n); $n+=2; } BEGIN {$|=1; $base=17}'

Print some primes above 64-bit range:

    perl -MMath::Prime::Util=:all -Mbigint -E 'my $start=100000000000000000000; say join "\n", @{primes($start,$start+1000)}'
    # Similar but much faster:
    # perl -MMath::Pari=:int,PARI,nextprime -E 'my $start = PARI "100000000000000000000"; my $end = $start+1000; my $p=nextprime($start); while ($p <= $end) { say $p; $p = nextprime($p+1); }'

=head1 LIMITATIONS

I have not completed testing all the functions near the word size limit
(e.g. C<2^32> for 32-bit machines).  Please report any problems you find.

Perl versions earlier than 5.8.0 have issues with 64-bit that show up in the
factoring tests.  The test suite will try to determine if your Perl is broken.
If you use later versions of Perl, or Perl 5.6.2 32-bit, or Perl 5.6.2 64-bit
and keep numbers below C<~ 2^52>, then everything works.  The best solution is
to update to a more recent Perl.

The module is thread-safe and should allow good concurrency on all platforms
that support Perl threads except Win32 (Cygwin works).  With Win32, either
don't use threads or make sure C<prime_precalc> is called before using
C<primes>, C<prime_count>, or C<nth_prime> with large inputs.  This is B<only>
an issue if you use non-Cygwin Win32 and call these routines from within
Perl threads.



=head1 PERFORMANCE

Counting the primes to C<10^10> (10 billion), with time in seconds.
Pi(10^10) = 455,052,511.

   External C programs in C / C++:

       1.9  primesieve 3.6 forced to use only a single thread
       2.2  yafu 1.31
       3.8  primegen (optimized Sieve of Atkin, conf-word 8192)
       5.6  Tomás Oliveira e Silva's unoptimized segmented sieve v2 (Sep 2010)
       6.7  Achim Flammenkamp's prime_sieve (32k segments)
       9.3  http://tverniquet.com/prime/ (mod 2310, single thread)
      11.2  Tomás Oliveira e Silva's unoptimized segmented sieve v1 (May 2003)
      17.0  Pari 2.3.5 (primepi)

   Small portable functions suitable for plugging into XS:

       5.3  My segmented SoE used in this module
      15.6  My Sieve of Eratosthenes using a mod-30 wheel
      17.2  A slightly modified verion of Terje Mathisen's mod-30 sieve
      35.5  Basic Sieve of Eratosthenes on odd numbers
      33.4  Sieve of Atkin, from Praxis (not correct)
      72.8  Sieve of Atkin, 10-minute fixup of basic algorithm
      91.6  Sieve of Atkin, Wikipedia-like

Perl modules, counting the primes to C<800_000_000> (800 million), in seconds:

  Time (s)   Module                      Version  Notes
  ---------  --------------------------  -------  -----------
       0.36  Math::Prime::Util           0.09     segmented mod-30 sieve
       0.9   Math::Prime::Util           0.01     mod-30 sieve
       2.9   Math::Prime::FastSieve      0.12     decent odd-number sieve
      11.7   Math::Prime::XS             0.29     "" but needs a count API
      15.0   Bit::Vector                 7.2
      59.1   Math::Prime::Util::PP       0.09     Perl
     170.0   Faster Perl sieve (net)     2012-01  array of odds
     548.1   RosettaCode sieve (net)     2012-06  simplistic Perl
   >5000     Math::Primality             0.04     Perl + GMP



C<is_prime>: my impressions:

   Module                    Small inputs   Large inputs (10-20dig)
   -----------------------   -------------  ----------------------
   Math::Prime::Util         Very fast      Pretty fast
   Math::Prime::XS           Very fast      Very, very slow if no small factors
   Math::Pari                Slow           OK
   Math::Prime::FastSieve    Very fast      N/A (too much memory)
   Math::Primality           Very slow      Very slow

The differences are in the implementations:

   - L<Math::Prime::FastSieve> only works in a sieved range, which is really
     fast if you can do it (M::P::U will do the same if you call
     C<prime_precalc>).  Larger inputs just need too much time and memory
     for the sieve.

   - L<Math::Primality> uses GMP for all work.  Under ~32-bits it uses 2 or 3
     MR tests, while above 4759123141 it performs a BPSW test.  This is is
     fantastic for bigints over 2^64, but it is significantly slower than
     native precision tests.  With 64-bit numbers it is generally an order of
     magnitude or more slower than any of the others.  This reverses when
     numbers get larger.

   - L<Math::Pari> has some very effective code, but it has some overhead to get
     to it from Perl.  That means for small numbers it is relatively slow: an
     order of magnitude slower than M::P::XS and M::P::Util (though arguably
     this is only important for benchmarking since "slow" is ~2 microseconds).
     Large numbers transition over to smarter tests so don't slow down much.

   - L<Math::Prime::XS> does trial divisions, which is wonderful if the input
     has a small factor (or is small itself).  But it can take 1000x longer
     if given a large prime.

   - L<Math::Prime::Util> looks in the sieve for a fast bit lookup if that
     exists (default up to 30,000 but it can be expanded, e.g.
     C<prime_precalc>), uses trial division for numbers higher than this but
     not too large (0.1M on 64-bit machines, 100M on 32-bit machines), a
     deterministic set of Miller-Rabin tests for 64-bit and smaller numbers,
     and a BPSW test for bigints.



Factoring performance depends on the input, and the algorithm choices used
are still being tuned.  Compared to Math::Factor::XS, it is a tiny bit faster
for most input under 10M or so, and rapidly gets faster.  For numbers
larger than 32 bits it's 10-100x faster (depending on the number -- a power
of two will be identical, while a semiprime with large factors will be on
the extreme end).  Pari's underlying algorithms and code are very
sophisticated, and will always be more so than this module, and of course
supports bignums which is a huge advantage.  Small numbers factor much, much
faster with Math::Prime::Util.  Pari passes M::P::U in speed somewhere in the
16 digit range and rapidly increases its lead.  For bignums, there is no
question that Math::Pari is far superior at this point.

The presentation here:
 L<http://math.boisestate.edu/~liljanab/BOISECRYPTFall09/Jacobsen.pdf>
has a lot of data on 64-bit and GMP factoring performance I collected in 2009.
Assuming you do not know anything about the inputs, trial division and
optimized Fermat work very well for small numbers (<= 10 digits), while
native SQUFOF is typically the method of choice for 11-18 digits (I've
seen claims that a lightweight QS can be faster for 15+ digits).  Some form
of Quadratic Sieve is usually used for inputs in the 19-100 digit range, and
beyond that is the Generalized Number Field Sieve.  For serious factoring,
I recommend looking info C<yafu>, C<msieve>, C<Pari>, and C<GGNFS>.



=head1 AUTHORS

Dana Jacobsen E<lt>dana@acm.orgE<gt>


=head1 ACKNOWLEDGEMENTS

Eratosthenes of Cyrene provided the elegant and simple algorithm for finding
the primes.

Terje Mathisen, A.R. Quesada, and B. Van Pelt all had useful ideas which I
used in my wheel sieve.

Tomás Oliveira e Silva has released the source for a very fast segmented sieve.
The current implementation does not use these ideas, but future versions likely
will.

The SQUFOF implementation being used is my modifications to Ben Buhrow's
modifications to Bob Silverman's code.  I may experiment with some other
implementations (Ben Buhrows and Jason Papadopoulos both have published
excellent versions in the public domain).



=head1 COPYRIGHT

Copyright 2011-2012 by Dana Jacobsen E<lt>dana@acm.orgE<gt>

This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
