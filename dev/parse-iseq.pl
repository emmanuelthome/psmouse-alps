#!/usr/bin/perl -w

use warnings;
use strict;

select(STDOUT); $|=1;

my $lexikon = {
    e6 => ["SETSCALE11", 0, 0, ],
    e7 => ["SETSCALE21", 0, 0, ],
    e8 => ["SETRES"    , 1, 0, ],
    e9 => ["GETINFO"   , 0, 3, ],
    ea => ["SETSTREAM" , 0, 0, ],
    f0 => ["SETPOLL"   , 0, 0, ],
    eb => ["POLL"      , 0, 0, ], # caller sets number of bytes to receive
    ec => ["RESET_WRAP", 0, 0, ],
    # f2 => ["GETID"     , 0, 2, ],
    f2 => ["CMD_NIBBLE_10"     , 0, 1, ],
    f3 => ["SETRATE"   , 1, 0, ],
    f4 => ["ENABLE"    , 0, 0, ],
    f5 => ["DISABLE"   , 0, 0, ],
    f6 => ["RESET_DIS" , 0, 0, ],
    ff => ["RESET_BAT" , 0, 2, ],
};

my $nibbles = {
       "SETPOLL()"           => '0',
       "RESET_DIS()"         => '1',
       "SETSCALE21()"        => '2',
       "SETRATE(0x0a)"       => '3',
       "SETRATE(0x14)"       => '4',
       "SETRATE(0x28)"       => '5',
       "SETRATE(0x3c)"       => '6',
       "SETRATE(0x50)"       => '7',
       "SETRATE(0x64)"       => '8',
       "SETRATE(0xc8)"       => '9',
       "CMD_NIBBLE_10()"     => 'a',
       "SETRES(0x00)"        => 'b',
       "SETRES(0x01)"        => 'c',
       "SETRES(0x02)"        => 'd',
       "SETRES(0x03)"        => 'e',
       "SETSCALE11()"        => 'f',
};


my $retcodes = {
         aa => "BAT",
         00 => "ID",
         fa => "ACK",
         fe => "NAK",
};

my @queue;

sub get {
    local $_;
    if (defined($_ = shift @queue)) {
        return $_;
    }
    while (1) {
        return unless defined($_=<>);
        chomp($_);
        return $_ unless /^$/ || /^#/;
    }
}

sub unget {
    unshift @queue, @_;
}

sub parse_data {
    my @packet;
    defined($_=get) or return 0; /^R (..)$/ or die; push @packet, "0x$1";
    defined($_=get) or die;      /^R (..)$/ or die; push @packet, "0x$1";
    defined($_=get) or die;      /^R (..)$/ or die; push @packet, "0x$1";
    defined($_=get) or die;      /^R (..)$/ or die; push @packet, "0x$1";
    defined($_=get) or die;      /^R (..)$/ or die; push @packet, "0x$1";
    defined($_=get) or die;      /^R (..)$/ or die; push @packet, "0x$1";
    return "GOT_DATA(" . join(" ", @packet) . ")";
}

sub parse_action {
    defined($_=get) or return 0;
    if (!/^S (..)$/) {
        unget $_;
        return parse_data @_;
    }
    my $a = $lexikon->{$1} or die "Unknown command $1";
    my ($name, $nsend, $nrecv)= @$a;
    my @args=();
    defined($_=get) or die "uh ?";
    if (!/^R fa/ && $name eq 'DISABLE') {
        # Apparently the windows drivers issues DISABLE and RESET_BAT
        # right after one another, and doesn't mind getting the two ACKs
        # afterwards.
        my $pop=$_;
        $_ = get;
        unget $pop;
    }
    /^R fa$/ or die "unexpected $_ at line $.";
    for(my $i = 0 ; $i < $nsend ; $i++) {
        defined($_=get) or die "uh ?";
        /^S (..)$/ or die "unexpected $_ at line $.";
        push @args, "0x$1";
        defined($_=get) or die "uh ?";
        /^R fa$/ or die "unexpected $_ at line $.";
    }
    my $command = $name;
    $command .= "(" . join(", ", @args) . ")";

    my @recv = ();
    for(my $i = 0 ; $i < $nrecv ; $i++) {
        defined($_=get) or die "uh ?";
        if ($name eq 'RESET_BAT' && /^S /) {
            my @normal = qw/aa 00/;
            my $next = get;
            print STDERR "Next is <$next>, comparing with <R $normal[$i]>\n";
            if ($next =~ /^R $normal[$i]/) {
                print STDERR "/* Swapping <$next> and <$_> in queue */\n";
                print STDERR "/* Putting back <$_> */\n";
                unget $_;
                $_ = $next;
            } else {
                my $miss = $nrecv - $i;
                push @recv, " missing $miss byte(s) (?!)";
                print STDERR "/* Undo lookahead <$next> */\n";
                unget $next;
                print STDERR "/* Putting back <$_> */\n";
                unget $_;
                last;
            }
        }
        /^R (..)$/ or die "unexpected $_ at line $. (cmd=$name, i=$i)";
        push @recv, "0x$1";
    }

    my $text=$command;
    if ($nrecv) {
        $text .= " /* I get " . join(", ", @recv) .  " */";
    }
    return $text;
}

# Commands are normally issued with device disabled (which avoids
# spurious data being fed in, I guess).
my $device_disabled = 1;

sub match_reset {
    my $a = shift;
    return unless $a->[0] =~ /^RESET_BAT/;
    return 1, "do_reset", shift @$a;
}

sub match_weird_nibble10 {
    my $a = shift;
    return unless $device_disabled;
    return unless $a->[0] =~ /^CMD_NIBBLE_10\(\)/;
    return 1, "weird_nibble10", shift @$a;
}

sub match_get_e6_report {
    my $a = shift;
    return unless $device_disabled;
    return unless
        scalar @$a >= 5 &&
        $a->[0] =~ /^SETRES\(0x00\)/ && 
        $a->[1] =~ /^SETSCALE11\(\)/ && 
        $a->[2] =~ /^SETSCALE11\(\)/ && 
        $a->[3] =~ /^SETSCALE11\(\)/ && 
        $a->[4] =~ /^GETINFO\(\)/;
    return 1, "get_e6_report", splice(@$a, 0, 5);
}

sub match_sortofsetmode {
    my $a = shift;
    return unless $device_disabled;
    my ($nh, $nl);
    return unless
        scalar @$a >= 5 &&
        $a->[0] =~ /^SETSCALE11\(\)/ && 
        $a->[1] =~ /^SETSCALE11\(\)/ && 
        $a->[2] =~ /^SETSCALE11\(\)/;
    $a->[3] =~ /^(\S+)/ or die;
    defined($nh = $nibbles->{$1}) or return;
    $a->[4] =~ /^(\S+)/ or die;
    defined($nl = $nibbles->{$1}) or return;
    return 1, "sortofsetmode(0x$nh$nl)", splice(@$a, 0, 5);
}

sub match_32bitcode {
    my $a = shift;
    return unless $device_disabled;
    return unless scalar @$a >= 8;
    my @nibbles;
    for(my $i = 0 ; $i < 8 ; $i++) {
        $a->[$i] =~ /^(\S+)/ or die;
        my $nibble = $nibbles->{$1};
        return unless defined $nibble;
        push @nibbles, $nibble;
    }
    my $command = "put_code(0x" . join("",@nibbles) . ")";
    return 1, $command, splice(@$a, 0, 8);
}

sub match_setrate {
    my $a = shift;
    return unless $device_disabled;
    return unless $a->[0] =~ /^SETRATE\((0x..)\)/;
    return 1, "setrate($1)", shift @$a;
}

sub match_setres {
    my $a = shift;
    return unless $device_disabled;
    return unless $a->[0] =~ /^SETRES\((0x..)\)/;
    return 1, "setres($1)", shift @$a;
}

sub match_enable {
    my $a = shift;
    return unless $device_disabled;
    return unless $a->[0] =~ /^ENABLE\(\)/;
    $device_disabled = 0;
    return 1, "enable", shift @$a;
}

sub match_disable {
    my $a = shift;
    # return if $device_disabled;
    return unless $a->[0] =~ /^DISABLE\(\)/;
    $device_disabled = 1;
    return 1, "disable", shift @$a;
}

sub match_setnormal {
    my $a = shift;
    return unless $device_disabled;
    return unless
        scalar @$a >= 3 &&
        $a->[0] =~ /^SETRATE\(0x64\)/ && 
        $a->[1] =~ /^SETRES\(0x03\)/ &&
        $a->[2] =~ /^ENABLE\(\)/;
    # we're matching against the ``enable()'' command, but don't shift
    # it out.
    return 1, "set_normal", splice(@$a, 0, 2);
}

sub match_setnormal2 {
    my $a = shift;
    return unless $device_disabled;
    return unless
        scalar @$a >= 2 &&
        $a->[0] =~ /^SETRATE\(0x64\)/ && 
        $a->[1] =~ /^ENABLE\(\)/;
    # we're matching against the ``enable()'' command, but don't shift
    # it out.
    return 1, "set_normal2", splice(@$a, 0, 1);
}

sub match_get_e7_report {
    my $a = shift;
    return unless $device_disabled;
    return unless
        scalar @$a >= 4 &&
        $a->[0] =~ /^SETSCALE21\(\)/ && 
        $a->[1] =~ /^SETSCALE21\(\)/ && 
        $a->[2] =~ /^SETSCALE21\(\)/ && 
        $a->[3] =~ /^GETINFO\(\)/;
    return 1, "get_e7_report", splice(@$a, 0, 4);
}

sub match_exit_command_mode {
    my $a = shift;
    return unless $device_disabled;
    return unless
        scalar @$a >= 1 &&
        $a->[0] =~ /^SETSTREAM\(\)/;
    return 1, "exit_command_mode", splice(@$a, 0, 1);
}

sub match_enter_command_mode {
    my $a = shift;
    return unless $device_disabled;
    return unless
        scalar @$a >= 4 &&
        $a->[0] =~ /^RESET_WRAP\(\)/ && 
        $a->[1] =~ /^RESET_WRAP\(\)/ && 
        $a->[2] =~ /^RESET_WRAP\(\)/ && 
        $a->[3] =~ /^GETINFO\(\)/;
    return 1, "enter_command_mode", splice(@$a, 0, 4);
}

sub match_readwriteregister {
    my $a = shift;
    return unless $device_disabled;
    return unless scalar @$a >= 8 && $a->[0] =~ /^RESET_WRAP\(\)/;
    my @nibbles;
    for(my $i = 0 ; $i < 4 ; $i++) {
        $a->[1+$i] =~ /^(\S+)/ or die;
        my $nibble = $nibbles->{$1};
        # my $x = $nibble; $x = '1undefined !' unless defined($x);
        # print STDERR "$1 -> $x\n";
        return unless defined $nibble;
        push @nibbles, $nibble;
    }
    my $register = join("", @nibbles);
    return unless $a->[5] =~ /^GETINFO\(\)/;
    @nibbles = ();
    for(my $i = 0 ; $i < 2 ; $i++) {
        $a->[6+$i] =~ /^(\S+)/ or die;
        my $nibble = $nibbles->{$1};
        return unless defined $nibble;
        push @nibbles, $nibble;
    }
    my $value = "0x" . join("", @nibbles);
    return 1, "read_and_set_register\($register, $value\)", splice(@$a, 0, 8);
}

# sub match_readwriteregister16 {
#     my $a = shift;
#     return unless $device_disabled;
#     return unless scalar @$a >= 10 && $a->[0] =~ /^RESET_WRAP\(\)/;
#     my @nibbles;
#     for(my $i = 0 ; $i < 4 ; $i++) {
#         $a->[1+$i] =~ /^(\S+)/ or die;
#         my $nibble = $nibbles->{$1};
#         # my $x = $nibble; $x = '2undefined !' unless defined($x);
#         # print STDERR "$1 -> $x\n";
#         return unless defined $nibble;
#         push @nibbles, $nibble;
#     }
#     my $register = join("", @nibbles);
#     return unless $a->[5] =~ /^GETINFO\(\)/;
#     @nibbles = ();
#     for(my $i = 0 ; $i < 4 ; $i++) {
#         $a->[6+$i] =~ /^(\S+)/ or die;
#         my $nibble = $nibbles->{$1};
#         # my $x = $nibble; $x = '3undefined !' unless defined($x);
#         # print STDERR "$1 -> $x\n";
#         return unless defined $nibble;
#         push @nibbles, $nibble;
#     }
#     my $value = "0x" . join("", @nibbles);
#     return 1, "read_and_set_register16\($register, $value\)", splice(@$a, 0, 10);
# }
 
sub match_readregister {
    my $a = shift;
    return unless $device_disabled;
    return unless scalar @$a >= 6 && $a->[0] =~ /^RESET_WRAP\(\)/;
    my @nibbles;
    for(my $i = 0 ; $i < 4 ; $i++) {
        $a->[1+$i] =~ /^(\S+)/ or die;
        my $nibble = $nibbles->{$1};
        return unless defined $nibble;
        push @nibbles, $nibble;
    }
    my $register = join("", @nibbles);
    return unless $a->[5] =~ /^GETINFO\(\)/;
    return 1, "read_register\($register\)", splice(@$a, 0, 6);
}

sub match_writeregister {
    my $a = shift;
    return unless $device_disabled;
    return unless scalar @$a >= 7 && $a->[0] =~ /^RESET_WRAP\(\)/;
    my @nibbles;
    for(my $i = 0 ; $i < 4 ; $i++) {
        $a->[1+$i] =~ /^(\S+)/ or die;
        my $nibble = $nibbles->{$1};
        return unless defined $nibble;
        push @nibbles, $nibble;
    }
    my $register = join("", @nibbles);
    @nibbles = ();
    for(my $i = 0 ; $i < 2 ; $i++) {
        $a->[5+$i] =~ /^(\S+)/ or die;
        my $nibble = $nibbles->{$1};
        return unless defined $nibble;
        push @nibbles, $nibble;
    }
    my $value = "0x" . join("", @nibbles);
    return 1, "set_register\($register, $value\)", splice(@$a, 0, 7);
}

sub match_data {
    my $a = shift;
    return if $device_disabled;
    my @packets;
    while (scalar @$a && $a->[0] =~ /^GOT_DATA/) {
        push @packets, shift @$a;
    }
    return unless scalar @packets;
    return 1, (scalar @packets . " data packets"), @packets;
}

# order is important !
my @parsers = (
    \&match_reset,
    \&match_weird_nibble10,
    \&match_get_e6_report,
    \&match_32bitcode,
    \&match_enable,
    \&match_disable,
    \&match_get_e7_report,
    \&match_sortofsetmode,
    \&match_exit_command_mode,
    \&match_enter_command_mode,
# \&match_readwriteregister16,
    \&match_readwriteregister,
    \&match_readregister,
    \&match_writeregister,
    \&match_setrate,
    \&match_setres,
    \&match_data,
);



my $inputformat = 0;
my $outputformat = 2;

sub usage {
    print STDERR <<EOF;
Usage: $0 [-if [0|1]] [-of [1|2]] < <capture data>
EOF
    exit 1;
}

while (defined($_ = shift @ARGV)) {
    if (/^-if$/) {
        defined($inputformat = shift @ARGV) or die;
        usage unless $inputformat =~ /^[01]$/;
        next;
    }
    if (/^-of$/) {
        defined($outputformat = shift @ARGV) or die;
        usage unless $outputformat =~ /^[12]$/;
        next;
    }
    usage;
}

# Create a level1 capture file.
my $capture = [];

if ($inputformat == 0) {
    while (1) {
        my $x = parse_action or last;
        if ($outputformat == 2) {
            push @$capture, $x;
        } else {
            print "$x\n";
        }
    }
} else {
    while (defined($_=<>)) {
        if ($outputformat == 2) {
            push @$capture, $_;
        } else {
            print "$_\n";
        }
    }
}

# Maybe stay with this level 1.
if ($outputformat == 1) {
    exit 0;
}

# Or go to level 2
PARSE: while (scalar @$capture) {
    my ($code, $command, @seq);

    for my $f (@parsers) {
        ($code, $command, @seq) = &$f($capture);
        do { print "$command\n"; next PARSE; } if $code;
    }
    print STDERR "Parse error: $capture->[0]\n";
    shift @$capture;
    # my $nleft = scalar @$capture;
    # die "$capture->[0] ($nleft left)?";
}
