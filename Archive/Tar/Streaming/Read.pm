package Archive::Tar::Streaming::Read;
use strict;
use warnings;
use IO::Handle;

# Copyright (c) 2011, Heart Internet Ltd
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of the <organization> nor the
#       names of its contributors may be used to endorse or promote products
#       derived from this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=head1 NAME

Archive::Tar::Streaming::Read

=head1 DESCRIPTION

Allows you to stream a tar file in and handle it somehow. Does NOT stream
a tar file back out.

Please note that, unlike Archive::Tar::Stream this won't try to read the
contents of any file into memory unless you ask it to, making it safe for huge
files.

=head1 FORMAT OVERVIEW

The "tar" format at its core is extremely simple, it's just a series of
header+body pairs, and at the end, just to be explicit, a pair of null
blocks (perhaps best thought of as two null headers). Each header is
512 bytes (4096 bits, one disc block) although as standard not all of
that is used; each body is a series of 512-byte blocks, including some
kind of padding at the end of the last one. The header stores the same
kind of information the filesystem would have, and no more, eg. times,
UIDs, filenames, and sizes. Adding to a tar is as simple as overwriting
the last two blocks and continuing.

There are references to "ustar" in the code: this is an extension to
vanilla tar created by shoving extra data into the space in the header,
eg. the actual username of the owner. Unfortunately there are two
implementations of this - the standard one ("ustar\0") which includes
a much-needed filename prefix (directory) and the GNU one ("ustar ")
which includes more timestamps and primitive sparse file support.

Further extensions would no longer fit in the header, so these result in
extra header+body members immediately before the member they refer to;
the one you'll encounter a lot is the GNU long-name chunk which includes
the full name of the next item as data.

Numeric values are traditionally expressed in octal, so a text editor
is sufficient to inspect a tar file in the common case.

Since compression with tar means piping through gzip, you get good
compression of wasted space and redundancy between small files, but the
resultant file is completely impossible to seek in. In a non-compressed
tar file you can seek forwards quite easily, which makes it relatively
painless for reading the TOC.

=head1 METHODS

=head2 new(%args)

Creates the stream handler.

Args are:

=over

=item fh

The filehandle from which to read the tar data

=back

=cut

sub new {
  my ($class, %args) = @_;
  my $self = {
    fh=>$args{fh},
  };
  return bless($self, $class);
}

=head2 read_header()

Reads a header and returns it. If the header is invalid, this will die.

Returns a hash or hashref, or nothing at EOF.

Some tar header blocks, if correctly parsed (fingers crossed!) will be
treated as expanded headers, meaning that multiple headers and data will
be read because it's really all just for one file.

Fields are:

=head3 Standard tar data

=over

=item checksum

The checksum value. You can ignore this.

=item filename

The filename. Limited to 100 characters.

=item gid

The owner's GID.

=item linkpath

If it's a hard link, this is the name of the file in the tarball which
contains the real data.

=item mode

The mode, as a number.

=item mtime

The modification timestamp.

=item size

The size in bytes.

=item type

File type, using an approximation of ls' type letters:

=over

=item -

File.

=item L

Hard link (ie, normal file but the data is elsewhere)

=item l

Symlink

=item c

Character device

=item b

Block device

=item d

Directory

=item p

FIFO

=back

=item uid

The owner's UID.

=back

=head3 UStar data

=over

=item metadata_extension_id

"ustar"

=item metadata_extension_version

The version number (eg. 0)

=item uname

The name of the user who owns the file.

=item gname

The name of the group which owns the file.

=item major

Major number (for devices)

=item minor

Minor number (for devices)

=item prefix

The prefix for the filename

=back

=head3 PAX

Various other attributes may be set.

=head3 Other

=over

=item path

The full filename, patched together using whatever information is
available.

=back

=cut

my @file_types=qw/
  - L l c b d p
/; # This is for the spec, NULL+0-6

use Fcntl ':mode';

my %type_to_mode_prefix =(
  "-" => S_IFREG,
  "L" => S_IFREG,
  "l" => S_IFLNK,
  "c" => S_IFCHR,
  "b" => S_IFBLK,
  "d" => S_IFDIR,
  "p" => S_IFIFO,
);

sub _long_oct {
  my ($s) = @_;
  $s=~s/^0+//;
  $s=~s/\0$//;
  if(
    length($s) < 11 or
    (length($s) == 11 and $s=~/^[1-3]/)
  ) {
    # Short enough to do verbatim.
    return oct($s);
  }
  # Otherwise, split it into even-ish-sized chunks
  # 64 / 3 = a mess, so instead break into 3x 24-bit
  # chunks. Which is 8 bytes each.
  my $i=0;
  my $t;
  while($s=~s/(.{8})$//) {
    my $n = oct($1);
    $n*=2**(24*$i);
    $t+=$n;
    $i++;
  }
  if($s) {
    my $n = oct($s);
    $n*=2**(24*$i);
    $t+=$n;
  }
  return $t;
}

sub read_header {
  my ($self) = @_;
  my $header_data;

  $self->skip_padding() if ($self->{last_header} and not $self->{padding_skipped});

  return unless $self->{fh}->read($header_data, 512);
  if($header_data=~/^\0+$/s) {
    # End of archive. Suck up the remaining block.
    $self->{fh}->read(undef, 512);
    return;
  }

  my %header_literal;

  # Suck up the standard header (257 bytes)
  @header_literal{qw/
    filename mode uid gid size mtime checksum type linkpath
  /} = unpack(
    "A100A8A8A8A12A12A8AA100", $header_data);
  
  # Convert the numbers.
  my %header_parsed;
  @header_parsed{qw/
    filename mode uid gid size mtime checksum type linkpath
  /} = (
    @header_literal{qw/ filename /},
    (map {_long_oct($_)} @header_literal{qw/ mode uid gid size mtime checksum /}),
    ($header_literal{type}=~/\d/ ? $file_types[ $header_literal{type} ] : "-"),
    $header_literal{linkpath},
  );

  # But wait a second! "mode" may be just the permissions at this stage.
  # So mask in the real mode prefix.

  # I'm setting bits here, not defaulting, so no ||=.
  $header_parsed{mode} |= $type_to_mode_prefix{ $header_parsed{type} };

  my $header_data_for_checksum = $header_data;
  $header_data_for_checksum=~s/^(.{148}).{8}/$1        /; # Eight spaces.

  # Check the checksum.
  my $expected_checksum = 0;
  $expected_checksum+=$_
    for(unpack("C512", $header_data_for_checksum)); 
  my $expected_checksum_s = 0;
  $expected_checksum_s+=$_
    for(unpack("c512", $header_data_for_checksum)); 

  if(
      $expected_checksum != $header_parsed{checksum} and
      $expected_checksum_s != $header_parsed{checksum}
    ) {
    warn "Checksum mismatch: $expected_checksum|$expected_checksum_s != $header_parsed{checksum}";
    warn "Dumping header";
    $header_data=~s/([\x7f-\xff\x00-\x1f])/'\\'.ord($1)/ge;
    warn $header_data;
    die;
  }

  if(substr($header_data, 257, 6) eq "ustar\0") {

    # We have a Uniform Standard tarball, so more delicious data!
    my $ustar_data = substr($header_data, 257, 500-257);
    @header_literal{qw/
      metadata_extension_id metadata_extension_version uname gname major minor prefix
    /} = unpack(
      "A6A2A32A32A8A8A155", $ustar_data);
    @header_parsed{qw/
      metadata_extension_id metadata_extension_version uname gname major minor prefix
    /} = (
      $header_literal{metadata_extension_id},
      oct($header_literal{metadata_extension_version}),
      @header_literal{qw/ uname gname /},
      (map {oct($_)} @header_literal{qw/ major minor /}),
      $header_literal{prefix},
    );
    $header_parsed{path} = $header_parsed{prefix}.$header_parsed{filename};

  } elsif(substr($header_data, 257, 6) eq "ustar ") {

    # We have a GNU variant UStar. I hate you, GNU! Be more standard!
    my $gnu_data = substr($header_data, 257, 512-257);
    @header_literal{qw/
      metadata_extension_id metadata_extension_version uname gname major minor
      atime ctime offset longnames unused 
      sparse1 sparse2 sparse3 sparse4
      isextended realsize
    /} = unpack(
      "A6A2A32A32A8A8"."A12A12A12A4A"."A24A24A24A24"."A1A12", $gnu_data);
    @header_parsed{qw/
      metadata_extension_id metadata_extension_version uname gname major minor
      atime ctime offset longnames unused 
      sparse1 sparse2 sparse3 sparse4
      isextended realsize
    /} = (
      $header_literal{metadata_extension_id},
      oct($header_literal{metadata_extension_version}),
      @header_literal{qw/ uname gname /},
      (map {oct($_)} @header_literal{qw/ major minor /}),
      (map {_long_oct($_)} @header_literal{qw/ atime ctime offset /}),
      @header_literal{qw/ longnames unused sparse1 sparse2 sparse3 sparse4 isextended /},
      @header_literal{qw/ realsize /}, # Although this IS packed, I don't know how.
    );

    $header_parsed{path} = $header_parsed{filename};

  }
  $self->{last_header} = \%header_parsed;

  # It's completely possible that we get here and have to read another
  # header. So deal with it!
  if($header_literal{type}=~/[KL]/) { # I don't intend to support M

    # GNU tar long filename

    my $actual_filename = $self->read_data();
    %header_parsed = $self->read_header();
    $header_parsed{path} = $actual_filename;

  } elsif($header_literal{type}=~/[S]/) {

    # GNU tar sparse file. PS, I hate you, GNU tar.
    warn "Sparse file data is NOT supported";

  } elsif($header_literal{type} eq "D") {

    # GNU tar directory. Just ignore it.
    $header_parsed{type} = "d";

  } elsif($header_literal{type} eq "x") { # I don't intend to support g

    # PAX extended attribute. It's required that these overwrite
    # the header where applicable.

    my $ea_data_packed = $self->read_data();
    %header_parsed = $self->read_header();
    while($ea_data_packed=~s/^(\d+) //) {
      my $length = $1;
      $length-=(1+length($length));
      $ea_data_packed=~s/^(.{$length})//s;
      chomp(my $line=$1);
      my ($key, $value) = split(/=/, $line, 2);
      $header_parsed{$key} = $value;
    }

  }

  $self->{padding_skipped} = 0;

  return wantarray ? %header_parsed : \%header_parsed;
}

=head2 read_data()

Reads the data block referred to by the last header. This is meaningless unless
you're doing read_header()/read_data() pairs.

=cut

sub read_data {
  my ($self) = @_;
  my $body_data;
  my $s;
  for($s = $self->{last_header}{size}; $s>512; $s-=512) {
    $self->{fh}->read($body_data, 512);
  }
  $self->{fh}->read($body_data, $s);
  $self->skip_padding();
  return $body_data;
}

=head2 skip_padding()

Just skips the padding at the end of a data block. You don't need to call
this explicitly.

=cut

sub skip_padding {
  my ($self) = @_;
  my $overflow = $self->{last_header}{size} % 512;
  if($overflow > 0) {
    $self->{fh}->read(undef, 512-$overflow);
  }
  $self->{padding_skipped} = 1;
}

1;
