#!/usr/bin/perl

use strict;
use warnings;
use IO::File qw();
use Test::More;
use File::Temp qw(tempfile);

my $debug = $ARGV[0];

my %parms;
my $range   = 0;
my $uidplus = 0;
my $fast    = 1;

BEGIN {
    open TST, 'test.txt'
      or plan skip_all => 'test parameters not provided in test.txt';

    while ( my $l = <TST> ) {
        chomp $l;
        my ( $p, $v ) = split /\=/, $l, 2;
        s/^\s+//, s/\s+$// for $p, $v;
        $parms{$p} = $v if $v;
    }

    close TST;

    my @missing;
    foreach my $p (qw/server user passed/) {
        push( @missing, $p ) unless defined $parms{$p};
    }

    @missing
      ? plan skip_all => "missing value for: @missing"
      : plan tests    => 85;
}

BEGIN { use_ok('Mail::IMAPClient') or exit; }

my %new_args = (
    Server        => delete $parms{server},
    Port          => delete $parms{port},
    User          => delete $parms{user},
    Password      => delete $parms{passed},
    Authmechanism => delete $parms{authmech},
    Clear         => 0,
    Fast_IO       => $fast,
    Uid           => $uidplus,
    Debug         => $debug,
);

# allow other options to be placed in test.txt
%new_args = ( %new_args, %parms );

my $imap = Mail::IMAPClient->new(
    %new_args,
    Range    => $range,
    Debug_fh => ( $debug ? IO::File->new( 'imap1.debug', 'w' ) : undef )
);

ok( defined $imap, 'created client' );
$imap
  or die "Cannot log into $new_args{Server} as $new_args{User}.\n"
  . "Are server/user/password correct?\n";

isa_ok( $imap, 'Mail::IMAPClient' );

$imap->Debug_fh->autoflush() if $imap->Debug_fh;

my $testmsg = <<__TEST_MSG;
Date:  @{[$imap->Rfc822_date(time)]}
To: <$new_args{User}\@$new_args{Server}>
From: Perl <$new_args{User}\@$new_args{Server}>
Subject: Testing from pid $$

This is a test message generated by $0 during a 'make test' as part of
the installation of the Mail::IMAPClient module from CPAN.
__TEST_MSG

ok( $imap->noop,                    "noop" );
ok( $imap->tag_and_run("NOOP\r\n"), "tag_and_run" );

my $sep = $imap->separator;
ok( defined $sep, "separator is '$sep'" );

{
    my $list = $imap->list();
    is( ref($list), "ARRAY", "list" );

    my $lsub = $imap->lsub();
    is( ref($lsub), "ARRAY", "lsub" );
}

my $ispar = $imap->is_parent('INBOX');
my ( $target, $target2 ) =
  $ispar
  ? ( "INBOX${sep}IMAPClient_$$", "INBOX${sep}IMAPClient_2_$$" )
  : ( "IMAPClient_$$", "IMAPClient_2_$$" );

ok( defined $ispar, "INBOX is_parent '$ispar' (note: target '$target')" );

ok( $imap->select('inbox'), "select inbox" );

# test append_file
my $append_file_size;
{
    my ( $afh, $afn ) = tempfile UNLINK => 1;

    # write message to autoflushed file handle since we keep $afh around
    my $oldfh = select($afh);
    $| = 1;
    select($oldfh);
    print( $afh $testmsg ) or die("print testmsg failed");
    cmp_ok( -s $afn, '>', 0, "tempfile has size" );

    ok( $imap->create($target), "create target" );

    my $uid = $imap->append_file( $target, $afn );
    ok( defined $uid, "append_file test message to $target" );

    ok( $imap->select($target), "select $target" );

    my $msg = ( $uidplus and $uid ) ? $uid : ( $imap->messages )[0];
    my $size = $imap->size($msg);

    cmp_ok( $size, '>', 0, "has size $size" );

    my $string = $imap->message_string($msg);
    ok( defined $string, "returned string" );

    cmp_ok( length($string), '==', $size, "string matches server size" );
    ok( $imap->delete($target), "delete folder $target" );

    $append_file_size = $size;
}

ok( $imap->create($target), "create target" );
ok( $imap->select($target), "select $target" );

# Test append / append_string if we also have UID capability
SKIP: {
    skip "UIDPLUS not supported", 3 unless $imap->has_capability("UIDPLUS");

    my $ouid = $imap->Uid();
    $imap->Uid(1);

    # test with date that has a leading space
    my $d = " 1-Jan-2011 01:02:03 -0500";
    my $uid = $imap->append_string( $target, $testmsg, undef, $d );
    ok( defined $uid, "append test message to $target with date (uid=$uid)" );
    ok( $imap->delete_message($uid), "delete_message $uid" );
    ok( $imap->uidexpunge($uid),     "uidexpunge $uid" );

    # multiple args joined internally in append()
    $uid = $imap->append( $target, $testmsg, "Some extra text too" );
    ok( defined $uid, "append test message to $target with date (uid=$uid)" );
    ok( $imap->delete_message($uid), "delete_message $uid" );
    ok( $imap->uidexpunge($uid),     "uidexpunge $uid" );

    $imap->Uid($ouid);
}

# test append
{
    my $uid = $imap->append( $target, $testmsg );
    ok( defined $uid, "append test message to $target" );

    my $msg = ( $uidplus and $uid ) ? $uid : ( $imap->messages )[0];
    my $size = $imap->size($msg);

    cmp_ok( $size, '>', 0, "has size $size" );

    my $string = $imap->message_string($msg);
    ok( defined $string, "returned string" );

    cmp_ok( length($string), '==', $size, "string == server size" );

    {
        my $var;
        ok( $imap->message_to_file( \$var, $msg ), "to SCALAR ref" );
        cmp_ok( length($var), '==', $size, "correct size" );

        my ( $fh, $fn ) = tempfile UNLINK => 1;
        ok( $imap->message_to_file( $fn, $msg ), "to file $fn" );

        cmp_ok( -s $fn, '==', $size, "correct size" );
    }

    cmp_ok( $size, '==', $append_file_size, "size matches string/file" );

    # save first message/folder for use below...
    #OFF ok( $imap->delete($target), "delete folder $target" );
}

#OFF ok( $imap->create($target), "create target" );
ok( $imap->exists($target),  "exists $target" );
ok( $imap->create($target2), "create $target2" );
ok( $imap->exists($target2), "exists $target2" );

{
    ok( $imap->subscribe($target), "subscribe target" );

    my $sub1 = $imap->subscribed();
    is( ( grep( /^\Q$target\E$/, @$sub1 ) )[0], "$target", "subscribed" );

    ok( $imap->unsubscribe($target), "unsubscribe target" );

    my $sub2 = $imap->subscribed();
    is( ( grep( /^\Q$target\E$/, @$sub2 ) )[0], undef, "unsubscribed" );
}

ok( $imap->select($target), "select $target" );

my $fwquotes = qq($target${sep}has "quotes");
if ( !$imap->is_parent($target) ) {
    ok( 1, "not parent, skipping quote test 1/3" );
    ok( 1, "not parent, skipping quote test 2/3" );
    ok( 1, "not parent, skipping quote test 3/3" );
}
elsif ( $imap->create($fwquotes) ) {
    ok( 1,                        "create $fwquotes" );
    ok( $imap->select($fwquotes), 'select $fwquotes' );
    ok( $imap->close,             'close $fwquotes' );
    $imap->select('inbox');
    ok( $imap->delete($fwquotes), 'delete $fwquotes' );
}
else {
    if ( $imap->LastError =~ /NO Invalid.*name/ ) {
        ok( 1, "$new_args{Server} doesn't support quotes in folder names" );
    }
    else { ok( 0, "failed creation with quotes" ) }
    ok( 1, "skipping 1/2 tests" );
    ok( 1, "skipping 2/2 tests" );
}

my $fields = $imap->search( "HEADER", "Message-id", "NOT_A_MESSAGE_ID" );
is( scalar @$fields, 0, 'bogus message id does not exist' );

my @seen = $imap->seen;
cmp_ok( scalar @seen, '==', 1, 'have seen 1' );

ok( $imap->deny_seeing( \@seen ), 'deny seeing' );
my @unseen = $imap->unseen;
cmp_ok( scalar @unseen, '==', 1, 'have unseen 1' );

ok( $imap->see( \@seen ), "let's see one" );
cmp_ok( scalar @seen, '==', 1, 'have seen 1' );

$imap->deny_seeing(@seen);    # reset

$imap->Peek(1);
my $subject = $imap->parse_headers( $seen[0], "Subject" )->{Subject}[0];
unlike( join( "", $imap->flags( $seen[0] ) ), qr/\\Seen/i, 'Peek==1' );

$imap->deny_seeing(@seen);
$imap->Peek(0);
$subject = $imap->parse_headers( $seen[0], "Subject" )->{Subject}[0];
like( join( "", $imap->flags( $seen[0] ) ), qr/\\Seen/i, 'Peek==0' );

$imap->deny_seeing(@seen);
$imap->Peek(undef);
$subject = $imap->parse_headers( $seen[0], "Subject" )->{Subject}[0];
unlike( join( "", $imap->flags( $seen[0] ) ), qr/\\Seen/i, 'Peek==undef' );

my $uid2 = $imap->copy( $target2, 1 );
ok( $uid2, "copy $target2" );

my @res = $imap->fetch( 1, "RFC822.TEXT" );
ok( scalar @res, "fetch rfc822" );

my $res1 = $imap->fetch_hash("RFC822.SIZE");
is( ref($res1), "HASH", "fetch_hash(RFC822.SIZE)" );

my $res2 = $imap->fetch_hash( 1, "RFC822.SIZE" );
is( ref($res2), "HASH", "fetch_hash(1,RFC822.SIZE)" );

my $h = $imap->parse_headers( 1, "Subject" );
ok( $h, "got subject" );
like( $h->{Subject}[0], qr/^Testing from pid/, "subject matched" );

ok( $imap->select($target), "select $target" );
my @hits = $imap->search( SUBJECT => 'Testing' );
cmp_ok( scalar @hits, '==', 1, 'hit subject Testing' );
ok( defined $hits[0], "subject is defined" );

ok( $imap->delete_message(@hits), 'delete hits' );
my $flaghash = $imap->flags( \@hits );
my $flagflag = 0;
foreach my $v ( values %$flaghash ) {
    $flagflag += grep /\\Deleted/, @$v;
}
cmp_ok( $flagflag, '==', scalar @hits, "delete verified" );

my @nohits = $imap->search( \qq(SUBJECT "Productioning") );
cmp_ok( scalar @nohits, '==', 0, 'no hits expected' );

ok( $imap->restore_message(@hits), 'restore messages' );

$flaghash = $imap->flags( \@hits );
foreach my $v ( values %$flaghash ) {
    $flagflag-- unless grep /\\Deleted/, @$v;
}
cmp_ok( $flagflag, '==', 0, "restore verified" );

$imap->select($target2);
ok(
    $imap->delete_message( scalar( $imap->search("ALL") ) )
      && $imap->close
      && $imap->delete($target2),
    "delete $target2"
);

$imap->select("INBOX");
$@ = undef;
@hits =
  $imap->search( BEFORE => Mail::IMAPClient::Rfc2060_date(time), "UNDELETED" );
ok( !$@, "search undeleted" ) or diag( '$@:' . $@ );

#
# Test migrate method
#

my $im2 = Mail::IMAPClient->new(
    %new_args,
    Timeout  => 30,
    Debug_fh => ( $debug ? IO::File->new(">./imap2.debug") : undef ),
);
ok( defined $im2, 'started second imap client' );

my $source = $target;
$imap->select($source)
  or die "cannot select source $source: $@";

$imap->append( $source, $testmsg ) for 1 .. 5;
$imap->close;
$imap->select($source);

my $migtarget = $target . '_mirror';

$im2->create($migtarget)
  or die "can't create $migtarget: $@";

$im2->select($migtarget)
  or die "can't select $migtarget: $@";

$imap->migrate( $im2, scalar( $imap->search("ALL") ), $migtarget )
  or die "couldn't migrate: $@";

$im2->close;
$im2->select($migtarget)
  or die "can't select $migtarget: $@";

ok( !$@, "LastError not set" ) or diag( '$@:' . $@ );

#
my $total_bytes1 = 0;
for ( $imap->search("ALL") ) {
    my $s = $imap->size($_);
    $total_bytes1 += $s;
    print "Size of msg $_ is $s\n" if $debug;
}

my $total_bytes2 = 0;
for ( $im2->search("ALL") ) {
    my $s = $im2->size($_);
    $total_bytes2 += $s;
    print "Size of msg $_ is $s\n" if $debug;
}

ok( !$@, "LastError not set" ) or diag( '$@:' . $@ );
cmp_ok( $total_bytes1, '==', $total_bytes2, 'size source==target' );

# cleanup
$im2->select($migtarget);
$im2->delete_message( @{ $im2->messages } )
  if $im2->message_count;

ok( $im2->close, "close" );
$im2->delete($migtarget);

ok_relaxed_logout($im2);

# Test IDLE
SKIP: {
    skip "IDLE not supported", 4 unless $imap->has_capability("IDLE");
    ok( my $idle = $imap->idle, "idle" );
    sleep 1;
    ok( $imap->idle_data,   "idle_data" );
    ok( $imap->done($idle), "done" );
    ok( !$@, "LastError not set" ) or diag( '$@:' . $@ );
}

$imap->select('inbox');
if ( $imap->rename( $target, "${target}NEW" ) ) {
    ok( 1, 'rename' );
    $imap->close;
    $imap->select("${target}NEW");
    $imap->delete_message( @{ $imap->messages } ) if $imap->message_count;
    $imap->close;
    $imap->delete("${target}NEW");
}
else {
    ok( 0, 'rename failed' );
    $imap->delete_message( @{ $imap->messages } )
      if $imap->message_count;
    $imap->close;
    $imap->delete($target);
}

$imap->_disconnect;
ok( $imap->reconnect, "reconnect" );

ok_relaxed_logout($imap);

# STARTTLS - an optional feature
if ( $imap->_load_module("SSL") ) {
    $imap->connect( Ssl => 0, Starttls => 1 );
    ok( 1, "OPTIONAL connect(Starttls=>1)" . ( $@ ? ": (error) $@ " : "" ) );
}
else {
    ok( 1, "skipping optional STARTTLS test" );
}

# LOGOUT
# - on successful LOGOUT $code is OK (not BYE!) see RFC 3501 sect 7.1.5
#   however some servers return BYE instead so we let that pass here...
sub ok_relaxed_logout {
    my $imap = shift;
    local ($@);
    my $rc = $imap->logout;
    my $err = $imap->LastError || "";
    ok( ( $rc or $err =~ /^\* BYE/ ), "logout" . ( $err ? ": $err" : "" ) );
}
