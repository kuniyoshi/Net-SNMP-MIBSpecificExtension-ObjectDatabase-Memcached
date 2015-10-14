package Net::SNMP::MIBSpecificExtension::ObjectDatabase::Memcached;
use 5.8.8;
use strict;
use warnings;
use base "Net::SNMP::MIBSpecificExtension::ObjectDatabase";
use Socket qw( :DEFAULT );
use IO::Handle;

use constant INTEGER => "integer";
use constant STRING  => "string";
use constant COUNTER => "counter";
use constant GAUGE   => "gauge";

our $VERSION = "0.01";

my %DEFAULT = (
    TIME_TO_LIVE       => 2 * 60,
    CONNECTION_TIMEOUT => 10,
);
my %TYPE = (
    pid                   => INTEGER,
    uptime                => GAUGE,
    time                  => GAUGE,
    version               => STRING,
    pointer_size          => INTEGER,
    curr_items            => GAUGE,
    curr_connections      => GAUGE,
    connection_structures => GAUGE,
    limit_maxbytes        => INTEGER,
    threads               => INTEGER,
);
my %INDEX = (
    pid                   => 2,
    uptime                => 3,
    time                  => 4,
    version               => 5,
    pointer_size          => 6,
    rusage_user           => 7,
    rusage_system         => 8,
    curr_items            => 9,
    total_items           => 10,
    bytes                 => 11,
    curr_connections      => 12,
    total_connections     => 13,
    connection_structures => 14,
    cmd_flush             => 18,
    cmd_get               => 16,
    cmd_set               => 17,
    get_hits              => 20,
    get_misses            => 21,
    delete_misses         => 22,
    delete_hits           => 23,
    incr_misses           => 24,
    incr_hits             => 25,
    decr_misses           => 26,
    decr_hists            => 27,
    cas_misses            => 28,
    cas_hists             => 29,
    cas_badval            => 30,
    auth_cmds             => 33,
    auth_errors           => 34,
    evictions             => 35,
    bytes_read            => 37,
    bytes_written         => 38,
    limit_maxbytes        => 39,
    threads               => 40,
    conn_yields           => 41,
    reclaimed             => 36,
);
my %UNIT = (
    bytes          => "M",
    limit_maxbytes => "M",
    bytes_read     => "k",
    bytes_written  => "k",
);

sub time_to_live { shift->{time_to_live} }

sub connection_timeout { shift->{connection_timeout} }

sub add_processes {
    my $self = shift;
    chomp( my @pids = `pgrep -x memcached` );

    for my $pid ( @pids ) {
        open my $FH, "<", "/proc/$pid/cmdline"
            or die "Could not read cmdline of $pid: $!";
        chomp( my $line = <$FH> );
        close $FH
            or die "Could not close cmdline of $pid: $!";

        my @cmd_args = split m{\0}, $line;
        shift @cmd_args; # drop command name

        my %option;
        my $name;

        for my $arg ( @cmd_args ) {
            if ( $arg =~ m{\A [-] (\w) \z}msx ) {
                $name = $1;
            }
            elsif ( defined $name ) {
                $option{ $name } = $arg;
                undef $name;
            }
        }

        $option{l} ||= "127.0.0.1";
        $option{p} ||= 11211;

        push @{ $self->{processes} }, \%option;
    }

    return;
}

sub init {
    my $self = shift;

    $self->{time_to_live} = $DEFAULT{TIME_TO_LIVE}
        unless defined $self->{time_to_live};
    $self->{connection_timeout} = $DEFAULT{CONNECTION_TIMEOUT}
        unless defined $self->{connection_timeout};

    $self->{db} = { };
    $self->{processes} = [ ];

    $self->updated_at( 0 );

    $self->add_processes;

    return $self->SUPER::init;
}

sub updated_at {
    my $self = shift;
    if ( @_ ) {
        $self->{updated_at} = shift;
    }
    return $self->{updated_at};
}

sub does_update_needed {
    my $self = shift;
    my $now = time;

    return $now > $self->updated_at + $self->time_to_live;
}

sub read_stats {
    my $self        = shift;
    my $process_ref = shift;

    my $host = $process_ref->{l};
    my $port = $process_ref->{p};

    my $proto = getprotobyname( "tcp" );
    socket( my $SH, PF_INET, SOCK_STREAM, $proto )
        or die "Could not create socket of [$proto]: $!";
    my $sin = sockaddr_in( $port, inet_aton( $host ) );
    connect( $SH, $sin )
        or die "Could not connect to $host:$port: $!";

    $SH->autoflush( 1 );

    print { $SH } "stats\r\n";

    local $SIG{ALRM} = sub { die "received alarm\n" };
    alarm $self->connection_timeout;

    my %stats;

    eval {
        while ( <$SH> ) {
            ( my $line = $_ ) =~ s{ \r \n \z}{}msx;
            my( $indicator, $key, $value ) = split m{ }, $line, 3;

            last
                if $indicator eq "END";

            if ( $indicator eq "STAT" ) {
                $stats{ $key } = $value;
            }
        }
    };

    if ( my $e = $@ ) {
        die $e;
    }
    else {
        alarm 0;
    }

    close $SH
        or die "Could not close a socket of $host:$port: $!";

    for my $united_key ( keys %UNIT ) {
        next
            unless exists $stats{ $united_key };

        my $value = $stats{ $united_key };
        my $unit  = $UNIT{ $united_key };

        if ( $unit eq "M" ) {
            $value /= 1024 * 1024;
            $value = int $value;
            $stats{ $united_key } = $value;
        }
        elsif ( $unit eq "k" ) {
            $value /= 1024;
            $value = int $value;
            $stats{ $united_key } = $value;
        }
    }

    return %stats;
}

sub get_child_oid {
    my $self = shift;
    my $oid  = shift;
    return $self->base_oid . $oid;
}

sub update_database {
    my $self = shift;
    my $db_ref    = $self->db;
    my @processes = @{ $self->{processes} };

    $db_ref->{ $self->get_child_oid( ".1.1.0" ) } = {
        value => scalar( @processes ),
        type  => INTEGER,
    };

    for my $i ( 0 .. $#processes ) {
        my $process_ref = $processes[ $i ];
        my %stats = $self->read_stats( $process_ref );

        my $j = $i + 1;

        $db_ref->{ $self->get_child_oid( ".1.2.1.$j" ) } = {
            value => $j,
            type  => INTEGER,
        };

        for my $key ( keys %stats ) {
            my $index = $INDEX{ $key }
                or next;
            my $oid = $self->get_child_oid( ".1.2.$index.$j" );
            $db_ref->{ $oid } = {
                value => $stats{ $key },
                type  => $TYPE{ $key } || COUNTER,
            };
        }
    }

    $self->updated_at( time );

    return;
}

sub set_settings_to_db {
    my $self   = shift;
    my $db_ref = $self->db;
    my @processes = @{ $self->{processes} };

    for my $i ( 0 .. $#processes ) {
        my $proces_ref = $processes[ $i ];
        my $j = $i + 1;
        $db_ref->{ $self->get_child_oid( ".1.3.1.$j" ) } = {
            value => $j,
            type  => INTEGER,
        };
        $db_ref->{ $self->get_child_oid( ".1.3.4.$j" ) } = {
            value => $proces_ref->{p},
            type  => INTEGER,
        };
    }

    return;
}

sub get {
    my $self = shift;
    my $oid  = shift;

    if ( $self->does_update_needed ) {
        $self->update_database;
        $self->set_settings_to_db;
    }

    return $self->SUPER::get( $oid );
}

sub __sort_oid {
    my( $lh, $rh ) = @_;
    $lh =~ s{\A [.] }{}msx;
    $rh =~ s{\A [.] }{}msx;
    $lh = join q{-}, map { sprintf "%03d", $_ } split m{[.]}, $lh;
    $rh = join q{-}, map { sprintf "%03d", $_ } split m{[.]}, $rh;
    return $lh cmp $rh;
}

sub __uniq { # Can not `prereq` List::MoreUtils module, write sub myself :<
    my @list = @_;
    my %count;
    return grep { !$count{ $_ }++ } @list;
}

sub __get_first_index { # Can not `prereq` List::MoreUtils module, write sub myself :<
    my( $list_ref, $target ) = @_;
    for ( my $i = 0; $i < @{ $list_ref }; $i++ ) {
        if ( $list_ref->[ $i ] eq $target ) {
            return $i;
        }
    }
    return;
}

sub get_next_oid {
    my $self = shift;
    my $oid  = shift;

    my @oids = sort { __sort_oid( $a, $b ) } __uniq( $oid, keys %{ $self->db } );
    my $index = __get_first_index( \@oids, $oid );

    return
        if $index >= @oids;

    return $oids[ $index + 1 ];
}

sub getnext {
    my $self = shift;
    my $oid  = shift;

    if ( $self->does_update_needed ) {
        $self->update_database;
    }

    return $self->SUPER::getnext( $oid );
}

sub dump_db {
    my $self = shift;
    my $db_ref = $self->db;
    my @oids = sort { __sort_oid( $a, $b ) } keys %{ $db_ref };
    my @lines;

    for my $oid ( @oids ) {
        push @lines, sprintf "%s = %s: %s", $oid, $db_ref->{ $oid }{type}, $db_ref->{ $oid }{value};
    }

    return join "\n", @lines;
}

1;

__END__
--- 1.2.4
STAT pid 1855
STAT uptime 35865483
STAT time 1441957290
STAT version 1.2.4
STAT pointer_size 32
STAT rusage_user 2.820000
STAT rusage_system 8.830000
STAT curr_items 184640
STAT total_items 5943483
STAT bytes 49266976
STAT curr_connections 185
STAT total_connections 3751509
STAT connection_structures 566
STAT cmd_get 5943448
STAT cmd_set 5943483
STAT get_hits 3875247
STAT get_misses 2068201
STAT evictions 0
STAT bytes_read 1887659947
STAT bytes_written 926148174
STAT limit_maxbytes 1610612736
STAT threads 1
END

--- 1.4.6
STAT pid 12815
STAT uptime 154847
STAT time 1441948066
STAT version 1.4.6
STAT libevent 2.0.12-stable
STAT pointer_size 64
STAT rusage_user 1.528767
STAT rusage_system 6.349034
STAT curr_connections 5
STAT total_connections 8
STAT connection_structures 6
STAT cmd_get 8
STAT cmd_set 8
STAT cmd_flush 0
STAT get_hits 8
STAT get_misses 0
STAT delete_misses 0
STAT delete_hits 0
STAT incr_misses 0
STAT incr_hits 0
STAT decr_misses 0
STAT decr_hits 0
STAT cas_misses 0
STAT cas_hits 0
STAT cas_badval 0
STAT auth_cmds 0
STAT auth_errors 0
STAT bytes_read 5347291
STAT bytes_written 5348047
STAT limit_maxbytes 8589934592
STAT accepting_conns 1
STAT listen_disabled_num 0
STAT threads 4
STAT conn_yields 0
STAT bytes 5347537
STAT curr_items 8
STAT total_items 8
STAT evictions 0
STAT reclaimed 0
END
