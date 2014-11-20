use Test::More tests => 4;
use strict;
use warnings;

use_ok("Archive::Tar::Streaming::Read");

open(my $test_tar, "<", "t/_data/test.tar");
my $ts = new_ok("Archive::Tar::Streaming::Read"=>[fh=>$test_tar]);
$ts->read_header; # The directory

# http://www.gnu.org/software/tar/manual/html_node/Standard.html
subtest "GNU type L is correctly parsed as a filename" => sub {
  my %h = $ts->read_header;
  unlike($h{path}, qr/\0/, 'path does not contain \0');
  is($h{path}, "test/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "path is correct");
  $ts->read_data;
};

subtest "GNU type K is correctly parsed as a symlink destination" => sub {
  my %h = $ts->read_header;
  unlike($h{linkpath}, qr/\0/, 'linkpath does not contain \0');
  is($h{path}, "test/t", "path is correct");
  is($h{linkpath}, "test/tttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttt", "destination is correct");
  $ts->read_data;
};
