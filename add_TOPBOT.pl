#!/usr/bin/env perl 

=head1 add_TOPBOT.pl

=head1 Usage

add_TOPBOT.pl --ref hg19.fa coordinates.txt
cat coordinates.txt | add_TOPBOT.pl --ref hg19.fa 

Add TOPBOT designation to a delimited file

=head1 Synopsis

    SNPs that could not be called as TOP or BOT instead have an ERROR_* code.

=head1 Options

=head2 Required 

  --ref STRING 
    Path to the reference FASTA file, for use with samtools faidx.

=head2 Optional 

  --help
    Get help

  --delim STRING
    Use this string as the delimiter instead of the default tab.

  --noheader
    Denotes that the file has a no header line. 

  --chrom STRING
  --position STRING
  --A STRING
  --B STRING
  --AB STRING
    These options specify the column for the SNP chromosome, position, first allele (A), second allele (B), combined allele (AB). 
    If these are a number, then it refers to that column number, otherwise it is the name of the column according to the header.
    If the alleles are in two columns, use --A and --B, if they are in a single column use --AB. 
    --AB attempts to find exactly two alleles (A/G/C/T) on the column, any more or less will cause the program to die. 
    Defaults are the same as the option name, i.e. "chrom", "position", "A", "B".

  --insertcol = NUMBER
    Insert the TOPBOT designation after this column. When set to 0, this becomes the first column in the output.
    (default after last column)

  --shortname
    Instead of designating TOPBOT with TOP and BOT, just use T and B.

  --headername
    Name of the column for the header with TOPBOT designation (default TOPBOT)

  --errorfilter
    Filter SNPs with an error (no TOP or BOT strand)

  --comment STRING
    String denoting lines to be skipped if this string is the first non-whitespace on a line. (default '#')

  --skip NUMBER
    Skip this many lines from the start, including comment lines. (default 0)

  --chromprefix STRING
    Append this string to the start of chromosome names when looking in the FASTA reference. 
    A common alternative value for this is "chr".
    (default "")

=cut

use 5.010;
use strict;
use warnings;
use autodie;
use Getopt::Long;
use Pod::Usage;
use Bio::SNP::TOPBOT;
use List::Util qw(max);

# Process command line options
my $help;
my $ref;
my $delim = "\t";
my $noheader = 0;
my $chrom = "chrom";
my $position = "position";
my $A;
my $B;
my $AB;
my $comment = "#";
my $skip = 0;
my $insertcol;
my $errorfilter;
my $chromprefix = '';
my $shortname = '';
my $headername = 'TOPBOT';

GetOptions(
    "help"          => \$help,
    "ref=s"         => \$ref,
    "delim=s"       => \$delim,
    "noheader"      => \$noheader,
    "chrom=s"       => \$chrom,
    "position=s"    => \$position,
    "A=s"           => \$A,
    "B=s"           => \$B,
    "AB=s"          => \$AB,
    "comment=s"     => \$comment,
    "skip=i"        => \$skip,
    "insertcol=i"   => \$insertcol,
    "errorfilter"   => \$errorfilter,
    "chromprefix=s" => \$chromprefix,
    "shortname"     => \$shortname,
    "headername=s"  => \$headername,

) or die "Error in command line arguments. Use --help for more information.\n";
if(@ARGV > 1) { die("Unused parameters in command line: " . join("\t", @ARGV)) };

if(defined($help)){
    pod2usage(
        -verbose => 2, 
        -output => \*STDOUT, 
        -width => 50,
        -noperldoc => ! -t STDOUT,
    );
}

# check inputs and set any defaults
# check reference file exists
unless(defined($ref)) { die "Reference file (--ref) must be specified.\n" }
unless(-r $ref) { die "Reference file \"$ref\" is not readable.\n" }

# Check A and B column specification
if(defined($AB) && (defined($A) || defined($B))) {
    die "Cannot define --AB and at least one of --A or --B.\n";
}
if(defined($A) xor defined($B)) {
    die "Must define both --A and --B together";
}
if(!(defined($AB) || defined($A) || defined($B))) {
    # set A and B defaults
    $A = "A";
    $B = "B";
}

# check delim is at least one character
if(length($delim) == 0) { die "Delimiter --delim must be at least one character long\n" }

# check these are integers 0 or greater
if($skip !~ /^\d+$/) { die "--skip is not an integer of 0 or greater.\n"} 
if($insertcol !~ /^\d+$/) { die "--insertcol is not an integer of 0 or greater.\n" }

# check columns are set if --noheader
if($noheader) {
    my $hsay = "need to be integers with no header";
    if($chrom =~ /^\d+$/ || $position =~ /^\d+$/) { die "--chrom, --position $hsay.\n" }
    if(defined($AB)) {
        if($AB =~ /^\d+$/) { die "--AB $hsay\n" }
    } else {
        if($A =~ /^\d+$/ || $B =~ /^\d+$/) { die "--A and --B $hsay\n" }
    }
}


# Process the input
my %error_table;
my $successes;
my $header_unseen = !$noheader; # assume column numbers are correct
while(<>) {
    # basic line processing, skip
    if($skip > 0) {
        $skip--;
        next;
    }
    next if /^\s*$comment/o;
    chomp;
    my @line = split /$delim/o;

    # process header if required
    if($header_unseen) {
        # set the column numbers
        my %cols;
        @cols{@line} = (0..$#line);
        foreach ($chrom, $position, $A, $B, $AB) {
            unless(defined($_)) { next }
            if($_ =~ /^\d+$/) { next }
            if(defined($cols{$_})) {
                $_ = $cols{$_};
            } else {
                die "Column $_ not found.\n";
            }
        }
        unless (defined $insertcol) {
            $insertcol = @line; # default as the last column
        }
        $header_unseen = 0;

        # print header line
        unless ($noheader) {
            splice @line, $insertcol, 0, ($headername);
            say join($delim, @line);
        }
        next;
    }
    
    # determine and check A and B allele
    my ($allele_a, $allele_b);
    my $is_base_error;
    if(defined($AB)) {
        my @matches = ($AB =~ /[ACGT]/g);
        if(@matches == 2) {
            ($allele_a, $allele_b) = @matches;
        } else {
            $is_base_error = 'ERROR_not_AGCT';    
        }
    } else {
        $allele_a = $line[$A];
        $allele_b = $line[$B];
        unless($allele_a =~ /^[ACGT]$/ && $allele_b =~ /^[ACGT]$/) {
            $is_base_error = 'ERROR_not_AGCT';
        }
    }

    # find TOPBOT value
    my $topbot;
    if(defined($is_base_error)) {
        $topbot = $is_base_error;
    } else {
        $topbot = topbot_genome $ref, "$chromprefix${line[$chrom]}", $line[$position], $allele_a, $allele_b;
    }
    
    # count errors
    if($topbot =~ /^ERROR/) {
        $error_table{$topbot}++;
        if($errorfilter) {
            # Filter error lines
            next
        }
    } else {
        $successes++;
        if($shortname) {
            $topbot =~ s/O.$//;
        }
    }

    # insert into output
    splice @line, $insertcol, 0, ($topbot);

    # Give output line
    say join($delim, @line);
}

# STDERR summary
my @keys_sorted = sort (keys %error_table);

warn "Successful TOPBOT: $successes\n";
warn "Error summary:\n";
my $max_k_len = max (map { length } @keys_sorted);
for my $k (@keys_sorted) {
    warn (sprintf "    %-${max_k_len}s: %s\n", $k, $error_table{$k});
}

